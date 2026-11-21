import VieText

/// State of one Insert or Replace mode session.
struct InsertSession {
    var kind: InsertKind
    /// Times to repeat the typed text (`3ix<Esc>`).
    var count: Int
    /// Where typing started; ⌃W and ⌃U stop here first.
    var start: Int
    /// Keys typed in this session, for the count repeat.
    var typed: [VimKey] = []
    /// True while the typed keys are being repeated.
    var repeating = false
    /// A line holding only an automatic indent, which Esc or Enter removes again.
    var autoIndentLine: Int?
    /// Replace mode: what each typed character overwrote (nil when it was appended), for ⌃H.
    var replaced: [(offset: Int, length: Int, original: [UInt8])] = []
    var block: BlockInsert?
    var awaitingRegister = false
    var awaitingLiteral = false
}

/// Visual block I, A and c: the text typed on the first line goes into the others on Esc.
struct BlockInsert {
    var firstLine: Int
    var lastLine: Int
    /// Display column the text goes in at.
    var vcol: Int
    var append: Bool
    var toEOL: Bool
    var startCol: Int
    var lineLength: Int
    var lineCount: Int
}

extension VimEngine {
    // MARK: - Entering

    func beginInsert(_ kind: InsertKind, count: Int, undoBegun: Bool, replace: Bool = false) {
        if !undoBegun {
            buffer.selection = Selection(cursor)
            buffer.beginUndoGroup()
        }
        insert = InsertSession(kind: kind, count: max(count, 1), start: cursor)
        mode = replace ? .replace : .insert
        message = nil
        syncSelection()
    }

    func startInsertCommand(_ kind: InsertKind, count: Int) {
        let p = cursorPos
        let b = text(p.line)
        switch kind {
        case .before, .change:
            break
        case .after:
            if p.col < b.count { cursor = lineStart(p.line) + nextCharCol(b, p.col) }
        case .lineStart:
            cursor = lineStart(p.line) + indentOf(b, tabstop: options.tabstop).bytes
        case .lineEnd:
            cursor = rope.lineEnd(p.line)
        case .column0:
            cursor = lineStart(p.line)
        case .lastInsert:
            if let m = marks["^"] { cursor = min(m, rope.byteCount) }
        case .openBelow, .openAbove:
            var indent = options.autoindent ? indentText(width: indentOf(b, tabstop: options.tabstop).width, options: options) : []
            // In a Markdown list, the new line gets the item's markers.
            let list = markdownLists.flatMap { lists in MarkdownList.prefix(of: b).flatMap { lists(cursor) ? $0 : nil } }
            if let list { indent = MarkdownList.continuation(of: list, in: b, above: kind == .openAbove) }
            buffer.selection = Selection(cursor)
            buffer.beginUndoGroup()
            if kind == .openBelow {
                let e = rope.lineEnd(p.line)
                replace(e..<e, with: [0x0A] + indent, cursor: e + 1 + indent.count)
            } else {
                let s = lineStart(p.line)
                replace(s..<s, with: indent + [0x0A], cursor: s + indent.count)
            }
            beginInsert(kind, count: count, undoBegun: true)
            insert?.autoIndentLine = options.autoindent && list == nil ? cursorPos.line : nil
            return
        }
        beginInsert(kind, count: count, undoBegun: false)
    }

    // MARK: - Keys

    func insertKey(_ key: VimKey) {
        guard var s = insert else {
            mode = .normal
            return
        }
        // Esc is added to the dot record when the change is committed.
        if replaying == 0 && !s.repeating && !key.isEscape { dotPending?.keys.append(key) }
        if !key.isEscape && !s.repeating { s.typed.append(key) }
        insert = s

        if s.awaitingRegister {
            insert?.awaitingRegister = false
            if let r = register(named: key.character) { typeText(r.text, record: false) }
            return
        }
        if s.awaitingLiteral {
            insert?.awaitingLiteral = false
            let literal = key == .enter ? "\r" : String(key.character)
            typeText(literal, record: false)
            return
        }
        switch key.character {
        case "\u{1B}", "\u{03}":
            leaveInsert()
        case "\r", "\n":
            insertNewline()
        case "\u{08}", "\u{7F}":
            insertBackspace()
        case "\u{F728}":
            insertDeleteForward()
        case "\u{17}":
            insertDeleteBack(line: false)
        case "\u{15}":
            insertDeleteBack(line: true)
        case "\t":
            insertTab()
        case VimKey.backtab.character:
            if !shiftListItem(right: false) { insertTab() }
        case "\u{14}":
            shiftCurrentLine(left: false)
        case "\u{04}":
            shiftCurrentLine(left: true)
        case "\u{12}":
            insert?.awaitingRegister = true
        case "\u{16}", "\u{11}":
            insert?.awaitingLiteral = true
        case "\u{F702}", "\u{F703}", "\u{F700}", "\u{F701}", "\u{F729}", "\u{F72B}":
            insertMoveCursor(key)
        default:
            if key.isText { typeText(String(key.character), record: false) } else { beep() }
        }
    }

