import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import VieSyntax
import VieText
import VieVim
@testable import VieEditor

/// Typing in Markdown lists, with the Mac keys and in Vim mode: Return continues or ends an
/// item, Tab and ⇧Tab nest it, Backspace removes its marker, numbered lists stay in order,
/// and none of it happens in code blocks or other files. (The rules themselves are tested in
/// MarkdownListTests.)
@MainActor
@Suite struct MarkdownListEditingTests {
    /// A Markdown view over `text`, "|" marking the cursor (without one, "[" and "]" mark a
    /// selection; task boxes are left alone).
    private func make(_ text: String, language: String? = "markdown", vim: Bool = false) -> EditorView {
        var s = text
        var anchor: Int?, head = 0
        if !s.contains("|"), let open = s.firstIndex(of: "["), let close = s.firstIndex(of: "]") {
            let a = s.utf8.distance(from: s.startIndex, to: open)
            var h = s.utf8.distance(from: s.startIndex, to: close)
            if a < h { h -= 1 }
            s.remove(at: s.firstIndex(of: "[")!)
            s.remove(at: s.firstIndex(of: "]")!)
            anchor = a < h ? a : a - 1
            head = h
        } else if let bar = s.firstIndex(of: "|") {
            head = s.utf8.distance(from: s.startIndex, to: bar)
            s.remove(at: bar)
        }
        let buffer = Buffer(rope: Rope(s))
        buffer.selection = Selection(anchor: anchor ?? head, head: head)
        let v = EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), buffer: buffer)
        v.pasteboard = NSPasteboard(name: NSPasteboard.Name("vie-test-\(UUID().uuidString)"))
        v.syntaxLanguage = language.flatMap { SyntaxLanguage.named($0) }
        v.vimEnabled = vim
        return v
    }

    private func settle(_ v: EditorView) async throws {
        for _ in 0..<400 {
            if let s = v.syntax, s.isReady, !s.isParsing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func state(_ v: EditorView) -> String {
        var bytes = v.rope.bytes(in: 0..<v.rope.byteCount)
        bytes.insert(UInt8(ascii: "|"), at: v.vim?.cursor ?? v.selection.head)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func run(_ v: EditorView, _ commands: String...) {
        for c in commands { v.doCommand(by: Selector(c)) }
    }

    private func event(_ chars: String, code: Int = 0xFFFF, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    /// Vim keys: Normal-mode characters, or the special keys named in braces.
    private func keys(_ v: EditorView, _ keys: String...) {
        for k in keys {
            switch k {
            case "{esc}": v.keyDown(with: event("\u{1B}", code: kVK_Escape))
            case "{cr}": v.keyDown(with: event("\r", code: kVK_Return))
            case "{tab}": v.keyDown(with: event("\t", code: kVK_Tab))
            case "{s-tab}": v.keyDown(with: event("\u{19}", code: kVK_Tab, flags: .shift))
            case "{bs}": v.keyDown(with: event("\u{7F}", code: kVK_Delete))
            default:
                if v.vim?.mode == .insert {
                    v.insertText(k, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    for c in k { v.keyDown(with: event(String(c))) }
                }
            }
        }
    }

    // MARK: - Mac keys

    @Test func returnContinuesTheItem() {
        let cases = [
            ("- one|", "- one\n- |"),
            ("  * two|", "  * two\n  * |"),
            ("- [x] done|", "- [x] done\n- [ ] |"),
            ("> quoted|", "> quoted\n> |"),
            ("- split|here", "- split\n- |here"),
            ("|- before the marker", "\n|- before the marker"),
        ]
        for (before, after) in cases {
            let v = make(before)
            run(v, "insertNewline:")
            #expect(state(v) == after, "\(before)")
        }
    }

    @Test func returnOnAnEmptyItemOutdentsThenEndsTheList() {
        let v = make("- a\n  - b|")
        run(v, "insertNewline:")
        #expect(state(v) == "- a\n  - b\n  - |")
        run(v, "insertNewline:")
        #expect(state(v) == "- a\n  - b\n- |")
        run(v, "insertNewline:")
        #expect(state(v) == "- a\n  - b\n|")
    }

    @Test func numberedItemsAreRenumbered() {
        let v = make("1. a|\n2. b\n3. c")
        run(v, "insertNewline:")
        #expect(state(v) == "1. a\n2. |\n3. b\n4. c")
        // One undo step takes back the new item and the renumbering.
        v.undo(nil)
        #expect(state(v) == "1. a|\n2. b\n3. c")
        // Deleting an item's line renumbers the ones after it.
        let w = make("1. a\n[2. b\n]3. c")
        run(w, "deleteBackward:")
        #expect(state(w) == "1. a\n|2. c")
    }

    @Test func tabNestsTheItemUnderTheOneAbove() {
        let v = make("- a\n- b|\n  - c\n- d")
        run(v, "insertTab:")
        #expect(state(v) == "- a\n  - b|\n    - c\n- d")
        run(v, "insertBacktab:")
        #expect(state(v) == "- a\n- b|\n  - c\n- d")
        // Numbered: the nested list starts at 1, and the outer one closes up.
        let n = make("1. a\n2. |b\n3. c")
        run(n, "insertTab:")
        #expect(state(n) == "1. a\n   1. |b\n2. c")
        run(n, "insertBacktab:")
        #expect(state(n) == "1. a\n2. |b\n3. c")
        // ⇧Tab on a top-level item does nothing; Tab in plain text still types spaces.
        let top = make("- a|")
        run(top, "insertBacktab:")
        #expect(state(top) == "- a|")
        let plain = make("text|")
        run(plain, "insertTab:")
        #expect(state(plain) == "text    |")
    }

    @Test func backspaceRemovesTheBoxThenTheMarker() {
        let v = make("  - [ ] |task")
        run(v, "deleteBackward:")
        #expect(state(v) == "  - |task")
        run(v, "deleteBackward:")
        #expect(state(v) == "  |task")
        run(v, "deleteBackward:")
        #expect(state(v) == " |task")
    }

    @Test func notInCodeBlocksOrOtherFiles() async throws {
        let v = make("```\n- a|\n```\n")
        try await settle(v)
        run(v, "insertNewline:")
        #expect(state(v) == "```\n- a\n|\n```\n")
        run(v, "insertTab:")
        #expect(state(v) == "```\n- a\n    |\n```\n")
        let swift = make("// - a|", language: "swift")
        run(swift, "insertNewline:")
        #expect(state(swift) == "// - a\n|")
        let plain = make("- a|", language: nil)
        run(plain, "insertNewline:")
        #expect(state(plain) == "- a\n|")
    }

    // MARK: - Vim mode

    @Test func vimOpensItemsAndContinuesThem() {
        let v = make("|1. a\n2. b", vim: true)
        keys(v, "o", "x", "{esc}")
        #expect(state(v) == "1. a\n2. |x\n3. b")
        keys(v, "u")
        #expect(state(v) == "|1. a\n2. b")
        keys(v, "j", "O", "y", "{esc}")
        #expect(state(v) == "1. a\n2. |y\n3. b")
        // Insert-mode Return: a new item, and on an empty one, out of the list.
        let w = make("|- [x] a", vim: true)
        keys(w, "A", "{cr}", "b", "{cr}", "{cr}", "c", "{esc}")
        #expect(state(w) == "- [x] a\n- [ ] b\n|c")
    }

    @Test func vimTabBackspaceAndRenumbering() {
        let v = make("|1. a\n2. b\n3. c", vim: true)
        keys(v, "j", "A", "{tab}")
        #expect(state(v) == "1. a\n   1. b|\n2. c")
        keys(v, "{s-tab}")
        #expect(state(v) == "1. a\n2. b|\n3. c")
        keys(v, "{esc}", "0fb", "i", "{bs}", "{esc}")
        #expect(state(v) == "1. a\n|b\n3. c")
        // dd renumbers, and u undoes it with the delete.
        let w = make("1. a\n|2. b\n3. c\n4. d", vim: true)
        keys(w, "dd")
        #expect(state(w) == "1. a\n|2. c\n3. d")
        keys(w, "u")
        #expect(state(w) == "1. a\n|2. b\n3. c\n4. d")
        // ⇧Tab outside a list types a tab, as in Vim.
        let plain = make("|x", vim: true)
        keys(plain, "i", "{s-tab}", "{esc}")
        #expect(state(plain) == "   | x")
    }
}
