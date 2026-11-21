import Testing
import VieText
@testable import VieVim

/// Space starts two-key commands in Normal mode (Space e: the file tree), as a leader mapping
/// does in Vim. Any other key after it is Vim's Space (move right) and then that key; a lone
/// Space moves right once Vim's 'timeoutlen' (a second) runs out.
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

    @Test func anotherKeyAfterSpaceRunsSpaceThenThatKey() {
        let e = engine("abc\ndef")
        e.handle(keys: VimKey.parse("<Space>j"))
        #expect(e.cursor == 5)
        // The first Space moves right when the second arrives, which then waits in turn.
        e.handle(keys: VimKey.parse("0<Space><Space>"))
        #expect(e.cursor == 5)
        e.timeoutPending()
        #expect(e.cursor == 6)
    }

    @Test func escAfterSpaceCancelsQuietly() {
        let host = TestHost()
        let e = engine("abc", host)
        e.handle(keys: VimKey.parse("<Space><Esc>"))
        e.timeoutPending()
        #expect(e.cursor == 0)
        #expect(host.beeps == 0)
    }

    @Test func aLoneSpaceMovesAfterASecond() async throws {
        let e = engine("abc")
        e.handle(keys: VimKey.parse("2<Space>"))
        #expect(e.cursor == 0)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(e.cursor == 2)
    }

    @Test func spaceIsStillAMotionAfterAnOperatorAndInVisualMode() {
        let e = engine("abcd")
        e.handle(keys: VimKey.parse("d<Space>"))
        #expect(text(e) == "bcd")
        e.handle(keys: VimKey.parse("v<Space>d"))
        #expect(text(e) == "d")
    }

    @Test func normalCommandRunsATrailingSpace() {
        let e = engine("abc")
        e.handle(keys: VimKey.parse(":norm 2 <CR>"))
        #expect(e.cursor == 2)
    }
}
