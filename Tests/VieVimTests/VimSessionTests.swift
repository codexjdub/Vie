import Testing
import VieText
@testable import VieVim

/// Engines sharing a session behave like buffers in one Vim: registers, searches, `.` and
/// global options carry over; tabs and indenting stay per buffer.
@MainActor
@Suite struct VimSessionTests {
    private func engine(_ text: String, _ session: VimSession, _ host: TestHost) -> VimEngine {
        let e = VimEngine(buffer: Buffer(rope: Rope(text)), session: session)
        e.host = host
        return e
    }

    private func text(_ e: VimEngine) -> String { e.buffer.rope.string(in: 0..<e.buffer.rope.byteCount) }

    @Test func registersSearchAndDotAreShared() {
        let session = VimSession(), host = TestHost()
        let a = engine("one two", session, host), b = engine("x two two", session, host)
        a.handle(keys: VimKey.parse("yiw"))
        b.handle(keys: VimKey.parse("P"))
        #expect(text(b) == "onex two two")
        a.handle(keys: VimKey.parse("/two<CR>"))
        b.handle(keys: VimKey.parse("0n"))
        #expect(b.cursor == 5)
        a.handle(keys: VimKey.parse("0x"))
        b.handle(keys: VimKey.parse("0."))
        #expect(text(b) == "nex two two")
    }

    @Test func globalOptionsAreSharedButTabsAreNot() {
        let session = VimSession(), host = TestHost()
        let a = engine("a", session, host), b = engine("b", session, host)
        a.handle(keys: VimKey.parse(":set ic ts=8<CR>"))
        #expect(b.options.ignorecase)
        #expect(a.options.tabstop == 8)
        #expect(b.options.tabstop == 4)
    }

    @Test func bufferCommandsGoToTheHost() {
        let host = TestHost()
        let e = engine("a", VimSession(), host)
        for keys in [":ls<CR>", ":bn<CR>", ":bp 2<CR>", ":b 3<CR>", ":b foo<CR>", ":bd!<CR>", "gt", "4gt", "2gT", ":qa!<CR>", ":wa<CR>", ":xa<CR>", ":tabe x.txt<CR>"] {
            e.handle(keys: VimKey.parse(keys))
        }
        #expect(host.performed == [
            .listBuffers, .nextBuffer(count: 1), .previousBuffer(count: 2), .buffer("3"), .buffer("foo"),
            .deleteBuffer(force: true), .nextBuffer(count: 1), .buffer("4"), .previousBuffer(count: 2),
            .quitAll(force: true), .writeAll, .writeQuitAll, .edit(path: "x.txt", force: false),
        ])
    }

    /// The language ('filetype') is the host's; the other options in the same `:set` still apply.
    @Test func filetypeGoesToTheHost() {
        let host = TestHost()
        let e = engine("a", VimSession(), host)
        for keys in [":set ft=swift ts=8<CR>", ":se filetype=python<CR>", ":set ft?<CR>", ":set filetype<CR>", ":set ft=<CR>"] {
            e.handle(keys: VimKey.parse(keys))
        }
        #expect(host.performed == [.setFiletype("swift"), .setFiletype("python"), .showFiletype, .showFiletype, .setFiletype("")])
        #expect(e.options.tabstop == 8)
        #expect(e.message == nil)
    }

    /// The options about the file on disk are the host's, and so is `:e ++enc=`.
    @Test func fileOptionsGoToTheHost() {
        let host = TestHost()
        let e = engine("a", VimSession(), host)
        for keys in [":set ff=dos ts=4<CR>", ":set ff?<CR>", ":se fileencoding=latin1<CR>", ":set fenc<CR>",
                     ":set bomb<CR>", ":set nobomb<CR>", ":set invbomb<CR>", ":set bomb?<CR>",
                     ":e ++enc=sjis<CR>", ":e! ++encoding=cp1252 x.txt<CR>", ":e<CR>"] {
            e.handle(keys: VimKey.parse(keys))
        }
        #expect(host.performed == [
            .fileOption(.fileformat, value: "dos"), .fileOption(.fileformat, value: nil),
            .fileOption(.fileencoding, value: "latin1"), .fileOption(.fileencoding, value: nil),
            .fileOption(.bomb, value: "on"), .fileOption(.bomb, value: "off"), .fileOption(.bomb, value: "toggle"),
            .fileOption(.bomb, value: nil),
            .edit(path: nil, force: false, encoding: "sjis"), .edit(path: "x.txt", force: true, encoding: "cp1252"),
            .edit(path: nil, force: false),
        ])
        #expect(e.options.tabstop == 4)
        e.handle(keys: VimKey.parse(":e ++ff=dos<CR>"))
        #expect(e.message == "E474: Invalid argument" && host.performed.count == 11)
    }
}
