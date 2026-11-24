import Testing
import VieText
@testable import VieVim

/// Space starts Vie's Space commands in Normal mode (Space e, Space f f…), LazyVim's leader
/// keys. It waits for the next key as long as it takes; Esc cancels and a key that isn't in
/// the menu beeps.
@MainActor
@Suite struct SpaceCommandTests {
    private func engine(_ text: String, _ host: TestHost = TestHost()) -> VimEngine {
        let e = VimEngine(buffer: Buffer(rope: Rope(text)))
        e.host = host
        return e
    }

    private func text(_ e: VimEngine) -> String { e.buffer.rope.string(in: 0..<e.buffer.rope.byteCount) }

    @Test func spaceEAsksTheHostForTheFileTree() {
        let host = TestHost()
        let e = engine("abc def", host)
        e.handle(keys: VimKey.parse("<Space>e"))
        e.handle(keys: VimKey.parse("3<Space>e"))
        #expect(host.performed == [.toggleSidebar, .toggleSidebar])
        #expect(e.cursor == 0)
        #expect(host.beeps == 0)
    }

    /// ⌃H goes to the file tree, as LazyVim maps it. Backspace (the delete key, DEL) still
    /// moves left, and so does ⌃H after an operator.
    @Test func ctrlHAsksForTheFileTreeAndBackspaceStillMovesLeft() {
        let host = TestHost()
        let e = engine("abc\ndef", host)
        e.handle(keys: VimKey.parse("j$<C-h>"))
        #expect(host.performed == [.focusSidebar] && e.cursor == 6)
        e.handle(keys: VimKey.parse("<BS>"))
        #expect(e.cursor == 5)
        e.handle(keys: VimKey.parse("d<C-h>"))
        #expect(text(e) == "abc\nef" && e.cursor == 4)
        #expect(host.performed == [.focusSidebar] && host.beeps == 0)
    }

    /// ⇧H and ⇧L switch tabs, a count moving that many; after an operator they're still
    /// the screen's top and bottom lines.
    @Test func shiftHAndLSwitchTabs() {
        let host = TestHost()
        let e = engine("abc", host)
        e.handle(keys: VimKey.parse("L2LH"))
        #expect(host.performed == [.nextBuffer(count: 1), .nextBuffer(count: 2), .previousBuffer(count: 1)])
        #expect(host.beeps == 0)
    }

    /// LazyVim's leader keys for what Vie does, each passed to the host.
    @Test func spaceCommandsAskTheHost() {
        let host = TestHost()
        let e = engine("abc", host)
        e.handle(keys: VimKey.parse("<Space><Space><Space>ff<Space>fn<Space>fe<Space>bd<Space>qq<Space>uw"))
        #expect(host.performed == [.findFile, .findFile, .newFile, .toggleSidebar, .closeTab, .quitApp, .toggleWrap])
        #expect(host.beeps == 0 && e.cursor == 0)
    }

    /// A key that isn't in the menu beeps and does nothing, at the top or in a group; the
    /// next key starts afresh.
    @Test func anotherKeyAfterSpaceBeeps() {
        let host = TestHost()
        let e = engine("abc\ndef", host)
        e.handle(keys: VimKey.parse("<Space>j"))
        #expect(e.cursor == 0 && host.beeps == 1)
        e.handle(keys: VimKey.parse("<Space>fz"))
        #expect(e.cursor == 0 && host.beeps == 2 && host.performed.isEmpty)
        e.handle(keys: VimKey.parse("j"))
        #expect(e.cursor == 4)
    }

    @Test func escAfterSpaceCancelsQuietly() {
        let host = TestHost()
        let e = engine("abc", host)
        e.handle(keys: VimKey.parse("<Space><Esc><Space>f<Esc>"))
        e.timeoutPending()
        #expect(e.cursor == 0 && e.spacePrefix == nil)
        #expect(host.beeps == 0 && host.performed.isEmpty)
    }

    /// A Space waits for its next key however long it takes, as with LazyVim's which-key.
    @Test func aLoneSpaceWaits() async throws {
        let e = engine("abc")
        e.handle(keys: VimKey.parse("2<Space>"))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(e.cursor == 0 && e.spacePrefix == "" && e.pendingText == "2␣")
    }

    /// What the host's hint lists: commands, then groups, each in key order; a group's keys
    /// once its key is typed; nothing once the command ran or was cancelled.
    @Test func theHintListsWhatCanFollow() {
        let e = engine("abc")
        #expect(e.spaceHint == nil)
        e.handle(keys: VimKey.parse("<Space>"))
        #expect(e.spaceHint?.map { "\($0.key) \($0.title)" } == [
            "  Find file", "e File tree", "b +buffer", "f +file/find", "q +quit", "u +ui",
        ])
        #expect(e.spaceHint?.filter(\.isGroup).map(\.key) == ["b", "f", "q", "u"])
        e.handle(keys: VimKey.parse("f"))
        #expect(e.spacePrefix == "f" && e.pendingText == "␣f")
        #expect(e.spaceHint?.map { "\($0.key) \($0.title)" } == ["e File tree", "f Find file", "n New file"])
        e.handle(keys: VimKey.parse("<Esc>"))
        #expect(e.spaceHint == nil)
        e.handle(keys: VimKey.parse("<Space>e"))
        #expect(e.spaceHint == nil)
    }

    @Test func spaceIsStillAMotionAfterAnOperatorAndInVisualMode() {
        let e = engine("abcd")
        e.handle(keys: VimKey.parse("d<Space>"))
        #expect(text(e) == "bcd")
        e.handle(keys: VimKey.parse("v<Space>d"))
        #expect(text(e) == "d")
    }

    /// At the end of `:normal`'s keys a lone Space is Vim's Space (move right), as when Vim's
    /// 'timeout' runs out; a half-typed Space command is dropped.
    @Test func normalCommandRunsATrailingSpace() {
        let host = TestHost()
        let e = engine("abc", host)
        e.handle(keys: VimKey.parse(":norm 2 <CR>"))
        #expect(e.cursor == 2)
        e.handle(keys: VimKey.parse(":norm 0 f<CR>"))
        #expect(e.cursor == 0 && e.spacePrefix == nil && host.performed.isEmpty && host.beeps == 0)
    }
}
