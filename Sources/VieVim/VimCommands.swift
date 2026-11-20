import VieText

extension VimEngine {
    func runCommand(_ cmd: Command, _ c: ParsedCommand) {
        let n = c.count1
        switch cmd {
        case .deleteChar(let forward):
            operatorWithMotion(.delete, .right(wrap: false).flipped(!forward), c)
        case .deleteToEnd:
            operatorWithMotion(.delete, .lineEnd, c)
        case .changeToEnd:
            operatorWithMotion(.change, .lineEnd, c)
        case .substituteChar:
            operatorWithMotion(.change, .right(wrap: false), c)
        case .substituteLine:
            operatorDoubled(.change, c)
        case .yankLine:
            operatorDoubled(.yank, c)
        case .put(let before, let after):
            put(c.register, before: before, cursorAfter: after, count: n)
        case .join(let spaces):
            var count = max(c.count ?? 2, 2)
            let line = cursorPos.line
            if line + count - 1 > lastLine {
                if count <= 2 { return beep() }
                count = lastLine - line + 1
            }
            join(first: line, count: count, spaces: spaces)
        case .replaceChar(let ch):
            replaceChars(with: ch, count: n)
        case .toggleCaseChar:
            toggleCaseChars(count: n)
        case .insert(let kind):
            startInsertCommand(kind, count: n)
        case .replaceMode:
            beginInsert(.before, count: n, undoBegun: false, replace: true)
        case .visual(let m):
            enterVisual(m)
        case .reselect:
            reselectVisual()
        case .undo:
            undo(count: n, redo: false)
        case .redo:
            undo(count: n, redo: true)
        case .dot:
            repeatLastChange(count: c.count)
        case .record(let name):
            if let name {
                recording = (name, [])
            } else if let r = recording {
                var keys = r.keys
                if keys.last?.character == "q" { keys.removeLast() }
                recording = nil
                registers.set(r.register == "\"" ? "0" : r.register, Register(text: VimKey.text(of: keys), kind: .charwise))
            }
        case .playMacro(let name):
            playMacro(name, count: n)
        case .setMark(let name):
            setMark(name)
        case .commandLine(let kind):
            var initial = ""
            if mode.isVisual { initial = "'<,'>" } else if let count = c.count { initial = count == 1 ? "." : ".,.+\(count - 1)" }
            startCommandLine(kind, pendingOp: nil, count: nil, initial: initial)
        case .repeatSubstitute(let global):
            let p = cursorPos.line
            if global {
                executeEx("%s//~/&")
            } else {
                substituteRepeat(lines: p...p, keepFlags: false)
            }
        case .increment(let sign):
            increment(by: sign * n)
        case .scroll(let kind):
            scroll(kind, count: c.count)
        case .escape:
            if mode.isVisual { endVisual() }
        case .writeQuit(let force):
            if let error = host?.vimPerform(force ? .quit(force: true) : .exit(force: false)) { fail(error) }
        case .fileInfo:
            let lines = rope.lineCount
            let line = cursorPos.line + 1
            show("\(lines) line\(lines == 1 ? "" : "s") --\(lines > 0 ? line * 100 / lines : 0)%--")
        case .visualSwap, .visualOperator, .visualLineOperator, .visualReplace, .visualJoin, .visualPut, .visualInsert:
            runVisualCommand(cmd, c)
        }
    }

    // MARK: - r ~

    func replaceChars(with ch: Character, count: Int) {
        let p = cursorPos
        let b = text(p.line)
        var e = p.col
        for _ in 0..<count {
            if e >= b.count { return beep() }
            e = nextCharCol(b, e)
        }
        let ls = lineStart(p.line)
        if ch == "\r" || ch == "\n" {
            // Replaced by one line break, with autoindent.
            var after = e
            if options.autoindent { while after < b.count && isBlank(b[after]) { after += 1 } }
            let indent = options.autoindent ? indentText(width: indentOf(b, tabstop: options.tabstop).width, options: options) : []
            change(at: cursor) {
                replace((ls + p.col)..<(ls + after), with: [0x0A] + indent, cursor: ls + p.col + 1 + indent.count)
            }
            cursor = clampNormal(cursor)
        } else {
            let one = Array(String(ch).utf8)
            var new: [UInt8] = []
            for _ in 0..<count { new += one }
            change(at: cursor) {
                replace((ls + p.col)..<(ls + e), with: new, cursor: ls + p.col + new.count - one.count)
            }
        }
        updateCurswant()
        syncSelection()
    }