    /// Inserts typed text (from keys or the input method).
    func typeText(_ text: String, record: Bool = true) {
        guard var s = insert else { return }
        if record {
            let keys = VimKey.keys(from: text)
            if replaying == 0 && !s.repeating { dotPending?.keys.append(contentsOf: keys) }
            if !s.repeating { s.typed.append(contentsOf: keys) }
        }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        let p = cursorPos
        if s.autoIndentLine == p.line { s.autoIndentLine = nil }
        if mode == .replace {
            // Overwrite one character per character typed, while there are some left.
            var changes: [Change] = []
            let b = self.text(p.line)
            var col = p.col
            var at = cursor
            for ch in text {
                let one = Array(String(ch).utf8)
                if ch == "\n" || ch == "\r" {
                    changes.append(Change(at..<at, [0x0A]))
                    s.replaced.append((at, 1, []))
                    at += 1
                    continue
                }
                if col < b.count {
                    let e = nextCharCol(b, col)
                    let original = Array(b[col..<e])
                    changes.append(Change((lineStart(p.line) + col)..<(lineStart(p.line) + e), one))
                    s.replaced.append((at, one.count, original))
                    col = e
                } else {
                    changes.append(Change((lineStart(p.line) + col)..<(lineStart(p.line) + col), one))
                    s.replaced.append((at, one.count, []))
                }
                at += one.count
            }
            insert = s
            edit(changes, cursor: at)
        } else {
            insert = s
            replace(cursor..<cursor, with: bytes, cursor: cursor + bytes.count)
        }
        syncSelection()
    }

    func insertNewline() {
        guard var s = insert else { return }
        let p = cursorPos
        let b = text(p.line)
        let ls = lineStart(p.line)
        if mode == .insert, let action = MarkdownList.returnAction(line: b, column: p.col), markdownLists?(cursor) == true {
            s.autoIndentLine = nil
            insert = s
            switch action {
            case .newItem(let markers):
                replace(cursor..<cursor, with: [0x0A] + markers, cursor: cursor + 1 + markers.count)
            case .end(let range, let text):
                replace((ls + range.lowerBound)..<(ls + b.count), with: text, cursor: ls + range.lowerBound + text.count)
            case .outdent:
                _ = shiftListItem(right: false)
            }
            if cursor < s.start { insert?.start = cursor }
            syncSelection()
            return
        }
        var before = p.col
        if s.autoIndentLine == p.line {
            while before > 0 && isBlank(b[before - 1]) { before -= 1 }
        }
        var after = p.col
        if options.autoindent { while after < b.count && isBlank(b[after]) { after += 1 } }
        let indent = options.autoindent ? indentText(width: indentOf(b, tabstop: options.tabstop).width, options: options) : []
        let new = [0x0A] + indent
        if mode == .replace { s.replaced.append((ls + before, new.count, Array(b[before..<after]))) }
        s.autoIndentLine = options.autoindent ? p.line + 1 : nil
        insert = s
        replace((ls + before)..<(ls + after), with: new, cursor: ls + before + new.count)
        syncSelection()
    }

    func insertBackspace() {
        guard var s = insert else { return }
        let p = cursorPos
        s.autoIndentLine = nil
        if mode == .replace {
            if let last = s.replaced.last, last.offset + last.length == cursor {
                s.replaced.removeLast()
                insert = s
                replace(last.offset..<(last.offset + last.length), with: last.original, cursor: last.offset)
            } else if p.col > 0 {
                insert = s
                cursor = lineStart(p.line) + prevCharCol(text(p.line), p.col)
            } else {
                insert = s
                beep()
            }
            syncSelection()
            return
        }
        insert = s
        if let r = MarkdownList.backspaceRange(line: text(p.line), column: p.col), markdownLists?(cursor) == true {
            // Where an item's text starts: its task box, else its marker.
            let ls = lineStart(p.line)
            replace((ls + r.lowerBound)..<(ls + r.upperBound), with: [], cursor: ls + r.lowerBound)
        } else if p.col == 0 {
            guard p.line > 0 else { return beep() }
            replace((cursor - 1)..<cursor, with: [], cursor: cursor - 1)
        } else {
            let c = rope.previousGraphemeBoundary(before: cursor)
            replace(c..<cursor, with: [], cursor: c)
        }
        if cursor < s.start { insert?.start = cursor }
        syncSelection()
    }

