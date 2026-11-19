# Vie — plan

A native Mac text editor: lightweight, very fast, Vim motions, a file pane. It should feel as
native as CotEditor, be as fast as Zed, and skip the IDE features. It targets the latest macOS
only (macOS 27 today) and ships as a notarized direct download.

## Goals and non-goals

**Goals**
- Native AppKit app that launches instantly and opens huge files without stalling.
- Vim editing that is good enough to stop noticing it is an emulation, and can be switched off
  for plain Mac-style editing.
- A workspace window: folder tree, ⌘P fuzzy finder, several open files.
- Syntax highlighting via tree-sitter.

**Non-goals for v1:** language servers, plugins/extensions, a built-in terminal, AI features,
collaboration, Windows/Linux. Each one is a reason Zed and VS Code are heavy; saying no is
what keeps Vie light.

## Performance budgets

Checked by a benchmark tool on every milestone (the spike's `--bench`, kept and extended).

Results on an Apple M4. The spike and M0 were measured on different days; on the same day
the spike launched in ~125 ms and M0 in ~141 ms.

| Metric | Budget | Spike | M0 (signed app) |
|---|---|---|---|
| Launch to first frame, empty | < 150 ms | ~105 ms | ~141 ms |
| Open a 100 MB file | < 150 ms | ~50 ms | ~56 ms |
| Frame work, scrolling or typing, p95 at 2x | < 4 ms | 2.9–4.4 ms | 3.1–3.6 ms |
| Worst frame (whole screen laid out cold) | < 8 ms | 8.4 ms | 7.6 ms (plus one 31 ms first-scroll frame) |
| Memory, empty window | < 40 MB | 22 MB | 27 MB |
| Memory on top of file size | < 15% | ~7% | ~8% |
| CPU while idle | 0% | not measured | not measured |

## Architecture

```
Vie.app            AppKit shell: windows, menus, keymap, settings
 ├─ VieWorkspace   folder tree · FSEvents watching · gitignore · fuzzy finder index
 ├─ VieEditor      EditorView: Core Text rendering · layout cache · input · scrolling · gutter
 │   ├─ VieVim     keys → commands → edits            (pure Swift, no AppKit)
 │   └─ VieSyntax  tree-sitter on background snapshots → highlight spans
 └─ VieText        persistent rope · Buffer · transactions · undo · encodings   (pure Swift)
```

Each box is a module (a SwiftPM target in one package). Dependencies only point downward. `VieText`, `VieVim` and
most of `VieSyntax` have no AppKit, so `swift test` covers them without launching anything.

### Key decisions

1. **Text storage: persistent UTF-8 B-tree rope.** The spike's rope, changed so edits copy
   only the path from leaf to root and leave the old version intact. A snapshot is then just a
   pointer, which makes background parsing, background saving and "is this buffer dirty?"
   checks free. Line endings are normalized to `\n` on load and restored on save.
2. **Rendering: draw visible rows only.** Core Text line layout, cached per line, invalidated by
   edits. The scroll position is anchored to a line (line, wrapped row, pixel offset) instead of
   an absolute pixel y. That's what makes soft wrap work on a 100 MB file: wrap counts are
   computed lazily and estimated until known, and edits above the viewport don't make the view
   jump. No NSTextView anywhere. Metal glyph rendering only if a benchmark ever needs it.
3. **Threading: the main thread owns buffers and UI.** Loading big files, parsing, indexing
   and saving run in the background on immutable snapshots. Each result is tagged with the
   buffer version it came from, and stale results are dropped.
4. **Document model: own Workspace and Buffer types, not NSDocument.** NSDocument assumes one
   document per window, while Vie's window is a workspace holding many buffers. Keep the Mac
   integrations by hand: Open Recent, Finder "Open With", drag and drop onto the Dock icon, the
   edited dot in the close button, reloading when a file changes on disk.
5. **Key handling has three layers.** Menu shortcuts (⌘S, ⌘Z, ⌘P…) always come first. In
   normal and visual mode, keys go to the Vim engine. Only insert mode passes keys through
   `interpretKeyEvents` and NSTextInputClient, so IME composition works where text is typed.
   Pressing Esc to return to normal mode switches the input source back to ASCII, which fixes
   the classic Vim + Japanese/Chinese input pain.
6. **The Vim engine is a pure state machine.** Keys are parsed into
   `count · register · operator · motion/text object`. Motions are pure functions over a
   snapshot that return a range (charwise, linewise or blockwise). Operators turn ranges into
   transactions. It's tested with a compact spec format, e.g. `"hel|lo world" dw → "hel|world"`.
7. **No SwiftUI in the editor path.** AppKit for the window, split view, outline view and
   editor. SwiftUI for the Settings window, which is the only place settings live (stored in
   UserDefaults, no config file). Key bindings and Vim mappings are edited there too.
8. **Swift 6 language mode** with strict concurrency from the start. Targeting only the latest
   macOS means every current API is available with no availability checks.

### Modules in more detail

**VieText**
- Rope: path-copying edits, inserting a large paste as a whole subtree instead of growing one
  leaf, merging underfull nodes after deletes, 2016-byte leaves (the spike's memory fix).
- Buffer: rope + selections + version number + undo/redo stack of transactions. A transaction
  is a list of (range, replacement) with selections before and after. An insert-mode session is
  one undo step.
- Cursor movement by grapheme cluster (emoji sequences, combining marks), computed on the
  small slice around the cursor.
- Encodings: UTF-8 (with or without BOM) natively; UTF-16 and legacy encodings converted on
  open and back on save.

**VieEditor**
- The spike's EditorView grown up: selections, block/bar/underline cursors per mode, cursor
  blink, mouse selection (drag, double-click word, triple-click line), horizontal scroll when
  wrap is off, soft wrap, current-line and matching-bracket highlight, gutter with relative line
  numbers as an option.
- NSTextInputClient (from the spike) tested with real Japanese and Chinese input methods.
- Basic VoiceOver support. A custom view gets nothing for free here, so it needs planned work.

**VieVim** (v1 scope)
- Modes: normal, insert, replace, visual, visual line, visual block, command line.
- Operators: `d c y > < = g~ gu gU`, with counts and registers.
- Motions: `h j k l w b e W B E ge 0 ^ $ gg G f F t T ; , % { } H M L`, plus `⌃d ⌃u ⌃f ⌃b`.
- Text objects: `iw aw iW aW` quotes `i" a" i' a'` brackets `i( a( i[ a[ i{ a{ i< a<`
  and `ip ap it at`.
- `.` repeat, `u` / `⌃r`, registers (unnamed, `a–z`, `0–9`, `"+` for the system clipboard),
  search `/ ? n N * #`, marks, macros `q @`.
- Ex commands: `:w :q :wq :x :e :s/…/…/g` with ranges, `:noh`, `:set` for a few options.
- Not in v1: Vimscript, plugins, most of ex.
- Vim can be turned off, in which case Vie behaves like a standard Mac text view.

**VieSyntax**
- tree-sitter through SwiftTreeSitter or the C API directly. About 12 grammars bundled
  (Swift, C/C++, JS/TS, Python, Rust, Go, JSON, YAML, TOML, Markdown, shell, HTML/CSS).
- Incremental parsing in the background; highlight queries limited to the visible range.
- A size threshold (start at 10 MB, then measure): above it, plain text or a cheap lexer.
- Themes map capture names to colors, with light and dark following the system appearance.

**VieWorkspace**
- Opening a folder creates a workspace window. Single files open in a one-file workspace.
- File tree: NSOutlineView with lazy loading, live updates from FSEvents, gitignore rules
  (own matcher, checked against `git check-ignore` in tests), and new/rename/delete/reveal
  in Finder from a context menu.
- ⌘P fuzzy finder: path index built in the background, fzf-style scoring, results updated on
  every keystroke.
- Restoring the session on relaunch: open folders, buffers, cursor positions.

### Tooling: Command Line Tools only, no Xcode

Checked on this machine (Swift 6.4, macOS 27 SDK):

| Need | How |
|---|---|
| Build | SwiftPM plus a `make app` script that assembles `Vie.app` (Info.plist, icon, binary). |
| Build output | `~/Library/Caches/Vie-dev`, outside the repo. The repo is in iCloud-synced Documents, and iCloud's extended attributes make `codesign` reject bundles. |
| Tests | Swift Testing works, but `swift test` misses the testing macro plugin, so `make test` passes `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. XCTest isn't available. |
| Signing | Builds are signed with the local self-signed `codexjdub` identity (code signing, valid until 2036) and hardened runtime. A stable identity keeps macOS permissions and keychain access across rebuilds, unlike ad-hoc signing. |
| Notarization | `notarytool` and `stapler` are available, but notarizing needs an Apple-issued Developer ID Application certificate from the paid Apple Developer Program. A self-signed certificate can't be notarized, so this waits until the M5 release build. |
| App icon | Classic `.icns` built with `iconutil`. The layered icon format needs Xcode's `actool`, so macOS may show the icon on a standard rounded-square background. |
| Profiling | No Instruments. Use the benchmark tool plus the built-in `sample`, `footprint`, `leaks`, `heap` and `vmmap`. |
| Debugging | `lldb` from the command line. |

## Milestones

Each milestone ends with something usable and a benchmark run against the budgets.

| # | Milestone | Done when |
|---|---|---|
| M0 | **Foundations** (done 2026-11-18). Git repo, SwiftPM packages, a Makefile with `app`, `test` and `bench` targets, a `Vie.app` signed with the `codexjdub` identity, the spike's benchmark as a permanent tool, TODO.md seeded. | `make app` builds a `Vie.app` that opens a file in the spike's view, `make test` runs, and `make bench` prints its table. |
| M1 | **Plain editor.** Persistent rope, Buffer with undo, selections, copy/paste, Mac text keys, atomic open/save, encodings and line endings, grapheme-aware movement, IME, reload on external change. | Usable instead of TextEdit for plain text, within all budgets. |
| M2 | **Vim.** Everything in the v1 scope above. | About 300 spec tests pass, and a full day of editing without the mouse feels right. |
| M3 | **Workspace.** Folder windows, file tree, ⌘P, multiple open files, session restore. | A 100,000-file repo shows its tree in under 200 ms, and ⌘P updates within one frame. |
| M4 | **Syntax.** tree-sitter, 12 grammars, light/dark themes, size threshold. | Highlighting never pushes frame work over budget. |
| M5 | **Daily driver.** Soft wrap, find/replace bar, `:s`, macros and marks, Settings window, crash recovery, basic VoiceOver, icon, notarized build with auto-update (e.g. Sparkle). | You use Vie instead of your current editor. |

After v1, if they still seem worth it: project-wide search, split panes, git change markers in
the gutter. LSP only if it can stay optional and out of process.

The `spike/` folder stays as reference until M1 matches it, then gets deleted.

## Risks

- **Vim fidelity.** Partial emulations feel wrong in small ways. Mitigation: a spec test for
  every behavior, checked against real Vim.
- **Soft wrap on huge files.** Line-anchored scrolling is the design answer, but it's the
  trickiest part of the view. Give it its own time in M5.
- **IME and accessibility.** Both are easy to postpone and painful to retrofit. IME is tested in
  M1; accessibility has a slot in M5.
- **tree-sitter on large files.** Initial parse time and memory grow with file size. The size
  threshold and benchmark protect the budgets.
- **Scope creep.** Every "small" IDE feature costs launch time, memory or complexity. The
  non-goals list is the default answer.

## Decisions

Made 2026-11-18.

| Question | Decision | What it means |
|---|---|---|
| Minimum macOS | Latest only (27 today) | Newest APIs everywhere; the deployment target moves up with each major release. |
| Distribution | Notarized direct download | No sandbox. Dev builds are signed with `codexjdub`; the public release needs a Developer ID certificate for notarization. |
| Open files | Tabs, plus a buffer list for Vim users | Tab bar per window; `:ls`/`:b` and a sidebar list over the same buffers. |
| Tooling | Command Line Tools only | See the Tooling table: `make` targets work around the gaps; no Instruments. |
| Config | Settings window only | All settings in UserDefaults, edited in a SwiftUI Settings window; no dotfile. |
