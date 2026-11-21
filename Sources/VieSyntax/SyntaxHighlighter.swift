import Foundation
import TreeSitter
import VieText

/// A highlighted run of text.
public struct HighlightSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var highlight: Highlight
    /// Drawn with a line through it (`@markup.strikethrough`). Unlike the highlight, markup
    /// inside doesn't take it away, so the line runs through bold or code within.
    public var struck: Bool

    public init(range: Range<Int>, highlight: Highlight, struck: Bool = false) {
        self.range = range
        self.highlight = highlight
        self.struck = struck
    }
}

/// Highlights one document. Parsing runs on a background queue on a snapshot of the text;
/// edits are applied to the current trees right away (so highlights stay in place while the
/// new parse runs), and the new trees replace them when it finishes. Highlights are computed
/// on demand for the bytes being laid out, so only visible text pays for queries.
///
/// Injected languages (a Markdown paragraph's inline markup, a fenced code block, an HTML
/// script) are parsed into layers over their parts of the text and drawn over the main tree.
/// A parse keeps the layers whose text didn't change and reparses edited ones from their old
/// trees, so typing in one paragraph doesn't redo the others. In long files, layers are kept
/// only in a region around what was last asked for (see `spans(in:)`), which moves with it.
@MainActor
public final class SyntaxHighlighter {
    public let language: SyntaxLanguage
    /// Whether the first parse has finished (until then there are no highlights).
    public private(set) var isReady = false
    /// Called with byte ranges whose highlighting may have changed, when a parse lands.
    public var onChange: (([Range<Int>]) -> Void)?
    /// Whether a parse is running (its result not yet in).
    public var isParsing: Bool { parsing }
    /// Milliseconds the last parse took (main tree and injections), for benchmarks.
    public private(set) var lastParseMs = 0.0
    /// Parses that have landed, for benchmarks.
    public private(set) var parseCount = 0

    /// The text the trees (as edited) describe.
    private var rope: Rope
    private var tree: TreeBox?
    /// Injected layers in the order they start, each holding those injected into it in turn.
    private var layers: [Layer] = []
    private let cursor = CursorBox()
    private var parsing = false
    /// Edits made while a parse runs; applied to its trees when it lands.
    private var pendingEdits: [TSInputEdit] = []
    /// Text changed since the last parse landed: redrawn when the next one lands, and layers
    /// over it aren't reused.
    private var dirty: [Range<Int>] = []
    /// Whether the text changed since the main tree was parsed. If not, a parse only updates
    /// the layers, for a new region.
    private var treeIsStale = true
    /// Where layers are kept, in a file longer than two margins: around the last request.
    private var region: Range<Int>
    /// The region moved while a parse ran, so another should follow it.
    private var layersWanted = false
    /// After the region moves, the part of it being drawn, which the next parse fills first;
    /// another then fills the rest.
    private var firstPass: Range<Int>?

    /// How far layers are kept before and after what was last asked for. Files shorter than
    /// twice this keep all of theirs.
    nonisolated static let regionMargin = 64 * 1024

    /// Layers kept, nested ones included (for tests and benchmarks).
    var layerCount: Int { layers.reduce(0) { $0 + $1.count } }
    /// Layers the last parse parsed rather than reused (for tests and benchmarks).
    private(set) var lastLayerParses = 0
    /// The last highlighted window, until the text or the trees change.
    private var window: (range: Range<Int>, spans: [HighlightSpan])?

    /// One queue and one set of parsers for all documents.
    nonisolated private static let queue = DispatchQueue(label: "Vie.syntax", qos: .userInitiated)
    nonisolated private static let parsers = ParserPool()

    public init(language: SyntaxLanguage, rope: Rope) {
        self.language = language
        self.rope = rope
        region = Self.region(around: 0..<0, count: rope.byteCount)
        startParse()
    }

    // MARK: - Edits