    func insertDeleteForward() {
        let p = cursorPos
        let b = text(p.line)
        if p.col < b.count {
            let e = lineStart(p.line) + nextCharCol(b, p.col)
            replace(cursor..<e, with: [], cursor: cursor)
        } else if p.line < lastLine {
            replace(cursor..<(cursor + 1), with: [], cursor: cursor)
        } else {
            beep()
        }
        syncSelection()
    }

    /// ⌃W (a word) and ⌃U (the line), stopping at the insert start the first time.
    func insertDeleteBack(line: Bool) {
        guard let s = insert else { return }
        let p = cursorPos
        if p.col == 0 {
            guard p.line > 0 else { return beep() }
            replace((cursor - 1)..<cursor, with: [], cursor: cursor - 1)
            syncSelection()
            return
        }
        let b = text(p.line)
        let ls = lineStart(p.line)
        let startPos = pos(min(s.start, rope.byteCount))
        let stopCol: Int? = startPos.line == p.line ? startPos.col : nil
        var minCol = 0
        if line && options.autoindent {
            let ind = indentOf(b, tabstop: options.tabstop).bytes
            if ind < p.col { minCol = ind }
        }
        var c = p.col
        var inWord = false
        var runClass = -1
        repeat {
            let prev = prevCharCol(b, c)
            if !line {
                let k = isBlank(b[prev]) ? 0 : vimClass(scalarAt(b, prev))
                if !inWord {
                    if k != 0 { inWord = true; runClass = k }
                } else if k != runClass {
                    break
                }
            }
            c = prev
        } while c > minCol && c != stopCol
        replace((ls + c)..<cursor, with: [], cursor: ls + c)
        if cursor < s.start { insert?.start = cursor }
        insert?.autoIndentLine = nil
        syncSelection()
    }

    func insertTab() {
        if mode == .insert && shiftListItem(right: true) { return }
        if options.expandtab {
            let p = cursorPos
            let v = vcolOf(text(p.line), p.col, tabstop: options.tabstop)
            typeText(String(repeating: " ", count: options.tabstop - v % options.tabstop), record: false)
        } else {
            typeText("\t", record: false)
        }
    }

    /// Tab and ⇧Tab on a Markdown list item: indent or outdent it with the lines under it,
    /// keeping the cursor on the same text. False when the cursor isn't on an item.
    func shiftListItem(right: Bool) -> Bool {
        let p = cursorPos
        guard mode == .insert, let lists = markdownLists, MarkdownList.prefix(of: text(p.line))?.isItem == true,
              lists(cursor) else { return false }
        let unit = indentText(width: options.shiftwidth, options: options)
        if let changes = MarkdownList.shift(rope, line: p.line, right: right, unit: unit) {
            edit(changes, cursor: Change.map(cursor, through: changes))
            insert?.autoIndentLine = nil
            syncSelection()
        }
        return true
    }

    /// ⌃T and ⌃D: shift the line by 'shiftwidth', keeping the cursor on the same text.
    func shiftCurrentLine(left: Bool) {
        let p = cursorPos
        let b = text(p.line)
        let ind = indentOf(b, tabstop: options.tabstop)
        let sw = options.shiftwidth
        let width = left ? max(0, (ind.width - 1) / sw * sw) : (ind.width / sw + 1) * sw
        if left && ind.width == 0 { return }
        let new = indentText(width: width, options: options)
        let ls = lineStart(p.line)
        let col = p.col >= ind.bytes ? p.col - ind.bytes + new.count : new.count
        replace(ls..<(ls + ind.bytes), with: new, cursor: ls + col)
        insert?.autoIndentLine = nil
        syncSelection()
    }

