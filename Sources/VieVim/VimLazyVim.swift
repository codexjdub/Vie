import VieText

/// Keys LazyVim adds to Vim (or Neovim does): `gc` to comment lines, and ⌥J and ⌥K to move
/// them.
extension VimEngine {
    // MARK: - gc

    /// `gc`: comments the lines out with the file's marker (`commentMarker`) or, when every
    /// line with text already is, back in, as Neovim does. Blank lines are left alone. The
    /// marker goes at the smallest indent among the lines, then a space; a closing marker
    /// (`-->`) goes after the text.
    func opComment(_ r: OpRange) {
        guard let marker = commentMarker?() else { return fail("This kind of file has no comment marker") }
        let open = Array(marker.start.utf8), close = Array(marker.end.utf8)
        let lines = (r.start.line...r.end.line).filter { !lineWhite($0) }
        guard !lines.isEmpty else { return }

        /// The line's text without the blanks around it.
        func body(_ b: [UInt8]) -> Range<Int> {
            var s = 0, e = b.count
            while s < e && isBlank(b[s]) { s += 1 }
            while e > s && isBlank(b[e - 1]) { e -= 1 }
            return s..<e
        }
        func isCommented(_ b: [UInt8]) -> Bool {
            let t = b[body(b)]
            guard t.starts(with: open) else { return false }
            return close.isEmpty || (t.count >= open.count + close.count && t.suffix(close.count).elementsEqual(close))
        }

        var changes: [Change] = []
        if lines.allSatisfy({ isCommented(text($0)) }) {
            for line in lines {
                let b = text(line), t = body(b), ls = lineStart(line)
                var s = t.lowerBound + open.count
                if s < t.upperBound && b[s] == 0x20 { s += 1 }
                changes.append(Change((ls + t.lowerBound)..<(ls + s), []))
                if !close.isEmpty {
                    var e = max(s, t.upperBound - close.count)
                    if e > s && b[e - 1] == 0x20 { e -= 1 }
                    changes.append(Change((ls + e)..<(ls + t.upperBound), []))
                }
            }
        } else {
            let tabstop = options.tabstop
            let indent = lines.map { indentOf(text($0), tabstop: tabstop).width }.min() ?? 0
            for line in lines {
                let b = text(line), ls = lineStart(line)
                var col = 0, width = 0
                while col < b.count && isBlank(b[col]) && width < indent {
                    width += b[col] == 0x09 ? tabstop - width % tabstop : 1
                    col += 1
                }
                changes.append(Change((ls + col)..<(ls + col), open + [0x20]))
                if !close.isEmpty {
                    let e = ls + body(b).upperBound
                    changes.append(Change(e..<e, [0x20] + close))
                }
            }
        }
        let first = r.start.line
        change(at: offset(r.start)) { edit(changes, cursor: lineStart(first)) }
        cursor = lineStart(first) + firstNonBlank(first)
    }

    // MARK: - ⌥J ⌥K

    /// ⌥J and ⌥K: moves the cursor's line `count` lines down or up, or the Visual lines (which
    /// stay selected), as LazyVim's mapping does with `:m`. Indents are kept as they are.
    func moveLinesKey(down: Bool, count: Int) {
        let visual = mode.isVisual
        let a = pos(visual ? visualAnchor : cursor), c = cursorPos
        let first = min(a.line, c.line), last = max(a.line, c.line)
        // The empty line after a final line break isn't one to move, or to move past: the
        // file keeps ending with its line break.
        let end = lastLine > 0 && rope.byteCount > 0 && rope.bytes(in: (rope.byteCount - 1)..<rope.byteCount) == [0x0A] ? lastLine - 1 : lastLine
        guard last <= end else { return beep() }
        let dest: Int
        if down {
            guard last < end else { return beep() }
            dest = min(last + count, end)
        } else {
            guard first > 0 else { return beep() }
            dest = max(first - count - 1, -1)
        }
        let shift = down ? dest - last : dest + 1 - first
        moveLines(first...last, below: dest, copy: false)
        guard visual else { return }
        // The moved lines keep their text, so the same columns are still in them.
        visualAnchor = offset(Pos(a.line + shift, a.col))
        cursor = offset(Pos(c.line + shift, c.col))
        syncSelection()
    }
}