    /// Follows a buffer change: `edits` as the buffer reports them, `rope` the text after them.
    public func update(rope newRope: Rope, edits: [TextEdit]) {
        window = nil
        guard let span = Self.span(of: edits) else {
            rope = newRope
            return
        }
        var edit = TSInputEdit(
            start_byte: UInt32(span.start), old_end_byte: UInt32(span.oldEnd), new_end_byte: UInt32(span.newEnd),
            start_point: Self.point(span.start, in: newRope), old_end_point: Self.point(span.oldEnd, in: rope),
            new_end_point: Self.point(span.newEnd, in: newRope))
        rope = newRope
        if let tree { ts_tree_edit(tree.tree, &edit) }
        for i in layers.indices { layers[i].apply(edit) }
        dirty = dirty.map { Self.map($0, through: edit) } + [span.start..<max(span.newEnd, span.start + 1)]
        region = Self.map(region, through: edit)
        treeIsStale = true
        if parsing {
            pendingEdits.append(edit)
        } else {
            startParse()
        }
    }

    /// One edit covering all of `edits` (each applied to the text left by the ones before):
    /// exact for a single edit, a little wide for several.
    nonisolated static func span(of edits: [TextEdit]) -> (start: Int, oldEnd: Int, newEnd: Int)? {
        guard let first = edits.first else { return nil }
        // The changed region in current and original coordinates; text before it is the same
        // in both, so it starts at the same offset.
        var lo = first.range.lowerBound, hi = lo + first.newLength, oldHi = first.range.upperBound
        for e in edits.dropFirst() {
            let a = e.range.lowerBound, b = e.range.upperBound
            // b in original coordinates: unchanged before the region, its end inside it, shifted after.
            let oldB = b < lo ? b : (b <= hi ? oldHi : b - (hi - oldHi))
            oldHi = max(oldHi, oldB)
            lo = min(lo, a)
            hi = max(hi, b) + e.newLength - (b - a)
        }
        return (lo, oldHi, hi)
    }

    nonisolated private static func point(_ off: Int, in rope: Rope) -> TSPoint {
        let line = rope.line(at: off)
        return TSPoint(row: UInt32(line), column: UInt32(off - rope.offset(ofLine: line)))
    }

    nonisolated static func map(_ r: Range<Int>, through e: TSInputEdit) -> Range<Int> {
        func f(_ p: Int) -> Int {
            if p < Int(e.start_byte) { return p }
            if p >= Int(e.old_end_byte) { return p + Int(e.new_end_byte) - Int(e.old_end_byte) }
            return Int(e.new_end_byte)
        }
        return f(r.lowerBound)..<max(f(r.lowerBound), f(r.upperBound))
    }

    // MARK: - Parsing

    /// What a parse on the syntax queue hands back.
    private struct Parsed: @unchecked Sendable {
        var tree: TreeBox?
        var layers: [Layer]
        /// Where the main tree changed, and where layers were parsed rather than reused.
        var changed: [Range<Int>]
        var fresh: [Range<Int>]
        var layerParses: Int
        /// Only the first pass's part of the region has layers yet.
        var incomplete: Bool
        var ms: Double
    }

