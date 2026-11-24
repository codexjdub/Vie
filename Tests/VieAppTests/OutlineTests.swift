import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import VieEditor
import VieText
import VieVim
@testable import Vie

/// The sidebar's Outline: shown under the tree for Markdown files, nested headings, following
/// the cursor, jumping, and keeping up with edits.
@MainActor
@Suite struct OutlineTests {
    private let dir: URL
    private let doc = "# Guide\n\nIntro.\n\n## Install\n\nSteps.\n\n### Mac\n\nBrew.\n\n## Use\n\nRun it.\n"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vie-outline-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(doc.utf8).write(to: dir.appendingPathComponent("guide.md"))
        try Data("plain\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    }

    private func window(vim: Bool = false) -> WorkspaceWindowController {
        WorkspaceWindowController(folder: dir, size: NSSize(width: 900, height: 600), vimEnabled: vim, vimSession: VimSession())
    }

    /// Waits for the file's parse to land and the Outline to list `count` headings.
    private func headings(_ w: WorkspaceWindowController, _ count: Int) async throws {
        for _ in 0..<200 where w.outlineSection.nodes.count != count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(w.outlineSection.nodes.count == count)
    }

    private func offset(of s: String) -> Int {
        doc.utf8.distance(from: doc.startIndex, to: doc.range(of: s)!.lowerBound)
    }

    private func key(_ view: NSView, _ chars: String, _ code: Int) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)))
        view.keyDown(with: event)
    }

    /// A Markdown file's headings show under the tree, nested by level; another kind of file
    /// takes the Outline away, and coming back brings it again.
    @Test func showsForMarkdownFiles() async throws {
        let w = window()
        defer { w.close() }
        let section = w.outlineSection
        #expect(section.view.superview == nil)
        w.open(dir.appendingPathComponent("guide.md"))
        try await headings(w, 4)
        #expect(section.view.superview != nil && section.view.frame.height > 100)
        let outline = section.outline
        #expect(outline.numberOfRows == 4 && (0..<4).map { outline.level(forRow: $0) } == [0, 1, 2, 1])
        w.open(dir.appendingPathComponent("notes.txt"))
        #expect(section.view.superview == nil && !section.isAvailable)
        w.selectTab(0)
        try await headings(w, 4)
        #expect(section.view.superview != nil)
    }

    /// The heading the cursor is under is selected, and follows it; a click (or Return) on a
    /// heading puts the cursor there with the keyboard in the text, and Esc goes back too.
    @Test func followsTheCursorAndJumps() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("guide.md"))
        try await headings(w, 4)
        let editor = try #require(w.activeView)
        let section = w.outlineSection
        editor.moveCursor(toLine: 10) // "Brew.", under "### Mac"
        #expect(section.currentTitle == "Mac" && section.outline.selectedRow == 2)
        editor.moveCursor(toLine: 0)
        #expect(section.currentTitle == "Guide")

        section.jump(to: section.nodes[3])
        #expect(editor.cursorOffset == offset(of: "## Use") && w.window?.firstResponder === editor)
        w.window?.makeFirstResponder(section.outline)
        section.outline.selectRowIndexes([1], byExtendingSelection: false)
        try key(section.outline, "\r", kVK_Return)
        #expect(editor.cursorOffset == offset(of: "## Install") && w.window?.firstResponder === editor)
        w.window?.makeFirstResponder(section.outline)
        try key(section.outline, "\u{1B}", kVK_Escape)
        #expect(w.window?.firstResponder === editor)
    }

    /// Editing the file updates the Outline once the parse lands; a folded heading stays folded.
    @Test func keepsUpWithEdits() async throws {
        let w = window()
        defer { w.close() }
        w.open(dir.appendingPathComponent("guide.md"))
        try await headings(w, 4)
        let editor = try #require(w.activeView)
        let section = w.outlineSection
        section.outline.collapseItem(section.nodes[1]) // "Install", with "Mac" in it
        #expect(section.outline.numberOfRows == 3)
        editor.buffer.selection = Selection(editor.rope.byteCount)
        editor.insert("\n## Later\n")
        try await headings(w, 5)
        #expect(section.nodes.last?.heading.title == "Later" && section.outline.numberOfRows == 4)
        #expect(!section.outline.isItemExpanded(section.nodes[1]))
    }
}
