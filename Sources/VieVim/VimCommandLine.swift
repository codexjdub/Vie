import Foundation
import VieText

/// A search offset: `/foo/e`, `/foo/s+2`, `/foo/+1`.
struct SearchOffset: Equatable {
    enum Kind: Equatable { case none, line, end, start }
    var kind: Kind = .none
    var amount = 0
}

struct PendingOperator {
    var op: Operator
    var register: Character?
    var count: Int?
    var start: Int
}

struct CommandLineState {
    var kind: Character
    var text: [Character]
    var cursor: Int
    var origin: VimMode
    var pendingOp: PendingOperator?
    var startCursor: Int
    var count: Int?
    var topLine: Int
    /// The history entry shown, while stepping through the history.
    var historyIndex: Int?
    /// While stepping through the history: the line as typed, and the part of it before the
    /// cursor, which ↑ and ↓ match entries against.
    var historyTyped: (text: [Character], prefix: [Character])?
    var awaitingRegister = false
    var awaitingLiteral = false
}

extension VimEngine {
    // MARK: - Typing the command line

    func startCommandLine(_ kind: Character, pendingOp: PendingOperator?, count: Int?, initial: String = "") {
        if kind == ":" && mode.isVisual { endVisual() }
        cmdline = CommandLineState(kind: kind, text: Array(initial), cursor: initial.count, origin: mode, pendingOp: pendingOp,
                                   startCursor: cursor, count: count, topLine: host?.visibleLines.lowerBound ?? 0)
        mode = .commandLine
        message = nil
        incsearchRange = nil
    }

    func commandLineKey(_ key: VimKey) {
        guard var s = cmdline else {
            mode = .normal
            return
        }
        if s.pendingOp != nil && replaying == 0 { dotPending?.keys.append(key) }
        let recall = [VimKey.up, .down, .ctrl("p"), .ctrl("n")].contains(key) && !s.awaitingRegister && !s.awaitingLiteral
        if !recall && s.historyTyped != nil {
            // Any other key ends the stepping; the next ↑ matches the line as it is then.
            s.historyIndex = nil
            s.historyTyped = nil
            cmdline = s
        }
        if s.awaitingRegister {
            s.awaitingRegister = false
            cmdline = s
            let t = key == .ctrl("w") ? currentWordText(pos(s.startCursor)) : register(named: key.character)?.text
            if let t { insertCommandText(t.replacingOccurrences(of: "\n", with: "\r")) }
            return
        }
        if s.awaitingLiteral {
            s.awaitingLiteral = false
            cmdline = s
            insertCommandText(String(key.character))
            return
        }
        switch key.character {
        case "\u{1B}", "\u{03}":
            cancelCommandLine()
        case "\r", "\n":
            finishCommandLine()
        case "\u{08}", "\u{7F}":
            if s.text.isEmpty { return cancelCommandLine() }
            if s.cursor > 0 {
                s.text.remove(at: s.cursor - 1)
                s.cursor -= 1
            }
            cmdline = s
        case "\u{F728}":
            if s.cursor < s.text.count { s.text.remove(at: s.cursor) }
            cmdline = s
        case "\u{17}":
            var c = s.cursor
            while c > 0 && s.text[c - 1] == " " { c -= 1 }
            let word = c > 0 && (s.text[c - 1].isLetter || s.text[c - 1].isNumber || s.text[c - 1] == "_")
            while c > 0 && s.text[c - 1] != " " && (s.text[c - 1].isLetter || s.text[c - 1].isNumber || s.text[c - 1] == "_") == word { c -= 1 }
            s.text.removeSubrange(c..<s.cursor)
            s.cursor = c
            cmdline = s
        case "\u{15}":
            s.text.removeSubrange(0..<s.cursor)
            s.cursor = 0
            cmdline = s
        case "\u{F702}": s.cursor = max(0, s.cursor - 1); cmdline = s
        case "\u{F703}": s.cursor = min(s.text.count, s.cursor + 1); cmdline = s
        case "\u{F729}", "\u{02}": s.cursor = 0; cmdline = s
        case "\u{F72B}", "\u{05}": s.cursor = s.text.count; cmdline = s
        case "\u{F700}", "\u{F701}", "\u{10}", "\u{0E}":
            // As in Vim: ↑ and ↓ step through the entries that begin with what was typed
            // before the cursor, ⌃P and ⌃N through all of them; past the newest, the typed
            // line comes back. With nothing further that way, the line stays.
            let list = history[historyKey(s.kind)] ?? []
            let typed = s.historyTyped ?? (s.text, Array(s.text[..<s.cursor]))
            let prefix = key == .up || key == .down ? String(typed.prefix) : ""
            let up = key == .up || key == .ctrl("p")
            let current = s.historyIndex ?? list.count
            let next = up ? list[..<current].lastIndex { $0.hasPrefix(prefix) }
                : s.historyIndex == nil ? nil : list[(current + 1)...].firstIndex { $0.hasPrefix(prefix) } ?? list.count
            guard let next else { return }
            s.historyTyped = typed
            s.historyIndex = next < list.count ? next : nil
            s.text = next < list.count ? Array(list[next]) : typed.text
            s.cursor = s.text.count
            cmdline = s
        case "\u{12}":
            s.awaitingRegister = true
            cmdline = s
        case "\u{16}", "\u{11}":
            s.awaitingLiteral = true
            cmdline = s
        case "\t":
            return
        default:
            if key.isText { insertCommandText(String(key.character)) } else { beep() }
            return
        }
        updateIncsearch()
    }

