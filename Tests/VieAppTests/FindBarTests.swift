import AppKit
import Foundation
import Testing
import VieText
import VieVim
@testable import VieEditor
@testable import Vie

/// The Find bar, through its window: ⌘F and finding as you type, Return and Esc, Replace and
/// Replace All, ⌘E and ⌘G, Vim mode, and following the current tab.
@MainActor
@Suite final class FindBarTests {
    private let dir: URL
    private let text = "one two\nthree two\ntwo\n"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-find-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("t.txt"))
        try Data("alpha beta\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A window with t.txt open, and a find pasteboard of its own (not the system's).
    private func window(vim: Bool = false) -> (WorkspaceWindowController, NSPasteboard) {
        let pasteboard = NSPasteboard.withUniqueName()
        FindBar.defaultPasteboard = pasteboard
        let w = WorkspaceWindowController(folder: nil, size: NSSize(width: 900, height: 600), vimEnabled: vim, vimSession: VimSession())
        w.findBar.findPasteboard = pasteboard
        w.open(dir.appendingPathComponent("t.txt"))
        return (w, pasteboard)
    }

    /// Typing into the field that has the keyboard.
    private func type(_ w: WorkspaceWindowController, _ s: String) throws {
        let field = try #require(w.window?.firstResponder as? NSTextView)
        field.insertText(s, replacementRange: field.selectedRange())
    }

    /// A key command (Return, Esc) in the field that has the keyboard.
    private func command(_ w: WorkspaceWindowController, _ selector: Selector) throws {
        try #require(w.window?.firstResponder as? NSTextView).doCommand(by: selector)
    }

    private func selected(_ w: WorkspaceWindowController) -> Range<Int>? { w.activeView?.selection.range }

    private var contents: String { (try? String(contentsOf: dir.appendingPathComponent("t.txt"), encoding: .utf8)) ?? "" }

    private func editorText(_ w: WorkspaceWindowController) -> String {
        guard let rope = w.activeView?.rope else { return "" }
        return String(decoding: rope.bytes(in: 0..<rope.byteCount), as: UTF8.self)
    }

    /// ⌘F shows the bar above the text with the keyboard in its field; typing selects the next
    /// match from the cursor and counts them; Return and ⇧Return go round them; Esc hides the
    /// bar and its highlights and leaves the match selected, back in the text.
    @Test func findsAsYouType() throws {
        let (w, pasteboard) = window()
        defer { w.close(); pasteboard.releaseGlobally() }
        let editor = try #require(w.activeView)
        let tall = try #require(editor.superview).frame.height
        w.showFindBar(nil)
        #expect(w.findBar.isShown && w.findBar.replaceField.isHidden)
        #expect(editor.superview?.frame.height == tall - FindBar.rowHeight)
        #expect((w.window?.firstResponder as? NSTextView)?.delegate === w.findBar.findField)

        try type(w, "tw")
        #expect(selected(w) == 4..<6 && w.findBar.status == "1 of 3" && editor.findSearch != nil)
        try type(w, "o")
        #expect(selected(w) == 4..<7 && w.findBar.status == "1 of 3")
        try command(w, #selector(NSResponder.insertNewline(_:)))
        #expect(selected(w) == 14..<17 && w.findBar.status == "2 of 3")
        w.findBar.findNext(forward: false)
        w.findBar.findNext(forward: false)
        #expect(selected(w) == 18..<21 && w.findBar.status == "3 of 3") // round the top
        #expect(pasteboard.string(forType: .string) == "two")

        try type(w, "x")
        #expect(w.findBar.status == "No matches" && selected(w) == 18..<21)
        w.findBar.caseButton.performClick(nil)
        #expect(w.findBar.query == FindQuery("twox", matchCase: true))

        try command(w, #selector(NSResponder.cancelOperation(_:)))
        #expect(!w.findBar.isShown && w.window?.firstResponder === editor)
        #expect(editor.findSearch == nil && editor.superview?.frame.height == tall)
        #expect(selected(w) == 18..<21)
    }

    /// ⌥⌘F adds the Replace row. Replace changes the current match and goes to the next;
    /// Replace All changes the rest as one undo step. A regular expression's `$1` is its group.
    @Test func replacesOneOrAll() throws {
        let (w, pasteboard) = window()
        defer { w.close(); pasteboard.releaseGlobally() }
        let editor = try #require(w.activeView)
        w.showFindAndReplace(nil)
        #expect(!w.findBar.replaceField.isHidden && w.findBar.frame.height == 2 * FindBar.rowHeight)
        try type(w, "two")
        w.findBar.replaceField.stringValue = "2"
        w.findBar.replace()
        #expect(editorText(w) == "one 2\nthree two\ntwo\n")
        #expect(selected(w) == 12..<15 && w.findBar.status == "1 of 2")
        #expect(w.findBar.replaceAll() == 2)
        #expect(editorText(w) == "one 2\nthree 2\n2\n" && w.findBar.status == "2 replaced")
        editor.undo(nil)
        #expect(editorText(w) == "one 2\nthree two\ntwo\n")
        editor.undo(nil)
        #expect(editorText(w) == text)

        w.findBar.regexButton.performClick(nil)
        w.findBar.findField.stringValue = "t(w|hr)"
        w.findBar.replaceField.stringValue = "<$1>"
        #expect(w.findBar.replaceAll() == 4)
        #expect(editorText(w) == "one <w>o\n<hr>ee <w>o\n<w>o\n")
    }

    /// ⌘E makes the selection the search (and puts it on the find pasteboard); ⌘G and ⇧⌘G go
    /// on with it while the bar is hidden, without highlights. Text another app put on the find
    /// pasteboard is in the field when the bar opens.
    @Test func useSelectionAndFindNextWithTheBarHidden() throws {
        let (w, pasteboard) = window()
        defer { w.close(); pasteboard.releaseGlobally() }
        let editor = try #require(w.activeView)
        editor.buffer.selection = Selection(anchor: 14, head: 17)
        w.useSelectionForFind(nil)
        #expect(w.findBar.query.text == "two" && pasteboard.string(forType: .string) == "two")
        w.findNextMatch(nil)
        #expect(selected(w) == 18..<21 && editor.findSearch == nil && !w.findBar.isShown)
        w.findNextMatch(nil)
        #expect(selected(w) == 4..<7)
        w.findPreviousMatch(nil)
        #expect(selected(w) == 18..<21)

        pasteboard.clearContents()
        pasteboard.setString("three", forType: .string)
        w.showFindBar(nil)
        #expect(w.findBar.query.text == "three" && w.findBar.status == "1 match")
    }

    /// In Vim mode a match puts the cursor at its start, as `/` does; when the bar closes, its
    /// search becomes Vim's, so `n` goes on with it, unhighlighted until then. A regular
    /// expression isn't handed over.
    @Test func vimModeHandsOverTheSearch() throws {
        let (w, pasteboard) = window(vim: true)
        defer { w.close(); pasteboard.releaseGlobally() }
        let editor = try #require(w.activeView)
        w.showFindBar(nil)
        try type(w, "two")
        #expect(editor.cursorOffset == 4 && editor.selection.isEmpty && w.findBar.status == "1 of 3")
        try command(w, #selector(NSResponder.cancelOperation(_:)))
        let all = 0..<editor.rope.byteCount
        #expect(editor.vimSession.lastSearchPattern == "\\V\\ctwo" && editor.vim?.searchHighlights(in: all).isEmpty == true)
        editor.vim?.handle(keys: VimKey.parse("n"))
        #expect(editor.cursorOffset == 14 && editor.vim?.searchHighlights(in: all).count == 3)

        w.showFindBar(nil)
        w.findBar.regexButton.performClick(nil)
        try type(w, "t.o")
        try command(w, #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.vimSession.lastSearchPattern == "\\V\\ctwo")
        #expect(FindBar.vimPattern(for: FindQuery("a\\b", matchCase: true, wholeWord: true)) == "\\V\\C\\<a\\\\b\\>")
        #expect(FindBar.vimPattern(for: FindQuery("(x", wholeWord: true)) == "\\V\\c(x\\>")
    }

    /// The bar searches the tab that's showing: switching tabs moves the highlights and the
    /// count; closing the last tab hides it. Editing the text counts again a moment later.
    @Test func followsTheCurrentTab() async throws {
        let (w, pasteboard) = window()
        defer { w.close(); pasteboard.releaseGlobally() }
        let first = try #require(w.activeView)
        w.showFindBar(nil)
        try type(w, "e")
        #expect(w.findBar.status == "1 of 3")
        w.open(dir.appendingPathComponent("a.txt"))
        let second = try #require(w.activeView)
        #expect(first.findSearch == nil && second.findSearch != nil && w.findBar.status == "1 match")

        second.buffer.selection = Selection(0)
        second.insert("e")
        for _ in 0..<20 where w.findBar.status != "2 matches" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(w.findBar.status == "2 matches")

        w.selectTab(0)
        #expect(first.findSearch != nil && second.findSearch == nil && w.findBar.status == "3 matches")
        #expect(await w.closeTab(at: 1, force: true))
        #expect(await w.closeTab(at: 0, force: true))
        #expect(!w.findBar.isShown)
    }
}
