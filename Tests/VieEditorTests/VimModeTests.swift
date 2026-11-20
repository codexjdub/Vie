import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import VieText
import VieVim
@testable import VieEditor

/// Vim mode in the view: key events reaching the engine, Insert-mode text through the input
/// method, the mouse and menus staying in step, the status bar, and drawing. (The engine
/// itself is covered by the specs in VieVimTests.)
@MainActor
@Suite struct VimModeTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    /// A view over `text` with Vim mode on; "|" marks the cursor.
    private func make(_ text: String, height: CGFloat = 400) -> EditorView {
        var s = text
        var head = 0
        if let bar = s.firstIndex(of: "|") {
            head = s.utf8.distance(from: s.startIndex, to: bar)
            s.remove(at: bar)
        }
        let buffer = Buffer(rope: Rope(s))
        buffer.selection = Selection(head)
        let view = EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: height), buffer: buffer)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("vie-test-\(UUID().uuidString)"))
        view.vimEnabled = true
        return view
    }

    /// The text with "|" at the Vim cursor.
    private func state(_ v: EditorView) -> String {
        var bytes = v.rope.bytes(in: 0..<v.rope.byteCount)
        bytes.insert(UInt8(ascii: "|"), at: v.vim?.cursor ?? v.selection.head)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func event(_ chars: String, code: Int = 0xFFFF, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false,
                         keyCode: UInt16(code))!
    }

    /// Presses each character's key in Normal or Visual mode.
    private func type(_ v: EditorView, _ keys: String) {
        for c in keys { v.keyDown(with: event(String(c))) }
    }

    private func esc(_ v: EditorView) { v.keyDown(with: event("\u{1B}", code: kVK_Escape)) }
    private func enter(_ v: EditorView) { v.keyDown(with: event("\r", code: kVK_Return)) }
    private func ctrl(_ v: EditorView, _ c: Character) {
        v.keyDown(with: event(String(VimKey.ctrl(c).character), flags: .control, ignoring: String(c)))
    }

    @Test func normalModeKeysRunCommands() {
        let v = make("|one two three")
        type(v, "dw")
        #expect(state(v) == "|two three")
        type(v, "$")
        #expect(state(v) == "two thre|e")
        type(v, "u")
        #expect(state(v) == "|one two three")
        ctrl(v, "r")
        #expect(state(v) == "|two three")
    }

    @Test func insertModeTextComesFromTheInputMethod() {
        let v = make("a|b")
        type(v, "i")
        #expect(v.vim?.mode == .insert)
        v.insertText("xy", replacementRange: none)
        esc(v)
        #expect(state(v) == "ax|yb")
        #expect(v.vim?.mode == .normal)
        type(v, ".")
        #expect(state(v) == "axx|yyb")
    }

    @Test func compositionIsTypedWhenCommitted() {
        let v = make("|ab")
        type(v, "A")
        v.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        #expect(v.rope.string(in: 0..<v.rope.byteCount) == "ab")
        v.insertText("日本", replacementRange: none)
        esc(v)
        #expect(state(v) == "ab日|本")
    }

    @Test func accentMenuReplacesTheTypedCharacter() {
        let v = make("|")
        type(v, "i")
        v.insertText("cafe", replacementRange: none)
        v.insertText("é", replacementRange: NSRange(location: 3, length: 1))
        esc(v)
        #expect(state(v) == "caf|é")
    }

    @Test func optionAndCommandBackspaceDeleteInInsertMode() {
        let v = make("|")
        type(v, "i")
        v.insertText("one two", replacementRange: none)
        v.keyDown(with: event("\u{7F}", code: kVK_Delete, flags: .option))
        #expect(v.rope.string(in: 0..<v.rope.byteCount) == "one ")
        v.keyDown(with: event("\u{7F}", code: kVK_Delete, flags: .command))
        #expect(v.rope.string(in: 0..<v.rope.byteCount) == "")
    }

    @Test func commandLineRunsExCommands() {
        let v = make("|a\nb\nc")
        type(v, ":")
        #expect(v.vim?.mode == .commandLine)
        v.insertText("2d", replacementRange: none)
        #expect(v.vim?.commandLineText == ":2d")
        enter(v)
        #expect(state(v) == "a\n|c")
        type(v, "/")
        v.insertText("c", replacementRange: none)
        #expect(v.vim?.incsearchRange == 2..<3)
        enter(v)
        #expect(state(v) == "a\n|c")
    }

    @Test func fileCommandsGoToTheHandler() {
        let v = make("|a")
        var got: [VimFileCommand] = []
        v.vimFileHandler = { got.append($0); return $0 == .quit(force: false) ? "E37: No write since last change" : nil }
        type(v, ":")
        v.insertText("w", replacementRange: none)
        enter(v)
        type(v, ":")
        v.insertText("q", replacementRange: none)
        enter(v)
        #expect(got == [.write(path: nil, force: false), .quit(force: false)])
        #expect(v.vim?.message == "E37: No write since last change")
        #expect(v.vim?.messageIsError == true)
    }

    @Test func aSelectionFromTheMouseIsVisualMode() {
        let v = make("|hello world")
        // What a drag from "h" to after "o" does.
        v.buffer.selection = Selection(anchor: 0, head: 5)
        v.vimSelectionChanged()
        #expect(v.vim?.mode == .visual)
        #expect(v.vim?.cursor == 4)
        type(v, "d")
        #expect(state(v) == "| world")
        #expect(v.vim?.mode == .normal)
    }

    @Test func aClickInInsertModeMovesTheInsertPoint() {
        let v = make("|abc")
        type(v, "i")
        v.buffer.selection = Selection(3)
        v.vimSelectionChanged()
        v.insertText("!", replacementRange: none)
        esc(v)
        #expect(state(v) == "abc|!")
    }

    @Test func shiftArrowSelectsInVisualMode() {
        let v = make("ab|cd")
        v.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        #expect(v.vim?.mode == .visual)
        type(v, "y")
        #expect(v.vim?.mode == .normal)
        type(v, "$p")
        #expect(state(v) == "abcd|c")
    }

    @Test func menuUndoLeavesInsertMode() {
        let v = make("|ab")
        type(v, "i")
        v.insertText("xyz", replacementRange: none)
        v.undo(nil)
        #expect(v.vim?.mode == .normal)
        #expect(state(v) == "|ab")
        v.redo(nil)
        #expect(v.rope.string(in: 0..<v.rope.byteCount) == "xyzab")
    }

    @Test func pasteInInsertModeIsPartOfTheInsert() {
        let v = make("|.")
        v.pasteboard.clearContents()
        v.pasteboard.setString("ab", forType: .string)
        type(v, "i")
        v.paste(nil)
        esc(v)
        type(v, ".")
        #expect(state(v) == "aa|bb.")
    }

    @Test func clipboardRegisterUsesThePasteboard() {
        let v = make("|word")
        type(v, "\"+yiw")
        #expect(v.pasteboard.string(forType: .string) == "word")
        v.pasteboard.clearContents()
        v.pasteboard.setString("new", forType: .string)
        type(v, "\"+P")
        #expect(state(v) == "ne|wword")
    }

    @Test func scrollCommandsUseTheView() {
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let v = make("|" + text, height: 200)
        let page = v.visibleLines.count
        #expect(page > 3)
        ctrl(v, "f")
        #expect(v.scrollY > 0)
        #expect(v.visibleLines.contains(v.rope.line(at: v.vim!.cursor)))
        type(v, "gg")
        #expect(v.scrollY == 0)
        type(v, "L")
        #expect(v.rope.line(at: v.vim!.cursor) == page - 1)
    }

    @Test func turningVimOffGoesBackToMacEditing() {
        let v = make("a|b")
        type(v, "v")
        v.vimEnabled = false
        #expect(v.vim == nil)
        v.insertText("x", replacementRange: none)
        #expect(v.rope.string(in: 0..<v.rope.byteCount) == "axb")
        v.vimEnabled = true
        #expect(v.vim?.mode == .normal)
    }

    @Test func tabstopChangesTheLayout() {
        let v = make("|\tx")
        let before = v.x(of: 1)
        type(v, ":")
        v.insertText("set ts=8", replacementRange: none)
        enter(v)
        #expect(v.x(of: 1) == before * 2)
    }

    @Test func statusBarShowsModeCommandLineAndPosition() {
        let v = make("a\n|bc")
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: StatusBarView.height), editor: v)
        v.statusBar = bar
        #expect(bar.shown.right == "Ln 2, Col 1")
        type(v, "i")
        #expect(bar.shown.left == "-- INSERT --")
        esc(v)
        type(v, "2d")
        #expect(bar.shown.right == "2d    Ln 2, Col 1")
        esc(v)
        type(v, ":")
        v.insertText("se", replacementRange: none)
        #expect(bar.shown.left == ":se")
        #expect(bar.shown.commandLineCursor == 3)
        esc(v)
        type(v, "u")
        #expect(bar.shown.leftIsError)
    }

    /// Draws each mode into a bitmap. Set VIE_SNAPSHOT_DIR to write PNGs to look at.
    @Test func rendersVimModes() throws {
        let v = make("func |hello() {\n    let 日本 = \"🚀\"\n}\n// hello")
        v.focusedForTesting = true
        func snapshot(_ name: String) throws {
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
            if let dir = ProcessInfo.processInfo.environment["VIE_SNAPSHOT_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("vim-\(name).png"))
            }
        }
        try snapshot("normal")
        type(v, "/hello")
        try snapshot("incsearch")
        enter(v)
        try snapshot("hlsearch")
        type(v, "gg")
        ctrl(v, "v")
        type(v, "jjl")
        try snapshot("block")
        esc(v)
        type(v, "Vj")
        try snapshot("line")
        esc(v)
        type(v, "R")
        try snapshot("replace")
    }
}