    private func startParse() {
        parsing = true
        layersWanted = false
        let reparse = treeIsStale || tree == nil
        treeIsStale = false
        // Copies, so the syntax queue reads trees this thread doesn't edit.
        let old = tree?.copy()
        let oldLayers = layers.map { $0.copy() }
        let rope = self.rope, language = self.language, dirty = self.dirty
        let region: Range<Int>? = rope.byteCount > 2 * Self.regionMargin ? self.region : nil
        let first = region == nil ? nil : firstPass
        firstPass = nil
        Self.queue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let new = reparse ? Self.parsers.parse(rope, language: language, old: old, ranges: nil) : old
            var changed: [Range<Int>] = []
            if !reparse {
                // Only the layers change (the region moved).
            } else if let old, let new {
                var count: UInt32 = 0
                if let ranges = ts_tree_get_changed_ranges(old.tree, new.tree, &count) {
                    changed = (0..<Int(count)).map { Int(ranges[$0].start_byte)..<Int(ranges[$0].end_byte) }
                    free(ranges)
                }
            } else {
                changed = [0..<rope.byteCount]
            }
            var result = Parsed(tree: new, layers: [], changed: changed, fresh: [], layerParses: 0, incomplete: false, ms: 0)
            if let new {
                result.layers = Self.injections(of: new, language: language, rope: rope, depth: 0, region: region, first: first,
                                                old: oldLayers, dirty: dirty, fresh: &result.fresh, parses: &result.layerParses,
                                                incomplete: &result.incomplete)
            }
            result.ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            Task { @MainActor in self?.finishParse(result) }
        }
    }

    private func finishParse(_ result: Parsed) {
        parsing = false
        lastParseMs = result.ms
        parseCount += 1
        window = nil
        guard let new = result.tree else {
            pendingEdits = []
            return
        }
        var newLayers = result.layers
        var changed = result.changed + result.fresh
        for var edit in pendingEdits {
            ts_tree_edit(new.tree, &edit)
            for i in newLayers.indices { newLayers[i].apply(edit) }
            changed = changed.map { Self.map($0, through: edit) }
        }
        let caughtUp = pendingEdits.isEmpty
        pendingEdits = []
        // Reused layers look as they did; only the main tree's changes, the edited text and
        // the layers parsed anew need drawing again.
        var report = changed + dirty
        if !isReady { report = [0..<rope.byteCount] }
        tree = new
        layers = newLayers
        lastLayerParses = result.layerParses
        isReady = true
        if caughtUp { dirty = [] }
        if !caughtUp || layersWanted || result.incomplete { startParse() }
        onChange?(report)
    }

    /// Parses the languages `tree`'s injection query finds inside it, and theirs in turn: at
    /// the top level only those reaching into `region` (nil for all), and of those only the
    /// ones reaching into `first` if given (`incomplete` says some were left for later). A
    /// layer from `old` over the same text, untouched by `dirty`, is kept as it is, with the
    /// layers inside it; an edited one is reparsed from its old tree. The ranges of layers
    /// parsed go in `fresh`.
    nonisolated private static func injections(of tree: TreeBox, language: SyntaxLanguage, rope: Rope, depth: Int,
                                               region: Range<Int>?, first: Range<Int>? = nil, old: [Layer], dirty: [Range<Int>],
                                               fresh: inout [Range<Int>], parses: inout Int, incomplete: inout Bool) -> [Layer] {
        guard depth < 4, let query = language.injections else { return [] }
        let cursor = CursorBox()
        // A combined injection gathers pieces from the whole tree, so it can't be limited.
        if let region, !query.hasCombined {
            ts_query_cursor_set_byte_range(cursor.pointer, UInt32(region.lowerBound), UInt32(region.upperBound))
        }
        ts_query_cursor_exec(cursor.pointer, query.pointer, ts_tree_root_node(tree.tree))
        var combined: [(SyntaxLanguage, [Range<Int>])] = []
        var separate: [(SyntaxLanguage, [Range<Int>])] = []
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor.pointer, &match) {
            guard query.satisfies(match, rope: rope) else { continue }
            let settings = query.settings[Int(match.pattern_index)]
            var name = settings["injection.language"]
            var contents: [TSNode] = []
            for i in 0..<Int(match.capture_count) {
                let capture = match.captures[i]
                switch query.captureNames[Int(capture.index)] {
                case "injection.language":
                    name = rope.string(in: Int(ts_node_start_byte(capture.node))..<Int(ts_node_end_byte(capture.node)))
                case "injection.content":
                    contents.append(capture.node)
                default:
                    break
                }
            }
            guard let name, let injected = SyntaxLanguage.named(name), !contents.isEmpty else { continue }
            let ranges = contents.flatMap { Self.contentRanges($0, includeChildren: settings["injection.include-children"] != nil) }
            guard !ranges.isEmpty else { continue }
            if settings["injection.combined"] != nil {
                if let i = combined.firstIndex(where: { $0.0 === injected }) { combined[i].1 += ranges } else { combined.append((injected, ranges)) }
            } else if region.map({ r in ranges.contains { $0.overlaps(r) } }) ?? true {
                separate.append((injected, ranges))
            }
        }
        var byKey: [LayerKey: Layer] = [:]
        for layer in old { byKey[LayerKey(layer.language, layer.ranges)] = layer }
        var layers: [Layer] = []
        for (injected, ranges) in combined + separate {
            let same = byKey[LayerKey(injected, ranges)]
            if let same, !Self.touches(dirty, same.ranges) {
                layers.append(same)
                continue
            }
            if let first, !ranges.contains(where: { $0.overlaps(first) }) {
                incomplete = true
                continue
            }
            // Edited, or new: parse, starting from the old layer this one replaces if any.
            let base = same ?? Self.overlapping(old, injected, ranges)
            let tsRanges = ranges.map { r in
                TSRange(start_point: point(r.lowerBound, in: rope), end_point: point(r.upperBound, in: rope),
                        start_byte: UInt32(r.lowerBound), end_byte: UInt32(r.upperBound))
            }
            let head = Self.startsOver(injected) ? nil : base?.tree
            guard let sub = parsers.parse(rope, language: injected, old: head, ranges: tsRanges) else { continue }
            parses += 1
            fresh += ranges
            let inner = injections(of: sub, language: injected, rope: rope, depth: depth + 1, region: nil,
                                   old: base?.children ?? [], dirty: dirty, fresh: &fresh, parses: &parses, incomplete: &incomplete)
            layers.append(Layer(language: injected, ranges: ranges, tree: sub, children: inner))
        }
        return layers.sorted { $0.start < $1.start }
    }

    /// Whether an edited layer in `language` is parsed afresh rather than from its old tree.
    /// Markdown's inline grammar can come out different reparsed than parsed afresh (a test
    /// with random edits finds it), and its layers are paragraphs that parse in microseconds.
    nonisolated private static func startsOver(_ language: SyntaxLanguage) -> Bool {
        language.name == "markdown_inline"
    }

    /// Whether an edit reached `ranges` (touching counts).
    nonisolated private static func touches(_ dirty: [Range<Int>], _ ranges: [Range<Int>]) -> Bool {
        dirty.contains { d in ranges.contains { d.lowerBound <= $0.upperBound && d.upperBound >= $0.lowerBound } }
    }

    /// An old layer in the same language over some of the same text, to reparse from. Layers
    /// are in the order they start; only the few starting just before the end are looked at,
    /// since it's only a head start (a parse without one is right too).
    nonisolated private static func overlapping(_ old: [Layer], _ language: SyntaxLanguage, _ ranges: [Range<Int>]) -> Layer? {
        guard let lo = ranges.first?.lowerBound, let hi = ranges.last?.upperBound else { return nil }
        var i = old.partitionIndex { $0.start >= hi }
        var looked = 0
        while i > 0 && looked < 8 {
            i -= 1
            looked += 1
            let layer = old[i]
            if layer.language === language && layer.end > lo { return layer }
        }
        return nil
    }

    /// The node's range, without its named children's unless `includeChildren` (so the inline
    /// markup of a quoted paragraph skips the "> " markers inside it). Anonymous children stay:
    /// Markdown's block grammar has one for each punctuation mark in a paragraph.
    nonisolated private static func contentRanges(_ node: TSNode, includeChildren: Bool) -> [Range<Int>] {
        let start = Int(ts_node_start_byte(node)), end = Int(ts_node_end_byte(node))
        guard !includeChildren else { return start < end ? [start..<end] : [] }
        var out: [Range<Int>] = []
        var at = start
        for i in 0..<ts_node_named_child_count(node) {
            let child = ts_node_named_child(node, i)
            let cs = Int(ts_node_start_byte(child)), ce = Int(ts_node_end_byte(child))
            if cs > at { out.append(at..<cs) }
            at = max(at, ce)
        }
        if end > at { out.append(at..<end) }
        return out
    }

    // MARK: - Structure

    /// The types of the main tree's nodes that hold `offset`, innermost first (as of the last
    /// parse, moved along by edits since). Empty before the first parse.
    public func nodeTypes(at offset: Int) -> [String] {
        guard let tree else { return [] }
        let at = UInt32(min(max(offset, 0), rope.byteCount))
        var node = ts_node_descendant_for_byte_range(ts_tree_root_node(tree.tree), at, at)
        var types: [String] = []
        while !ts_node_is_null(node) {
            types.append(String(cString: ts_node_type(node)))
            node = ts_node_parent(node)
        }
        return types
    }

    // MARK: - Highlights

    /// The highlighted or struck-through runs in `range`, sorted and not overlapping (plain
    /// text is left out).
    ///
    /// Served from one query over a window around the request: the view asks a line at a time,
    /// and each query walks the tree down to its range, so one per screen costs a fraction of
    /// one per line.
    public func spans(in range: Range<Int>) -> [HighlightSpan] {
        let range = max(0, range.lowerBound)..<min(rope.byteCount, range.upperBound)
        guard tree != nil, !range.isEmpty else { return [] }
        followRegion(to: range)
        if window.map({ $0.range.lowerBound > range.lowerBound || $0.range.upperBound < range.upperBound }) ?? true {
            let around = max(0, range.lowerBound - Self.windowBefore)..<min(rope.byteCount, range.upperBound + Self.windowAfter)
            window = (around, query(around))
        }
        let spans = window?.spans ?? []
        var out: [HighlightSpan] = []
        var i = spans.partitionIndex { $0.range.upperBound > range.lowerBound }
        while i < spans.count && spans[i].range.lowerBound < range.upperBound {
            let r = spans[i].range.clamped(to: range)
            if !r.isEmpty { out.append(HighlightSpan(range: r, highlight: spans[i].highlight, struck: spans[i].struck)) }
            i += 1
        }
        return out
    }

    /// Bytes before and after a request that `spans(in:)` also highlights: about a screenful
    /// in all, more of it below, since the view lays out lines top to bottom.
    nonisolated static let windowBefore = 2048, windowAfter = 4096

    /// Moves the region where layers are kept when a request gets near its edge (within a
    /// quarter of the margin; the file's ends don't count), and starts a parse to fill it:
    /// first the part being drawn, then the rest. Until the first lands (a few milliseconds),
    /// the new text shows the main tree's colors only.
    private func followRegion(to range: Range<Int>) {
        guard rope.byteCount > 2 * Self.regionMargin else { return }
        let slack = Self.regionMargin / 4
        let lo = region.lowerBound == 0 ? 0 : region.lowerBound + slack
        let hi = region.upperBound >= rope.byteCount ? rope.byteCount : region.upperBound - slack
        guard range.lowerBound < lo || range.upperBound > hi else { return }
        region = Self.region(around: range, count: rope.byteCount)
        firstPass = max(0, range.lowerBound - Self.windowBefore)..<min(rope.byteCount, range.upperBound + Self.windowAfter)
        if parsing { layersWanted = true } else { startParse() }
    }

    nonisolated static func region(around range: Range<Int>, count: Int) -> Range<Int> {
        max(0, range.lowerBound - regionMargin)..<min(count, range.upperBound + regionMargin)
    }

    /// Runs the highlight queries over `range`: the main tree's, then each injected layer's on top.
    private func query(_ range: Range<Int>) -> [HighlightSpan] {
        guard let tree, let query = language.highlights else { return [] }
        var styles = [Highlight?](repeating: nil, count: range.count)
        var struck = [Bool](repeating: false, count: range.count)
        query.paint(ts_tree_root_node(tree.tree), range: range, cursor: cursor.pointer, rope: rope, into: &styles, struck: &struck)
        // Each layer paints over the text around it, then the layers inside it over it.
        func paint(_ layer: Layer) {
            guard let q = layer.language.highlights else { return }
            var own = [Highlight?](repeating: nil, count: range.count)
            var ownStruck = q.strikes ? [Bool](repeating: false, count: range.count) : []
            q.paint(ts_tree_root_node(layer.tree.tree), range: range, cursor: cursor.pointer, rope: rope, into: &own, struck: &ownStruck)
            // The injected language's highlights go over the outer ones (a heading's inline
            // text keeps the heading's color where the inline grammar has none), only inside
            // its own ranges. A strike adds to the outer ones.
            for r in layer.ranges where r.overlaps(range) {
                let s = max(r.lowerBound, range.lowerBound) - range.lowerBound, e = min(r.upperBound, range.upperBound) - range.lowerBound
                for i in s..<e { if let h = own[i] { styles[i] = h } }
                if q.strikes { for i in s..<e where ownStruck[i] { struck[i] = true } }
            }
            for child in layer.children where child.start < range.upperBound && child.end > range.lowerBound { paint(child) }
        }
        // Layers start in order; those starting past the range can't reach it.
        let end = layers.partitionIndex { $0.start >= range.upperBound }
        for layer in layers[..<end] where layer.end > range.lowerBound { paint(layer) }
        var out: [HighlightSpan] = []
        var i = 0
        while i < styles.count {
            let h = styles[i] ?? .none, s = struck[i]
            var j = i + 1
            while j < styles.count && (styles[j] ?? .none) == h && struck[j] == s { j += 1 }
            if h != .none || s { out.append(HighlightSpan(range: range.lowerBound + i..<range.lowerBound + j, highlight: h, struck: s)) }
            i = j
        }
        return out
    }
}