    func insertMoveCursor(_ key: VimKey) {
        var p = cursorPos
        let b = text(p.line)
        switch key {
        case .left:
            if p.col == 0 { return beep() }
            p.col = prevCharCol(b, p.col)
        case .right:
            if p.col >= b.count { return beep() }
            p.col = nextCharCol(b, p.col)
        case .up, .down:
            let v = vcolOf(b, p.col, tabstop: options.tabstop)
            if key == .up ? p.line == 0 : p.line >= lastLine { return beep() }
            p.line += key == .up ? -1 : 1
            p.col = colForVcol(text(p.line), v, tabstop: options.tabstop, oneMore: true)
        case .home: p.col = 0
        default: p.col = lineLength(p.line)
        }
        // Moving starts a new insert: a new undo step, and `.` repeats only what follows.
        buffer.endUndoGroup()
        cursor = offset(p)
        buffer.selection = Selection(cursor)
        buffer.beginUndoGroup()
        insert?.start = cursor
        insert?.typed = []
        insert?.count = 1
        insert?.autoIndentLine = nil
        if replaying == 0 { dotPending = DotRecord(keys: [VimKey("i")], count: nil, register: nil) }
        syncSelection()
    }

    // MARK: - Leaving

    func leaveInsert() {
        guard var s = insert else { return }
        if s.count > 1 && !s.typed.isEmpty {
            s.repeating = true
            insert = s
            for _ in 1..<s.count {
                if s.kind == .openBelow || s.kind == .openAbove { insertNewline() }
                run(s.typed, stopOnFailure: false)
            }
            s = insert ?? s
            s.repeating = false
        }
        if let blk = s.block { finishBlockInsert(blk) }
        var p = cursorPos
        if s.autoIndentLine == p.line, p.col > 0, p.col >= lineLength(p.line) {
            let b = text(p.line)
            var c = b.count
            while c > 0 && isBlank(b[c - 1]) { c -= 1 }
            if c < b.count {
                let ls = lineStart(p.line)
                replace((ls + c)..<(ls + b.count), with: [], cursor: ls + c)
                p = cursorPos
            }
        }
        lastInserted = VimKey.text(of: s.typed.filter { $0.isText || $0.isEnter || $0 == .tab })
        marks["^"] = cursor
        setChangeMarks(min(s.start, cursor), cursor)
        if s.block != nil {
            p = Pos(s.block!.firstLine, s.block!.append ? blockStartCol(s.block!) : s.block!.startCol)
        } else if p.col > 0 {
            p.col = prevCharCol(text(p.line), p.col)
        }
        insert = nil
        mode = .normal
        buffer.endUndoGroup()
        cursor = clampNormal(offset(p))
        updateCurswant()
        syncSelection()
        if replaying == 0, var d = dotPending {
            d.keys.append(.escape)
            dotPending = d
        }
        finishChangeIfComplete()
    }

    /// Copies the text typed on the block's first line into its other lines.
    func finishBlockInsert(_ blk: BlockInsert) {
        guard rope.lineCount == blk.lineCount, cursorPos.line == blk.firstLine else { return }
        let added = lineLength(blk.firstLine) - blk.lineLength
        guard added > 0 else { return }
        let first = text(blk.firstLine)
        let inserted = Array(first[blk.startCol..<(blk.startCol + added)])
        guard blk.lastLine > blk.firstLine else { return }
        var changes: [Change] = []
        for line in (blk.firstLine + 1)...blk.lastLine {
            let b = text(line)
            let ls = lineStart(line)
            if blk.toEOL {
                changes.append(Change((ls + b.count)..<(ls + b.count), inserted))
                continue
            }
            let width = displayWidth(b, tabstop: options.tabstop)
            if width < blk.vcol {
                if blk.append {
                    changes.append(Change((ls + b.count)..<(ls + b.count), [UInt8](repeating: 0x20, count: blk.vcol - width) + inserted))
                }
                continue
            }
            var col = 0, v = 0
            while col < b.count && v < blk.vcol {
                v += cellsAt(b, col, vcol: v, tabstop: options.tabstop)
                col = nextCharCol(b, col)
            }
            changes.append(Change((ls + col)..<(ls + col), inserted))
        }
        if !changes.isEmpty { edit(changes, cursor: cursor) }
    }

    /// For block append: the block's left column on its first line.
    func blockStartCol(_ blk: BlockInsert) -> Int {
        lastVisualLeftCol ?? blk.startCol
    }

    var lastVisualLeftCol: Int? {
        guard let lv = lastVisual, lv.mode == .visualBlock else { return nil }
        let a = pos(lv.anchor), c = pos(lv.cursor)
        let left = min(vcolOf(text(a.line), a.col, tabstop: options.tabstop), vcolOf(text(c.line), c.col, tabstop: options.tabstop))
        let line = min(a.line, c.line)
        return colForVcol(text(line), left, tabstop: options.tabstop, oneMore: true)
    }
}