    func toggleCaseChars(count: Int) {
        let p = cursorPos
        let b = text(p.line)
        guard !b.isEmpty else { return beep() }
        var e = p.col
        for _ in 0..<count where e < b.count { e = nextCharCol(b, e) }
        let ls = lineStart(p.line)
        let old = Array(b[p.col..<e])
        let new = changeCase(old, .toggle)
        change(at: cursor) {
            if new != old { replace((ls + p.col)..<(ls + e), with: new, cursor: ls + p.col + new.count) }
        }
        cursor = clampNormal(ls + p.col + new.count)
        updateCurswant()
        syncSelection()
    }

    // MARK: - . (repeat)

    func repeatLastChange(count: Int?) {
        guard let d = dot else { return beep() }
        if let count { dot?.count = count }
        var keys: [VimKey] = []
        if let r = d.register { keys += [VimKey("\""), VimKey(r)] }
        if d.visual == nil, let n = count ?? d.count {
            keys += String(n).map { VimKey($0) }
        }
        keys += d.keys
        replaying += 1
        defer { replaying -= 1 }
        if let v = d.visual { selectForRepeat(v) }
        run(keys, stopOnFailure: true)
        if mode == .insert || mode == .replace { process(.escape) }
    }

    // MARK: - Macros

    func playMacro(_ name: Character, count: Int) {
        var reg = name
        if name == "@" {
            guard let last = lastMacro else { return fail("E748: No previously used register") }
            reg = last
        }
        if reg == ":" {
            lastMacro = ":"
            guard !lastCommandLine.isEmpty else { return fail("E30: No previous command line") }
            for _ in 0..<count { executeEx(lastCommandLine) }
            return
        }
        guard let r = register(named: reg) else { return beep() }
        lastMacro = reg
        guard macroDepth < 100 else { return beep() }
        var keys = VimKey.keys(from: r.text)
        if r.kind == .linewise, keys.last?.character == "\n" { keys[keys.count - 1] = .enter }
        macroDepth += 1
        defer { macroDepth -= 1 }
        for _ in 0..<count {
            if !run(keys, stopOnFailure: true) {
                failed = true
                return
            }
        }
    }

    // MARK: - Marks

    func setMark(_ name: Character) {
        switch name {
        case "'", "`": marks["'"] = cursor
        case "<", ">", "[", "]": marks[name] = cursor
        default: marks[Character(name.lowercased())] = cursor
        }
    }

    // MARK: - ⌃A ⌃X