// MARK: - tree-sitter objects

/// Owns a tree. Edited only by whoever holds it; other threads get copies (copying is cheap).
final class TreeBox: @unchecked Sendable {
    let tree: OpaquePointer
    init(_ tree: OpaquePointer) { self.tree = tree }
    func copy() -> TreeBox { TreeBox(ts_tree_copy(tree)) }

    /// Freeing a big tree takes milliseconds, so it happens off the main thread (subtrees are
    /// reference counted atomically, so copies elsewhere aren't disturbed).
    deinit {
        let doomed = Doomed(tree: tree)
        Self.reaper.async { ts_tree_delete(doomed.tree) }
    }

    private struct Doomed: @unchecked Sendable { let tree: OpaquePointer }
    private static let reaper = DispatchQueue(label: "Vie.syntax.free", qos: .utility)
}

final class CursorBox: @unchecked Sendable {
    let pointer = ts_query_cursor_new()!
    deinit { ts_query_cursor_delete(pointer) }
}

/// An injected language's tree over part of the text, and the layers injected into it.
struct Layer: @unchecked Sendable {
    let language: SyntaxLanguage
    var ranges: [Range<Int>]
    let tree: TreeBox
    /// Layers inside this one (a paragraph's inline HTML or math), kept or dropped with it.
    var children: [Layer] = []
    var start: Int { ranges.first?.lowerBound ?? 0 }
    var end: Int { ranges.last?.upperBound ?? 0 }
    /// This layer and those inside it.
    var count: Int { children.reduce(1) { $0 + $1.count } }