    func insertCommandText(_ t: String) {
        guard var s = cmdline else { return }
        s.text.insert(contentsOf: Array(t), at: s.cursor)
        s.cursor += t.count
        cmdline = s
        updateIncsearch()
    }

    func cancelCommandLine() {
        guard let s = cmdline else { return }
        cmdline = nil
        mode = s.origin == .commandLine ? .normal : s.origin
        incsearchRange = nil
        if s.kind != ":" && options.incsearch { host?.vimScroll(toTopLine: s.topLine) }
        if s.pendingOp != nil { dotPending = nil }
        cursor = s.startCursor
        if mode == .normal { cursor = clampNormal(cursor) }
        syncSelection()
    }

    func finishCommandLine() {
        guard let s = cmdline else { return }
        cmdline = nil
        incsearchRange = nil
        mode = s.origin == .commandLine ? .normal : s.origin
        let text = String(s.text)
        if s.kind == ":" {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lastCommandLine = text
                addHistory(":", text)
            }
            executeEx(text)
            if mode == .normal { cursor = clampNormal(cursor) }
            syncSelection()
            return
        }
        let forward = s.kind == "/"
        let (patternText, searchOffset) = splitSearch(text, delimiter: s.kind)
        var pattern = patternText
        if pattern.isEmpty {
            guard let last = lastSearch else {
                if s.pendingOp != nil { dotPending = nil }
                return fail("E35: No previous regular expression")
            }
            pattern = last.pattern
        }
        lastSearch = (pattern, forward, searchOffset)
        addHistory("/", text)
        highlightSearch = true
        if let op = s.pendingOp {
            guard let r = searchMotion(pattern, forward: forward, offset: searchOffset, count: max(op.count ?? 1, 1), from: op.start) else {
                dotPending = nil
                return
            }
            marks["'"] = op.start
            cursor = op.start
            applyMotionOperator(op.op, from: pos(op.start), r, register: op.register, count: op.count)
            finishChangeIfComplete()
            return
        }
        guard let r = searchMotion(pattern, forward: forward, offset: searchOffset, count: max(s.count ?? 1, 1), from: s.startCursor) else {
            cursor = s.startCursor
            syncSelection()
            return
        }
        marks["'"] = s.startCursor
        cursor = offset(mode.isVisual ? r.pos : clampNormal(r.pos))
        updateCurswant()
        syncSelection()
    }

    /// Searches (`/` and `?`) share one history, as in Vim; `:` commands have their own.
    func historyKey(_ kind: Character) -> Character { kind == ":" ? ":" : "/" }

    func addHistory(_ kind: Character, _ text: String) {
        let kind = historyKey(kind)
        var list = history[kind] ?? []
        list.removeAll { $0 == text }
        list.append(text)
        if list.count > 100 { list.removeFirst(list.count - 100) }
        history[kind] = list
    }

    /// Splits `foo/e+1` into the pattern and its offset (at the first unescaped delimiter).
    func splitSearch(_ text: String, delimiter: Character) -> (String, SearchOffset) {
        let chars = Array(text)
        var i = 0
        var inSet = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" { inSet = true } else if c == "]" { inSet = false }
            if c == delimiter && !inSet { break }
            i += 1
        }
        let pattern = String(chars[0..<min(i, chars.count)])
        guard i < chars.count else { return (pattern, SearchOffset()) }
        var rest = String(chars[(i + 1)...])
        var off = SearchOffset()
        if let f = rest.first, "esb".contains(f) {
            off.kind = f == "e" ? .end : .start
            rest.removeFirst()
            off.amount = rest.isEmpty ? 0 : (Int(rest) ?? (rest == "+" ? 1 : rest == "-" ? -1 : 0))
        } else if !rest.isEmpty {
            off.kind = .line
            off.amount = Int(rest) ?? (rest == "+" ? 1 : rest == "-" ? -1 : 0)
        }
        return (pattern, off)
    }

    // MARK: - Searching

    func compile(_ pattern: String, smartCase: Bool = true) -> VimPattern? {
        let key = "\(pattern)\u{0}\(options.ignorecase)\(options.smartcase)\(smartCase)\(lastReplacement ?? "")"
        if let c = patternCache, c.key == key { return c.pattern }
        guard let p = try? VimPattern(pattern, ignoreCase: options.ignorecase, smartCase: options.smartcase,
                                      useSmartCase: smartCase, lastReplacement: lastReplacement) else { return nil }
        patternCache = (key, p)
        return p
    }

    /// The `count`th match of `pattern` from `from`, as a motion with the offset applied.
    func searchMotion(_ pattern: String, forward: Bool, offset off: SearchOffset, count: Int, from: Int, smartCase: Bool = true) -> MotionResult? {
        guard let compiled = compile(pattern, smartCase: smartCase) else {
            fail("E486: Pattern not found: \(pattern)")
            return nil
        }
        // As Vim does, step back over a character offset first, so "/x/e-1" and "?x?s+1"
        // don't find the match they started on again.
        var at = off.kind == .end || off.kind == .start ? offset(stepChars(pos(from), -off.amount)) : from
        var found: Range<Int>?
        var wrapped = false
        for _ in 0..<count {
            let endAfter = off.kind == .end && forward ? rope.nextGraphemeBoundary(after: at) : nil
            guard let (r, w) = compiled.find(in: rope, from: at, forward: forward, wrap: options.wrapscan, endAfter: endAfter) else {
                if options.wrapscan {
                    fail("E486: Pattern not found: \(pattern)")
                } else {
                    fail(forward ? "E385: Search hit BOTTOM without match for: \(pattern)" : "E384: Search hit TOP without match for: \(pattern)")
                }
                return nil
            }
            found = r
            at = r.lowerBound
            wrapped = wrapped || w
        }
        guard let r = found else { return nil }
        if wrapped { show(forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM", error: true) }
        var p = pos(r.lowerBound)
        var kind = MotionKind.exclusive
        switch off.kind {
        case .none:
            break
        case .line:
            let line = min(max(p.line + off.amount, 0), lastLine)
            return MotionResult(pos: Pos(line, firstNonBlank(line)), kind: .linewise, jump: true, useRegOne: true)
        case .end:
            p = pos(r.isEmpty ? r.lowerBound : rope.previousGraphemeBoundary(before: r.upperBound))
            p = stepChars(p, off.amount)
            kind = .inclusive
        case .start:
            p = stepChars(p, off.amount)
            if off.amount > 0 { kind = .inclusive }
        }
        return MotionResult(pos: p, kind: kind, jump: true, useRegOne: true)
    }

    /// Moves `n` characters (negative: back) across lines.
    func stepChars(_ p: Pos, _ n: Int) -> Pos {
        var p = p
        if n > 0 { for _ in 0..<n { if incl(&p) == -1 { break } } }
        if n < 0 { for _ in 0..<(-n) { if decl(&p) == -1 { break } } }
        return p
    }

    /// The keyword under or after the cursor as a search pattern (`\<word\>` when `whole`),
    /// and the column where it starts.
    func wordUnderCursor(_ p: Pos, whole: Bool) -> (String, Int)? {
        let b = text(p.line)
        func cl(_ c: Int) -> Int { c < b.count ? (isBlank(b[c]) ? 0 : vimClass(scalarAt(b, c))) : 0 }
        var start = 0, end = 0
        var found = false
        for pass in 0..<2 {
            var col = p.col
            while col < b.count {
                let k = cl(col)
                if k != 0 && (pass == 1 || k != 1) { break }
                col = nextCharCol(b, col)
            }
            guard col < b.count else { continue }
            let k = cl(col)
            while col > 0 {
                let prev = prevCharCol(b, col)
                if cl(prev) != k { break }
                col = prev
            }
            start = col
            end = col
            while end < b.count && (pass == 0 ? cl(end) == k : cl(end) != 0) { end = nextCharCol(b, end) }
            if pass == 0 && k < 2 { continue }
            found = true
            break
        }
        guard found, end > start else { return nil }
        let word = String(decoding: b[start..<end], as: UTF8.self)
        var escaped = ""
        for ch in word { escaped += "/.*~[^$\\?".contains(ch) ? "\\" + String(ch) : String(ch) }
        var pattern = escaped
        if whole {
            if isKeywordChar(b, start) { pattern = "\\<" + pattern }
            if isKeywordChar(b, prevCharCol(b, end)) { pattern += "\\>" }
        }
        return (pattern, start)
    }

    func currentWordText(_ p: Pos) -> String {
        guard let (_, start) = wordUnderCursor(p, whole: false) else { return "" }
        let b = text(p.line)
        var end = start
        let k = vimClass(scalarAt(b, start))
        while end < b.count && !isBlank(b[end]) && vimClass(scalarAt(b, end)) == k { end = nextCharCol(b, end) }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    // MARK: - Highlighting

    /// While typing a search, moves the view to the first match.
    func updateIncsearch() {
        guard let s = cmdline, s.kind != ":", options.incsearch else {
            incsearchRange = nil
            return
        }
        let (pattern, _) = splitSearch(String(s.text), delimiter: s.kind)
        guard !pattern.isEmpty, let compiled = compile(pattern) else {
            incsearchRange = nil
            host?.vimScroll(toTopLine: s.topLine)
            return
        }
        let from = s.pendingOp?.start ?? s.startCursor
        guard let (r, _) = compiled.find(in: rope, from: from, forward: s.kind == "/", wrap: options.wrapscan) else {
            incsearchRange = nil
            host?.vimScroll(toTopLine: s.topLine)
            return
        }
        incsearchRange = r
        if let visible = host?.visibleLines {
            let line = rope.line(at: r.lowerBound)
            if !visible.contains(line) { host?.vimScroll(toTopLine: max(line - visible.count / 2, 0)) }
            else { host?.vimScroll(toTopLine: s.topLine) }
        }
    }

    /// Matches of the current search pattern in `range`, for 'hlsearch' (and the pattern
    /// being typed, with 'incsearch').
    public func searchHighlights(in range: Range<Int>) -> [Range<Int>] {
        var pattern: String?
        if let s = cmdline, s.kind != ":", options.incsearch {
            let p = splitSearch(String(s.text), delimiter: s.kind).0
            if !p.isEmpty { pattern = p }
        } else if options.hlsearch && highlightSearch {
            pattern = lastSearch?.pattern
        }
        guard let pattern, let compiled = compile(pattern) else { return [] }
        let lo = rope.lineStart(containing: range.lowerBound)
        let hi = min(rope.byteCount, rope.lineEnd(containing: range.upperBound) + 1)
        return compiled.matches(in: rope, lo..<hi, limit: 10_000).map(\.range)
    }

    // MARK: - Ex commands

    /// Runs one command-line command (without the `:`).
    func executeEx(_ line: String) {
        var s = Substring(line)
        func skipSpace() { while let f = s.first, f == " " || f == "\t" || f == ":" { s.removeFirst() } }
        skipSpace()
        guard !s.isEmpty else { return }
        if s.first == "\"" { return }
        let range: ExRange
        switch parseRange(&s) {
        case .failure(let e): return fail(e.message)
        case .success(let r): range = r
        }
        skipSpace()
        var name = ""
        if let f = s.first, f.isLetter {
            while let f = s.first, f.isLetter { name.append(f); s.removeFirst() }
        } else if let f = s.first {
            name = String(f)
            s.removeFirst()
            if name == "&", s.first == "&" { name = "&&"; s.removeFirst() }
            if f == ">" || f == "<" { while s.first == f { name.append(s.removeFirst()) } }
        }
        var bang = false
        if s.first == "!" && !name.isEmpty && name != "&&" {
            bang = true
            s.removeFirst()
        }
        let args = s.trimmingCharacters(in: .whitespaces)
        runEx(name, range: range, bang: bang, args: args, rawArgs: String(s))
    }

    struct ExError: Error { let message: String }

    struct ExRange {
        var first: Int
        var last: Int
        /// Number of addresses typed (0: none, the command's default applies).
        var count: Int
    }

    func parseRange(_ s: inout Substring) -> Result<ExRange, ExError> {
        var current = cursorPos.line
        var addresses: [Int] = []
        if s.first == "%" {
            s.removeFirst()
            addresses = [0, lastLine]
        } else {
            while true {
                while s.first == " " { s.removeFirst() }
                switch parseAddress(&s, current: current) {
                case .failure(let e): return .failure(e)
                case .success(let a):
                    guard let a else {
                        if s.first == "," || s.first == ";" {
                            addresses.append(current)
                        } else {
                            break
                        }
                        break
                    }
                    addresses.append(a)
                }
                if s.first == "," {
                    s.removeFirst()
                    if addresses.isEmpty { addresses.append(current) }
                    continue
                }
                if s.first == ";" {
                    s.removeFirst()
                    if let last = addresses.last { current = last }
                    continue
                }
                break
            }
        }
        if addresses.count > 2 { addresses = Array(addresses.suffix(2)) }
        for a in addresses where a < 0 || a > lastLine {
            return .failure(ExError(message: "E16: Invalid range"))
        }
        switch addresses.count {
        case 0: return .success(ExRange(first: cursorPos.line, last: cursorPos.line, count: 0))
        case 1: return .success(ExRange(first: addresses[0], last: addresses[0], count: 1))
        default:
            let a = min(addresses[0], addresses[1]), b = max(addresses[0], addresses[1])
            return .success(ExRange(first: a, last: b, count: 2))
        }
    }

    /// One address: a line number, `.`, `$`, `'x`, `/pat/`, `?pat?`, plus `+n` / `-n`.
    /// Returns nil when there is none.
    func parseAddress(_ s: inout Substring, current: Int) -> Result<Int?, ExError> {
        var base: Int?
        guard let f = s.first else { return .success(nil) }
        if f.isNumber {
            var n = 0
            while let d = s.first?.wholeNumberValue, s.first!.isASCII { n = n * 10 + d; s.removeFirst() }
            base = n - 1
        } else if f == "." {
            s.removeFirst()
            base = current
        } else if f == "$" {
            s.removeFirst()
            base = lastLine
        } else if f == "'" {
            s.removeFirst()
            guard let m = s.first else { return .failure(ExError(message: "E20: Mark not set")) }
            s.removeFirst()
            guard let off = markOffset(m) else { return .failure(ExError(message: "E20: Mark not set")) }
            base = rope.line(at: off)
        } else if f == "/" || f == "?" {
            s.removeFirst()
            var pat = ""
            while let c = s.first, c != f {
                if c == "\\", s.count > 1 { pat.append(c); s.removeFirst() }
                pat.append(s.removeFirst())
            }
            if s.first == f { s.removeFirst() }
            if pat.isEmpty { pat = lastSearch?.pattern ?? "" }
            guard !pat.isEmpty, let compiled = compile(pat) else { return .failure(ExError(message: "E35: No previous regular expression")) }
            lastSearch = (pat, f == "/", SearchOffset())
            let from = f == "/" ? rope.lineEnd(current) : lineStart(current)
            guard let (r, _) = compiled.find(in: rope, from: from, forward: f == "/", wrap: options.wrapscan) else {
                return .failure(ExError(message: "E486: Pattern not found: \(pat)"))
            }
            base = rope.line(at: r.lowerBound)
        } else if f == "\\" {
            s.removeFirst()
            guard let k = s.first, "/?&".contains(k) else { return .failure(ExError(message: "E10: \\ should be followed by /, ? or &")) }
            s.removeFirst()
            let pat = k == "&" ? (lastSubstitute?.pattern ?? "") : (lastSearch?.pattern ?? "")
            guard !pat.isEmpty, let compiled = compile(pat) else { return .failure(ExError(message: "E35: No previous regular expression")) }
            let fwd = k != "?"
            let from = fwd ? rope.lineEnd(current) : lineStart(current)
            guard let (r, _) = compiled.find(in: rope, from: from, forward: fwd, wrap: options.wrapscan) else {
                return .failure(ExError(message: "E486: Pattern not found: \(pat)"))
            }
            base = rope.line(at: r.lowerBound)
        }
        // Offsets.
        while let c = s.first, c == "+" || c == "-" || (base != nil && c.isNumber) {
            if base == nil { base = current }
            var sign = 1
            if c == "+" || c == "-" {
                sign = c == "-" ? -1 : 1
                s.removeFirst()
            }
            var n = 0, any = false
            while let d = s.first?.wholeNumberValue, s.first!.isASCII { n = n * 10 + d; s.removeFirst(); any = true }
            base! += sign * (any ? n : 1)
        }
        return .success(base)
    }

    private func matches(_ name: String, _ full: String, min: Int) -> Bool {
        name.count >= min && full.hasPrefix(name)
    }

    func runEx(_ name: String, range: ExRange, bang: Bool, args: String, rawArgs: String) {
        let lines = range.first...range.last
        func countRange(_ text: String) -> (ClosedRange<Int>, String)? {
            // A trailing count makes the range start at its last line: ":d 3".
            let parts = text.split(separator: " ").map(String.init)
            if let last = parts.last, let n = Int(last), n > 0 {
                let first = range.last
                let lastL = min(first + n - 1, lastLine)
                return (first...lastL, parts.dropLast().joined(separator: " "))
            }
            return nil
        }
        func registerArg(_ text: String) -> (Character?, String) {
            if let f = text.first, !f.isNumber, Registers.isValid(f) { return (f, String(text.dropFirst()).trimmingCharacters(in: .whitespaces)) }
            return (nil, text)
        }

        if name.isEmpty {
            // ":12" goes to line 12.
            guard range.count > 0 else { return }
            marks["'"] = cursor
            cursor = lineStart(range.last) + firstNonBlank(range.last)
            updateCurswant()
            return
        }
        if name == "s" || matches(name, "substitute", min: 2) || name == "&" || name == "&&" || name == "~" {
            if name == "&" || name == "&&" || name == "~" {
                substituteRepeat(lines: lines, keepFlags: name == "&&", flags: args, useSearchPattern: name == "~")
            } else {
                substitute(rawArgs, lines: lines)
            }
            return
        }
        if name.allSatisfy({ $0 == ">" }) || name.allSatisfy({ $0 == "<" }) {
            var ls = lines
            if let (r, _) = countRange(args) { ls = r }
            let r = OpRange(start: Pos(ls.lowerBound, 0), end: Pos(ls.upperBound, 0), kind: .line, inclusive: true)
            opShift(r, left: name.first == "<", amount: name.count)
            cursor = lineStart(ls.upperBound) + firstNonBlank(ls.upperBound)
            return
        }
        switch name {
        case _ where matches(name, "write", min: 1):
            perform(.write(path: args.isEmpty ? nil : args, force: bang))
        case "wq":
            perform(.writeQuit(path: args.isEmpty ? nil : args, force: bang))
        case _ where matches(name, "xit", min: 1) || matches(name, "exit", min: 3):
            perform(.exit(force: bang))
        case _ where matches(name, "update", min: 2):
            if buffer.isDirty { perform(.write(path: nil, force: bang)) }
        case _ where matches(name, "qall", min: 2) || matches(name, "quitall", min: 5):
            perform(.quitAll(force: bang))
        case _ where matches(name, "wall", min: 2):
            perform(.writeAll)
        case _ where matches(name, "wqall", min: 3) || matches(name, "xall", min: 2):
            perform(.writeQuitAll)
        case _ where matches(name, "quit", min: 1) || name == "close" || name == "clo" || matches(name, "tabclose", min: 4):
            perform(.quit(force: bang))
        case _ where matches(name, "ls", min: 2) || matches(name, "buffers", min: 7) || matches(name, "files", min: 5):
            perform(.listBuffers)
        case _ where matches(name, "bnext", min: 2) || matches(name, "tabnext", min: 4):
            perform(.nextBuffer(count: max(Int(args) ?? 1, 1)))
        case _ where matches(name, "bprevious", min: 2) || matches(name, "bNext", min: 2) || matches(name, "tabprevious", min: 4) || matches(name, "tabNext", min: 4):
            perform(.previousBuffer(count: max(Int(args) ?? 1, 1)))
        case _ where matches(name, "bdelete", min: 2):
            perform(.deleteBuffer(force: bang))
        case _ where matches(name, "buffer", min: 1):
            perform(.buffer(args.isEmpty && range.count > 0 ? String(range.last + 1) : args))
        case _ where matches(name, "tabedit", min: 4) || matches(name, "tabnew", min: 4):
            perform(.edit(path: args.isEmpty ? nil : args, force: bang))
        case _ where matches(name, "edit", min: 1):
            perform(.edit(path: args.isEmpty ? nil : args, force: bang))
        case _ where matches(name, "nohlsearch", min: 3):
            highlightSearch = false
        case _ where matches(name, "set", min: 2):
            // The language ('filetype') belongs to the host, which knows the grammars.
            let rest = args.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !filetypeArgument($0) }
            if let m = options.set(rest.joined(separator: " ")) { show(m, error: m.hasPrefix("E")) }
        case _ where matches(name, "normal", min: 4):
            exNormal(rawArgs.drop(while: { $0 == " " }), lines: range.count > 0 ? lines : nil)
        case _ where matches(name, "delete", min: 1):
            var (reg, rest) = registerArg(args)
            var ls = lines
            if let (r, rem) = countRange(rest) { ls = r; rest = rem }
            let r = OpRange(start: Pos(ls.lowerBound, 0), end: Pos(ls.upperBound, 0), kind: .line, inclusive: true)
            opDelete(r, register: reg)
            updateCurswant()
        case _ where matches(name, "yank", min: 1):
            var (reg, rest) = registerArg(args)
            var ls = lines
            if let (r, rem) = countRange(rest) { ls = r; rest = rem }
            let r = OpRange(start: Pos(ls.lowerBound, 0), end: Pos(ls.upperBound, 0), kind: .line, inclusive: true)
            storeYank(registerContent(r), reg)
        case _ where matches(name, "join", min: 1):
            var ls = lines
            if let (r, _) = countRange(args) { ls = r.lowerBound...min(r.upperBound + 1, lastLine) }
            var count = ls.count
            if range.count < 2 && countRange(args) == nil { count = 2 }
            if ls.lowerBound + count - 1 > lastLine { count = lastLine - ls.lowerBound + 1 }
            guard count >= 2 else { return }
            cursor = lineStart(ls.lowerBound)
            join(first: ls.lowerBound, count: count, spaces: !bang)
            cursor = lineStart(ls.lowerBound) + firstNonBlank(ls.lowerBound)
        case _ where matches(name, "put", min: 2):
            let (reg, _) = registerArg(args)
            guard let content = register(named: reg) else { return fail("E353: Nothing in register \(reg ?? "\"")") }
            var t = content.text
            if !t.hasSuffix("\n") { t += "\n" }
            let target = range.last
            let bytes = Array(t.utf8)
            let at: Int
            var ins = bytes
            if bang { at = lineStart(target) } else if target < lastLine { at = lineStart(target + 1) } else {
                at = rope.byteCount
                ins = [0x0A] + bytes.dropLast()
            }
            let n = bytes.filter { $0 == 0x0A }.count
            change(at: cursor) { replace(at..<at, with: ins, cursor: at) }
            let lastPut = (bang ? target : target + 1) + n - 1
            cursor = lineStart(min(lastPut, lastLine)) + firstNonBlank(min(lastPut, lastLine))
        case _ where matches(name, "move", min: 1):
            var t = Substring(args)
            guard case .success(let d) = parseAddress(&t, current: cursorPos.line), let dest = d else { return fail("E14: Invalid address") }
            moveLines(lines, below: dest, copy: false)
        case "t",
             _ where matches(name, "copy", min: 2):
            var t = Substring(args)
            guard case .success(let d) = parseAddress(&t, current: cursorPos.line), let dest = d else { return fail("E14: Invalid address") }
            moveLines(lines, below: dest, copy: true)
        case _ where matches(name, "undo", min: 1):
            undo(count: 1, redo: false)
        case _ where matches(name, "redo", min: 3):
            undo(count: 1, redo: true)
        case "k",
             _ where matches(name, "mark", min: 2):
            guard let m = args.first, m.isLetter || "'`<>[]".contains(m) else { return fail("E191: Argument must be a letter or forward/backward quote") }
            let saved = cursor
            cursor = lineStart(range.last)
            setMark(m)
            cursor = saved
        case "=":
            show("\(range.count > 0 ? range.last + 1 : lastLine + 1)")
        default:
            fail("E492: Not an editor command: \(name)\(bang ? "!" : "")\(rawArgs)")
        }
    }

    /// `ft=name`, `filetype:name`, `ft?` or `ft` from a `:set` command, handed to the host;
    /// false for any other argument.
    private func filetypeArgument(_ arg: String) -> Bool {
        for key in ["filetype", "ft"] {
            if arg == key || arg == key + "?" {
                perform(.showFiletype)
                return true
            }
            if arg.hasPrefix(key + "=") || arg.hasPrefix(key + ":") {
                perform(.setFiletype(String(arg.dropFirst(key.count + 1))))
                return true
            }
        }
        return false
    }

    func perform(_ command: VimFileCommand) {
        guard let host else { return fail("E32: No file name") }
        if let error = host.vimPerform(command) { fail(error) }
    }

    /// `:m` and `:t`: moves or copies lines below line `dest` (-1 for above the first).
    func moveLines(_ lines: ClosedRange<Int>, below dest: Int, copy: Bool) {
        guard dest >= -1 && dest <= lastLine else { return fail("E14: Invalid address") }
        if !copy && dest >= lines.lowerBound && dest < lines.upperBound { return fail("E134: Cannot move a range of lines into itself") }
        if !copy && (dest == lines.lowerBound - 1 || dest == lines.upperBound) {
            cursor = lineStart(lines.upperBound) + firstNonBlank(lines.upperBound)
            return
        }
        let textRange = lineStart(lines.lowerBound)..<rope.lineEnd(lines.upperBound)
        let block = rope.bytes(in: textRange)
        var changes: [Change] = []
        let insertAt: Int
        var ins: [UInt8]
        if dest < 0 {
            insertAt = 0
            ins = block + [0x0A]
        } else if dest == lastLine {
            insertAt = rope.byteCount
            ins = [0x0A] + block
        } else {
            insertAt = lineStart(dest + 1)
            ins = block + [0x0A]
        }
        changes.append(Change(insertAt..<insertAt, ins))
        if !copy { changes.append(Change(lineRange(lines.lowerBound, lines.upperBound, forDeletion: true), [])) }
        // Changes must not overlap; when moving down past the end, the two touch.
        changes.sort { $0.range.lowerBound < $1.range.lowerBound }
        if changes.count == 2 && changes[0].range.overlaps(changes[1].range) { return fail("E134: Cannot move a range of lines into itself") }
        change(at: cursor) { edit(changes, cursor: cursor) }
        let movedLast: Int
        if copy || dest < lines.lowerBound {
            movedLast = dest + lines.count
        } else {
            movedLast = dest
        }
        let line = min(max(movedLast, 0), lastLine)
        cursor = lineStart(line) + firstNonBlank(line)
        updateCurswant()
    }

    /// `:normal {keys}`: runs keys as typed on each line of the range (or once), ending any
    /// unfinished command.
    func exNormal(_ keysText: Substring, lines: ClosedRange<Int>?) {
        let keys = VimKey.keys(from: String(keysText))
        guard !keys.isEmpty else { return }
        mode = .normal
        func runOnce() {
            macroDepth += 1
            run(keys, stopOnFailure: true)
            timeoutPending()
            macroDepth -= 1
            if mode == .insert || mode == .replace { process(.escape) }
            if mode == .commandLine { cancelCommandLine() }
            if mode.isVisual { endVisual() }
            pending = []
        }
        if let lines {
            // Lines are tracked through edits made on earlier ones.
            var starts = lines.map { lineStart($0) }
            trackEdits += 1
            defer { trackEdits -= 1 }
            for i in starts.indices {
                guard starts[i] <= rope.byteCount else { continue }
                cursor = starts[i]
                curswant = 0
                syncSelection()
                let logStart = editLog.count
                runOnce()
                let edits = Array(editLog[logStart...])
                if !edits.isEmpty {
                    for j in (i + 1)..<starts.count { starts[j] = VimEngine.map(starts[j], through: edits) }
                }
            }
            if trackEdits == 1 { editLog = [] }
        } else {
            runOnce()
        }
        failed = false
    }

    // MARK: - :s

    func substitute(_ args: String, lines: ClosedRange<Int>) {
        let chars = Array(args)
        guard let delim = chars.first, !delim.isLetter, !delim.isNumber, delim != "\\", delim != "\"", delim != "|", delim != " " else {
            return substituteRepeat(lines: lines, keepFlags: false, flags: args.trimmingCharacters(in: .whitespaces))
        }
        var i = 1
        func field() -> String? {
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\" && i + 1 < chars.count {
                    out.append(c)
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == delim { i += 1; return out }
                out.append(c)
                i += 1
            }
            return out
        }
        let pattern = field() ?? ""
        let replacement = i <= chars.count ? (field() ?? "") : ""
        let rest = i < chars.count ? String(chars[i...]).trimmingCharacters(in: .whitespaces) : ""
        doSubstitute(pattern: pattern, replacement: replacement, flagsAndCount: rest, lines: lines)
    }

    func substituteRepeat(lines: ClosedRange<Int>, keepFlags: Bool, flags: String = "", useSearchPattern: Bool = false) {
        guard let last = lastSubstitute else { return fail("E35: No previous regular expression") }
        var f = flags
        if keepFlags { f = last.flags + f }
        let pattern = useSearchPattern ? (lastSearch?.pattern ?? last.pattern) : last.pattern
        doSubstitute(pattern: pattern, replacement: "~", flagsAndCount: f, lines: lines, previousReplacement: last.replacement)
    }

    func doSubstitute(pattern rawPattern: String, replacement rawReplacement: String, flagsAndCount: String,
                      lines: ClosedRange<Int>, previousReplacement previous: String? = nil) {
        var flagsText = flagsAndCount
        if flagsText.hasPrefix("&") {
            flagsText = (lastSubstitute?.flags ?? "") + flagsText.dropFirst()
        }
        var flags = ""
        var countText = ""
        for c in flagsText {
            if "cegiInp#lr".contains(c) && countText.isEmpty { flags.append(c) } else if c.isNumber { countText.append(c) } else if c != " " { return fail("E488: Trailing characters: \(flagsAndCount)") }
        }
        var lines = lines
        if let n = Int(countText), n > 0 {
            lines = lines.upperBound...min(lines.upperBound + n - 1, lastLine)
        }
        var pattern = rawPattern
        if pattern.isEmpty {
            guard let last = lastSearch?.pattern ?? lastSubstitute?.pattern else { return fail("E35: No previous regular expression") }
            pattern = last
        }
        // `~` in the replacement is the previous replacement.
        var replacement = ""
        let prev = previous ?? lastReplacement ?? ""
        let rc = Array(rawReplacement)
        var k = 0
        while k < rc.count {
            if rc[k] == "\\" && k + 1 < rc.count {
                replacement.append(rc[k])
                replacement.append(rc[k + 1])
                k += 2
                continue
            }
            if rc[k] == "~" { replacement += prev } else { replacement.append(rc[k]) }
            k += 1
        }
        if previous != nil && rawReplacement == "~" { replacement = prev }
        lastReplacement = replacement
        lastSubstitute = (pattern, replacement, flags.filter { "gciI".contains($0) })
        lastSearch = (pattern, lastSearch?.forward ?? true, SearchOffset())
        highlightSearch = true

        var ignore = options.ignorecase
        if flags.contains("i") { ignore = true }
        if flags.contains("I") { ignore = false }
        guard let compiled = try? VimPattern(pattern, ignoreCase: ignore, smartCase: options.smartcase && !flags.contains("i") && !flags.contains("I"),
                                             lastReplacement: lastReplacement) else {
            return fail("E486: Pattern not found: \(pattern)")
        }
        let global = flags.contains("g")
        let countOnly = flags.contains("n")
        let rangeStart = lineStart(lines.lowerBound)
        let rangeEnd = lines.upperBound < lastLine ? lineStart(lines.upperBound + 1) : rope.byteCount
        var changes: [Change] = []
        var matchCount = 0
        var lastLineMatched = -1
        var linesChanged = Set<Int>()
        var chunkStart = rangeStart
        while chunkStart < rangeEnd || (chunkStart == rangeEnd && rangeStart == rangeEnd) {
            var chunkEnd = min(rangeEnd, chunkStart + 256 * 1024)
            if chunkEnd < rangeEnd { chunkEnd = min(rangeEnd, rope.lineEnd(containing: chunkEnd) + 1) }
            for m in compiled.matches(in: rope, chunkStart..<chunkEnd) {
                let start = m.range.lowerBound
                // A match right after the final line break belongs to the next line.
                if start == chunkEnd && chunkEnd > chunkStart && rope.byte(at: chunkEnd - 1) == 0x0A { continue }
                let line = rope.line(at: start)
                if line > lines.upperBound { continue }
                if !global && line == lastLineMatched { continue }
                if let prev = changes.last, prev.range.upperBound > start { continue }
                lastLineMatched = line
                matchCount += 1
                linesChanged.insert(line)
                if countOnly { continue }
                let text = substitution(replacement, m.result, compiled, m.map)
                changes.append(Change(m.range, text))
            }
            if chunkEnd >= rangeEnd { break }
            chunkStart = chunkEnd
        }
        guard matchCount > 0 else {
            if !flags.contains("e") { fail("E486: Pattern not found: \(pattern)") }
            return
        }
        if countOnly {
            show("\(matchCount) match\(matchCount == 1 ? "" : "es") on \(linesChanged.count) line\(linesChanged.count == 1 ? "" : "s")")
            return
        }
        // Where the last change starts once all of them are made.
        var shift = 0
        for c in changes.dropLast() { shift += c.text.count - c.range.count }
        let lastStart = changes.last!.range.lowerBound + shift
        let lastEnd = lastStart + changes.last!.text.count
        change(at: cursor) { edit(changes, cursor: lastStart) }
        let line = rope.line(at: min(lastEnd, rope.byteCount))
        cursor = lineStart(line) + firstNonBlank(line)
        updateCurswant()
        if matchCount > 2 {
            show("\(matchCount) substitution\(matchCount == 1 ? "" : "s") on \(linesChanged.count) line\(linesChanged.count == 1 ? "" : "s")")
        }
    }

    /// The text replacing one match: `&` and `\0`–`\9` groups, `\r` line breaks, `\n` NUL,
    /// `\t`, `\u` `\l` `\U` `\L` `\e` case changes, and `\=submatch(n)`.
    func substitution(_ rep: String, _ m: NSTextCheckingResult, _ p: VimPattern, _ map: ChunkMap) -> [UInt8] {
        func group(_ n: Int) -> String { map.substring(p.group(m, n)) }
        if rep.hasPrefix("\\=") {
            let expr = rep.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if expr.hasPrefix("submatch("), expr.hasSuffix(")"), let n = Int(expr.dropFirst(9).dropLast()) {
                return Array(group(n).utf8)
            }
            return Array(expr.utf8)
        }
        var out = ""
        var one: CaseChange?
        var all: CaseChange?
        func emit(_ s: String) {
            for ch in s {
                var t = String(ch)
                if let c = one {
                    t = c == .upper ? t.uppercased() : t.lowercased()
                    one = nil
                } else if let c = all {
                    t = c == .upper ? t.uppercased() : t.lowercased()
                }
                out += t
            }
        }
        let chars = Array(rep)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                i += 2
                switch n {
                case "0"..."9": emit(group(n.wholeNumberValue!))
                case "n": out += "\u{0}"
                case "r": out += "\n"
                case "t": out += "\t"
                case "u": one = .upper
                case "l": one = .lower
                case "U": all = .upper
                case "L": all = .lower
                case "e", "E": all = nil; one = nil
                default: emit(String(n))
                }
                continue
            }
            i += 1
            switch c {
            case "&": emit(group(0))
            case "\r": out += "\n"
            default: emit(String(c))
            }
        }
        return Array(out.utf8)
    }
}