    /// Adds `delta` to the number at or after the cursor on its line (decimal, `0x` hex or
    /// `0b` binary).
    func increment(by delta: Int) {
        let p = cursorPos
        let b = text(p.line)
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c | 0x20) >= 0x61 && (c | 0x20) <= 0x66 }
        // Start of a number under the cursor, else the next one.
        var col = p.col
        if col < b.count && isHex(b[col]) {
            var k = col
            while k > 0 && isHex(b[k - 1]) { k -= 1 }
            if k >= 2 && (b[k - 1] | 0x20) == UInt8(ascii: "x") && b[k - 2] == 0x30 { col = k - 2 }
            else {
                var d = col
                while d > 0 && isDigit(b[d - 1]) { d -= 1 }
                col = isDigit(b[col]) ? d : col
            }
        }
        while col < b.count && !isDigit(b[col]) { col += 1 }
        guard col < b.count else { return beep() }
        var start = col
        var end = col
        var radix = 10
        if b[col] == 0x30 && col + 2 < b.count && (b[col + 1] | 0x20) == UInt8(ascii: "x") && isHex(b[col + 2]) {
            radix = 16
            end = col + 2
            while end < b.count && isHex(b[end]) { end += 1 }
        } else if b[col] == 0x30 && col + 2 < b.count && (b[col + 1] | 0x20) == UInt8(ascii: "b") && (b[col + 2] == 0x30 || b[col + 2] == 0x31) {
            radix = 2
            end = col + 2
            while end < b.count && (b[end] == 0x30 || b[end] == 0x31) { end += 1 }
        } else {
            while end < b.count && isDigit(b[end]) { end += 1 }
            if start > 0 && b[start - 1] == UInt8(ascii: "-") { start -= 1 }
        }
        let old = String(decoding: b[start..<end], as: UTF8.self)
        var new: String
        if radix == 10 {
            guard let v = Int(old) else { return beep() }
            new = String(v &+ delta)
        } else {
            let digits = String(old.dropFirst(2))
            guard let v = UInt64(digits, radix: radix) else { return beep() }
            var s = String(v &+ UInt64(bitPattern: Int64(delta)), radix: radix)
            if digits.contains(where: { $0.isUppercase }) { s = s.uppercased() }
            if s.count < digits.count { s = String(repeating: "0", count: digits.count - s.count) + s }
            new = String(old.prefix(2)) + s
        }
        let ls = lineStart(p.line)
        let bytes = Array(new.utf8)
        change(at: cursor) {
            replace((ls + start)..<(ls + end), with: bytes, cursor: ls + start + bytes.count - 1)
        }
        updateCurswant()
        syncSelection()
    }

    // MARK: - Scrolling

    func scroll(_ kind: ScrollKind, count: Int?) {
        let visible = host?.visibleLines ?? 0..<(lastLine + 1)
        let height = max(visible.count, 1)
        var top = visible.lowerBound
        var p = cursorPos
        switch kind {
        case .halfDown, .halfUp:
            let n = count ?? max(height / 2, 1)
            if kind == .halfDown {
                if p.line >= lastLine { return beep() }
                top = min(top + n, max(lastLine - height + 1, 0))
                p.line = min(p.line + n, lastLine)
            } else {
                if p.line == 0 { return beep() }
                top = max(top - n, 0)
                p.line = max(p.line - n, 0)
            }
            p.col = startOfLineCol(p.line)
        case .pageDown, .pageUp:
            let n = max(count ?? 1, 1)
            let step = max(height - 2, 1) * n
            if kind == .pageDown {
                if top >= lastLine { return beep() }
                top = min(top + step, lastLine)
                p.line = max(p.line, top)
            } else {
                if top == 0 { return beep() }
                top = max(top - step, 0)
                p.line = min(p.line, top + height - 1)
            }
            p.col = startOfLineCol(p.line)
        case .lineDown, .lineUp:
            let n = max(count ?? 1, 1)
            top = kind == .lineDown ? min(top + n, lastLine) : max(top - n, 0)
            if p.line < top { p.line = top } else if p.line > top + height - 1 { p.line = top + height - 1 }
            p.col = colFor(p.line, vcol: curswant)
        case .cursorTop, .cursorMiddle, .cursorBottom:
            if let count { p.line = min(max(count - 1, 0), lastLine) }
            switch kind {
            case .cursorTop: top = p.line
            case .cursorMiddle: top = max(p.line - height / 2, 0)
            default: top = max(p.line - height + 1, 0)
            }
        }
        host?.vimScroll(toTopLine: top)
        cursor = offset(clampNormal(p))
        if case .lineDown = kind {} else if case .lineUp = kind {} else { updateCurswant() }
        syncSelection()
    }
}

extension Motion {
    /// `.right` as `.left` when `flip` (for `X` versus `x`).
    func flipped(_ flip: Bool) -> Motion {
        guard flip, case .right(let wrap) = self else { return self }
        return .left(wrap: wrap)
    }
}