    mutating func apply(_ edit: TSInputEdit) {
        var e = edit
        ts_tree_edit(tree.tree, &e)
        ranges = ranges.map { SyntaxHighlighter.map($0, through: edit) }.filter { !$0.isEmpty }
        for i in children.indices { children[i].apply(edit) }
    }

    /// The same layers over copies of the trees, for another thread to read while these are
    /// edited.
    func copy() -> Layer {
        Layer(language: language, ranges: ranges, tree: tree.copy(), children: children.map { $0.copy() })
    }
}

/// What a layer covers: its language and ranges.
struct LayerKey: Hashable {
    let language: String
    let ranges: [Range<Int>]
    init(_ language: SyntaxLanguage, _ ranges: [Range<Int>]) {
        self.language = language.name
        self.ranges = ranges
    }
}

/// One parser per language, used only on the syntax queue.
final class ParserPool: @unchecked Sendable {
    private var parsers: [String: OpaquePointer] = [:]

    func parse(_ rope: Rope, language: SyntaxLanguage, old: TreeBox?, ranges: [TSRange]?) -> TreeBox? {
        let parser: OpaquePointer
        if let p = parsers[language.name] {
            parser = p
        } else {
            parser = ts_parser_new()
            ts_parser_set_language(parser, language.pointer)
            parsers[language.name] = parser
        }
        if let ranges {
            guard ranges.withUnsafeBufferPointer({ ts_parser_set_included_ranges(parser, $0.baseAddress, UInt32($0.count)) }) else { return nil }
        } else {
            ts_parser_set_included_ranges(parser, nil, 0)
        }
        let reader = RopeReader(rope)
        let input = TSInput(payload: Unmanaged.passUnretained(reader).toOpaque(), read: ropeRead,
                            encoding: TSInputEncodingUTF8, decode: nil)
        let tree = withExtendedLifetime(reader) { ts_parser_parse(parser, old?.tree, input) }
        return tree.map(TreeBox.init)
    }

    deinit { for p in parsers.values { ts_parser_delete(p) } }
}

/// Hands tree-sitter the text a rope leaf at a time, copied into a buffer it owns.
private final class RopeReader {
    let rope: Rope
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 8192)
    init(_ rope: Rope) { self.rope = rope }
    deinit { buffer.deallocate() }
}

private func ropeRead(_ payload: UnsafeMutableRawPointer?, _ index: UInt32, _ point: TSPoint,
                      _ bytesRead: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<CChar>? {
    let reader = Unmanaged<RopeReader>.fromOpaque(payload!).takeUnretainedValue()
    let n = reader.rope.copyChunk(from: Int(index), into: reader.buffer)
    bytesRead?.pointee = UInt32(n)
    return UnsafeRawPointer(reader.buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
}

extension Array {
    /// The first index whose element satisfies `pred`, for an array where it's false then true.
    func partitionIndex(where pred: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
