/// Character, word and line boundaries on a rope. Every function looks only at a small
/// window of text around the offset, so cost doesn't grow with file size.

/// Classes used to split text into words. A word is a run of one class; marks and joiners
/// (`.extend`) belong to the character before them. Japanese scripts get their own classes,
/// so 日本語のテキスト splits into 日本語 · の · テキスト (as in Vim).
public enum CharClass: Sendable {
    case newline, whitespace, punctuation, word, han, hiragana, katakana, extend

    /// Classes that form words (as opposed to separators).
    public var isWord: Bool {
        switch self {
        case .word, .han, .hiragana, .katakana: true
        default: false
        }
    }

    public init(_ s: Unicode.Scalar) {
        switch s.value {
        case 0x0A: self = .newline
        case 0x09, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x3000: self = .whitespace
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: self = .word
        case 0..<0x80: self = .punctuation
        case 0x3040...0x309F: self = .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: self = .katakana
        default:
            let p = s.properties
            switch p.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format:
                self = .extend
            default:
                if p.isWhitespace { self = .whitespace }
                else if p.isIdeographic { self = .han }
                else if p.isAlphabetic || p.numericType != nil { self = .word }
                else { self = .punctuation }
            }
        }
    }
}

/// Decodes the scalar starting at `i` in valid UTF-8. Returns the scalar and its length.
@inline(__always) func decodeScalar(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> (Unicode.Scalar, Int) {
    let b0 = UInt32(p[i])
    let len = utf8Length(p[i])
    guard i + len <= p.count else { return ("\u{FFFD}", 1) }
    let v: UInt32
    switch len {
    case 1: v = b0
    case 2: v = (b0 & 0x1F) << 6 | UInt32(p[i + 1] & 0x3F)
    case 3: v = (b0 & 0x0F) << 12 | UInt32(p[i + 1] & 0x3F) << 6 | UInt32(p[i + 2] & 0x3F)
    default: v = (b0 & 0x07) << 18 | UInt32(p[i + 1] & 0x3F) << 12 | UInt32(p[i + 2] & 0x3F) << 6 | UInt32(p[i + 3] & 0x3F)
    }
    return (Unicode.Scalar(v) ?? "\u{FFFD}", len)
}

extension Rope {
    // MARK: - Scalars

    /// Calls `body` with each scalar from `off` forward and its offset, until it returns false.
    public func scanForward(from off: Int, _ body: (Unicode.Scalar, Int) -> Bool) {
        var pos = max(0, off)
        while pos < byteCount {
            let chunk = bytes(from: pos, maxBytes: 4096, stopAtNewline: false)
            if chunk.isEmpty { return }
            let keepGoing = chunk.withUnsafeBufferPointer { p -> Bool in
                var i = 0
                while i < p.count {
                    let (s, len) = decodeScalar(p, i)
                    if !body(s, pos + i) { return false }
                    i += len
                }
                return true
            }
            if !keepGoing { return }
            pos += chunk.count
        }
    }

    /// Calls `body` with each scalar before `off`, nearest first, until it returns false.
    public func scanBackward(from off: Int, _ body: (Unicode.Scalar, Int) -> Bool) {
        var end = min(off, byteCount)
        while end > 0 {
            var start = max(0, end - 4096)
            while start > 0 && isContinuation(byte(at: start)) { start -= 1 }
            let chunk = bytes(in: start..<end)
            var scalars: [(Unicode.Scalar, Int)] = []
            scalars.reserveCapacity(chunk.count)
            chunk.withUnsafeBufferPointer { p in
                var i = 0
                while i < p.count {
                    let (s, len) = decodeScalar(p, i)
                    scalars.append((s, start + i))
                    i += len
                }
            }
            for (s, at) in scalars.reversed() where !body(s, at) { return }
            end = start
        }
    }

    // MARK: - Graphemes

    /// Offset of the line start for the line containing `off`.
    public func lineStart(containing off: Int) -> Int { offset(ofLine: line(at: off)) }

    /// Offset of the line end (its newline, or the end of text) for the line containing `off`.
    public func lineEnd(containing off: Int) -> Int { lineEnd(line(at: off)) }

    /// End of the user-perceived character (grapheme cluster) starting at `off`: a whole emoji
    /// sequence, a letter with its combining marks, a flag.
    public func nextGraphemeBoundary(after off: Int) -> Int {
        guard off < byteCount else { return byteCount }
        if byte(at: off) == 0x0A { return off + 1 }
        let lineEnd = lineEnd(containing: off)
        var window = 64
        while true {
            let n = min(window, lineEnd - off)
            let chunk = bytes(from: off, maxBytes: n, stopAtNewline: true)
            guard let first = String(decoding: chunk, as: UTF8.self).first else { return nextCharEnd(off) }
            let len = first.utf8.count
            if len < chunk.count || off + chunk.count >= lineEnd || window >= 1 << 16 { return off + min(len, chunk.count) }
            window *= 4
        }
    }

    /// Start of the user-perceived character (grapheme cluster) ending at `off`.
    public func previousGraphemeBoundary(before off: Int) -> Int {
        guard off > 0 else { return 0 }
        if byte(at: off - 1) == 0x0A { return off - 1 }
        let lineStart = lineStart(containing: off - 1)
        var window = 64
        while true {
            var start = max(lineStart, off - window)
            while start > lineStart && isContinuation(byte(at: start)) { start -= 1 }
            let chunk = bytes(in: start..<off)
            let s = String(decoding: chunk, as: UTF8.self)
            guard let last = s.last else { return previousCharStart(off) }
            let len = last.utf8.count
            // A window that starts inside a run of regional indicators may pair flags wrongly.
            let startsInFlags = start > lineStart && s.unicodeScalars.first.map { (0x1F1E6...0x1F1FF).contains($0.value) } == true
            if start == lineStart || window >= 1 << 16 || (len < chunk.count && !startsInFlags) { return off - len }
            window *= 4
        }
    }

    // MARK: - Words

    /// Mac ⌥→: skips separators, then a run of one word class. Returns the end of that word.
    public func wordEnd(after off: Int) -> Int {
        var result = byteCount
        var run: CharClass?
        scanForward(from: off) { s, at in
            let c = CharClass(s)
            if c == .extend { return true }
            if let r = run {
                if c != r { result = at; return false }
            } else if c.isWord {
                run = c
            }
            return true
        }
        return result
    }

    /// Mac ⌥←: skips separators backward, then a run of one word class. Returns its start.
    public func wordStart(before off: Int) -> Int {
        var result = 0
        var run: CharClass?
        scanBackward(from: off) { s, at in
            let c = CharClass(s)
            if c == .extend { return true }
            if let r = run {
                if c != r { return false }
                result = at
            } else if c.isWord {
                run = c
                result = at
            }
            return true
        }
        return run == nil ? 0 : result
    }

    /// The word, whitespace run or single punctuation character at `off`, for double-click.
    /// At the end of a line it uses the character before.
    public func wordRange(at off: Int) -> Range<Int> {
        let off = min(max(off, 0), byteCount)
        var probe = off
        if off == byteCount || byte(at: off) == 0x0A {
            guard off > 0, byte(at: off - 1) != 0x0A else { return off..<min(off + 1, byteCount) }
            probe = previousGraphemeBoundary(before: off)
        }
        var cls: CharClass = .punctuation
        scanForward(from: probe) { s, _ in cls = CharClass(s); return false }
        if cls == .punctuation || cls == .extend || cls == .newline {
            return probe..<nextGraphemeBoundary(after: probe)
        }
        var lo = probe, hi = probe
        scanBackward(from: probe) { s, at in
            let c = CharClass(s)
            if c == cls { lo = at; return true }
            return c == .extend
        }
        scanForward(from: probe) { s, at in
            let c = CharClass(s)
            if c == cls || c == .extend { hi = at + s.utf8.count; return true }
            return false
        }
        return lo..<hi
    }

    /// The whole line containing `off`, including its newline.
    public func lineRange(at off: Int) -> Range<Int> {
        let line = line(at: off)
        return offset(ofLine: line)..<min(lineEnd(line) + 1, byteCount)
    }

    /// The leading spaces and tabs of the line containing `off`.
    public func indentation(ofLineContaining off: Int) -> [UInt8] {
        var out: [UInt8] = []
        var pos = lineStart(containing: off)
        while pos < byteCount {
            let b = byte(at: pos)
            guard b == 0x20 || b == 0x09 else { break }
            out.append(b)
            pos += 1
        }
        return out
    }
}
