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
the spike launched in ~125 ms and M0 in ~141 ms. M1 was measured on 2026-11-19; its open time
now includes checking that the file is valid UTF-8 and scanning for CR line endings. M2 was
measured the same day with Vim mode on (typing goes through Insert mode); the slower launch and
higher empty-window memory reproduce with M1 rebuilt that day, so they're the machine, not M2.
M3 was measured on 2026-11-20 on battery with the built-in 60 Hz display, which is slower than
the earlier runs on an external display; M2 rebuilt and run alternately with M3 that day gave
the same numbers (in parentheses), so the differences from the M2 column are the machine.
M4 was measured the same day, also on battery; M3 rebuilt and launched alternately with M4
gave the same launch times (in parentheses). In M4 the 100 MB file is over the syntax limit,
so it's plain text, where M3 colored it with a stand-in lexer; the highlighted rows use a
generated 3 MB Swift file, with the same file as plain text for comparison.

| Metric | Budget | Spike | M0 (signed app) | M1 | M2 (Vim on) | M3 (on battery) | M4 (on battery) |
|---|---|---|---|---|---|---|---|
| Launch to first frame, empty | < 150 ms | ~105 ms | ~141 ms | 100–135 ms | 138–145 ms (M1 rebuilt the same day: ~140 ms) | 123–138 ms (M2: 124–153 ms) | 145–146 ms (M3: 140–151 ms) |
| Open a 100 MB file | < 150 ms | ~50 ms | ~56 ms | ~59 ms | ~62 ms | ~59 ms (M2: ~58 ms) | ~63 ms |
| Frame work, scrolling or typing, p95 at 2x | < 4 ms | 2.9–4.4 ms | 3.1–3.6 ms | 3.2–4.3 ms | 2.9–4.3 ms | 4.3–5.6 ms (M2: 4.3–5.9 ms) | 4.3–5.1 ms (100 MB, plain) |
| Worst frame (whole screen laid out cold) | < 8 ms | 8.4 ms | 7.6 ms (plus one 31 ms first-scroll frame) | 5.7–8.5 ms (one run had a 21 ms first-scroll frame) | 7.2–9.4 ms | 8.6–10.2 ms, jumping to random lines (M2: 9.1–10.8 ms) | 5.3–6.8 ms (100 MB, plain) |
| Memory, empty window | < 40 MB | 22 MB | 27 MB | 26 MB | 34–84 MB (M1 rebuilt the same day: the same) | 106–109 MB (M2: 102 MB) | 67 MB |
| Memory on top of file size | < 15% | ~7% | ~8% | ~8% | ~8% | ~235 MB footprint after the first frame, as M2 (233–286 MB); too noisy on this run for a percentage | 193 MB footprint after the first frame of the 100 MB file |
| CPU while idle | 0% | not measured | not measured | not measured | not measured | not measured | not measured |
| 100,000-file folder: tree | < 200 ms | | | | | top folder listed in ~4 ms; first frame with the tree 168–243 ms after process start | top folder listed in ~8 ms; first frame with the tree 181–205 ms after process start |
| 100,000-file folder: ⌘P per keystroke | < 1 frame | | | | | p50 1.7 ms, p95 5.4 ms, max 6.0 ms; scan (background) 0.36–1 s, index 16 ms | p50 1.6 ms, p95 5.2 ms, max 5.6 ms; scan (background) 1.2 s, index 17 ms |
| Highlighted 3 MB Swift file: frame work p95, worst frame | < 4 ms, < 8 ms | | | | | | | 3.1–6.1 ms, 7.4 ms (one 8.4–9.4 ms frame on the first scroll, where plain text sometimes spikes too); the same file as plain text: 4.0–4.7 ms, 5.2–7.5 ms |
| Highlighting: first parse, reparse, tree memory | in the background | | | | | | | ~470 ms for 3 MB (~140 ms per MB); reparse 3–10 ms in real code (65–72 ms in the generated file); tree ~40× the file's size |

## Architecture

```
Vie.app            AppKit shell: windows, menus, keymap, settings
 ├─ VieWorkspace   documents on disk · file watching · folder tree · gitignore · fuzzy finder
 ├─ VieEditor      EditorView: Core Text rendering · layout cache · input · scrolling · gutter
 │   ├─ VieVim     keys → commands → edits            (pure Swift, no AppKit)
 │   └─ VieSyntax  tree-sitter on background snapshots → highlight spans
 └─ VieText        persistent rope · Buffer · undo · boundaries · encodings   (pure Swift)
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
   normal and visual mode, keys go to the Vim engine. Only text typed in insert mode and on
   the command line passes through `interpretKeyEvents` and NSTextInputClient, so IME
   composition works where text is typed.
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
- Buffer: rope + selection + version number + undo/redo stack of transactions. A transaction
  is a list of (range, replacement) with selections before and after. An insert-mode session is
  one undo step. M1 has one selection; M2 extends it for Vim's visual block mode.
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

**VieSyntax** (M4)
- tree-sitter through the C API, compiled from pinned source releases that
  `scripts/fetch-grammars.sh` downloads outside the repo. 17 grammars for 15 languages: Swift,
  C, C++, JavaScript (JSX), TypeScript, TSX, Python, Rust, Go, JSON, YAML, TOML, Markdown (block
  and inline), shell, HTML, CSS. The upstream highlight and injection queries are embedded with
  C23 `#embed`, with predicates (`#eq?`, `#match?`, `#any-of?`…) evaluated in Swift.
- Incremental parsing on one background queue: the main thread edits its tree at once and
  starts a parse on a snapshot; edits made meanwhile are replayed onto the result. Changed
  ranges (from tree-sitter, plus the edited text) tell the view which lines to lay out again.
  Old trees are freed in the background too, since freeing a big one takes milliseconds.
- Injected languages (Markdown code blocks and inline markup, HTML scripts and styles) are
  parsed into layers whose highlights go over the outer tree's.
- Queries run over a window of about a screenful around the line being laid out, and the
  view's following lines are served from it: one query per screen instead of one per line,
  since each query walks down the tree to its range (0.5 ms per cold screen instead of 1–4).
- Size threshold: 4 MB (measured; see M4). A tree takes ~40× the file's size in memory and
  the first parse ~140 ms per MB, so above it files stay plain text.
- Themes map capture names (longest dotted prefix) to a small set of highlight kinds, with
  light and dark palettes following the system appearance.

**VieWorkspace**
- `Document` (M1): a buffer and its file. Atomic saves that keep permissions and symlinks,
  saving off the main thread on a snapshot, and watching the file so outside changes reload
  (silently when there are no unsaved edits; reloading is undoable).
- Opening a folder creates a workspace window. Single files open in a one-file workspace.
- File tree (M3): NSOutlineView with lazy loading, live updates from FSEvents, gitignore rules
  (own matcher, a port of git's wildmatch, checked against `git ls-files` in tests), and
  new/rename/trash/reveal in Finder from a context menu.
- ⌘P fuzzy finder (M3): path index built in the background, fzf-style scoring with its
  alignment search ("v2"), searched across cores and narrowed as the query grows, results
  updated on every keystroke.
- Restoring the session on relaunch (M3): open folders, tabs, cursor positions, expanded folders.

### Tooling: Command Line Tools only, no Xcode

Checked on this machine (Swift 6.4, macOS 27 SDK):

| Need | How |
|---|---|
| Build | SwiftPM plus a `make app` script that assembles `Vie.app` (Info.plist, icon, binary). |
| Build output | `~/Library/Caches/Vie-dev`, outside the repo. The repo is in iCloud-synced Documents, and iCloud's extended attributes make `codesign` reject bundles. |
| Tests | Swift Testing works, but `swift test` misses the testing macro plugin, so `make test` passes `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. XCTest isn't available. Six test targets: VieText, VieEditor (drives the view's commands and key events without a window), VieVim (spec files, checked against the system's `vim` by `scripts/vim-oracle.py`), VieSyntax (every grammar and query, injections, incremental edits), VieWorkspace (real files and git repositories in a temp folder) and VieAppTests (the app's window controllers, with real windows but no clicks). |
| Signing | Builds are signed with the local self-signed `codexjdub` identity (code signing, valid until 2036) and hardened runtime. A stable identity keeps macOS permissions and keychain access across rebuilds, unlike ad-hoc signing. |
| Notarization | `notarytool` and `stapler` are available, but notarizing needs an Apple-issued Developer ID Application certificate from the paid Apple Developer Program. A self-signed certificate can't be notarized, so this waits until the M5 release build. |
| App icon | Classic `.icns`, drawn in Core Graphics by `scripts/make-icon.swift` and packed with `iconutil`. The layered Icon Composer format needs Xcode's `actool`. macOS 27 shows an `.icns` drawn on the icon grid (an 824 px body with continuous corners on a 1024 canvas) at full size with its own glass edge, without the gray background it gives other legacy icons; tinted and clear appearances are derived by the system. |
| Profiling | No Instruments. Use the benchmark tool plus the built-in `sample`, `footprint`, `leaks`, `heap` and `vmmap`. |
| Debugging | `lldb` from the command line. |

## Milestones

Each milestone ends with something usable and a benchmark run against the budgets.

| # | Milestone | Done when |
|---|---|---|
| M0 | **Foundations** (done 2026-11-18). Git repo, SwiftPM packages, a Makefile with `app`, `test` and `bench` targets, a `Vie.app` signed with the `codexjdub` identity, the spike's benchmark as a permanent tool, TODO.md seeded. | `make app` builds a `Vie.app` that opens a file in the spike's view, `make test` runs, and `make bench` prints its table. |
| M1 | **Plain editor** (done 2026-11-19). Persistent rope, Buffer with undo, selections, copy/paste, Mac text keys, atomic open/save, encodings and line endings, grapheme-aware movement, IME, reload on external change. | Usable instead of TextEdit for plain text, within all budgets. IME follows the NSTextInputClient protocol in tests; a session with real Japanese and Chinese input methods is still to do. |
| M2 | **Vim** (done 2026-11-19). Everything in the v1 scope above, plus more ex commands (`:d :y :m :t :j :pu :norm :k :&`), `⌃A`/`⌃X`, search offsets and Vim regex; block, bar and underline cursors, search highlighting, a status bar, and a menu toggle. | About 300 spec tests pass, and a full day of editing without the mouse feels right. 580 specs pass and match real Vim; the full day of editing is still to do. |
| M3 | **Workspace** (done 2026-11-20). Folder windows, file tree with git ignore rules and FSEvents, tabs, ⌘P, Vim buffer commands and registers shared across buffers, session restore. | A 100,000-file repo shows its tree in under 200 ms, and ⌘P updates within one frame. Listing the tree takes ~4 ms; the window's first frame comes 168–243 ms after process start, of which ~130 ms is the app's own launch. ⌘P takes 1.5 ms per keystroke (p50), under 6 ms at worst, over 100,000 paths. |
| M4 | **Syntax** (done 2026-11-20). tree-sitter with 17 grammars for 15 languages, injected languages (Markdown code blocks, HTML scripts and styles), light and dark themes following the system, a 4 MB size threshold. | Highlighting never pushes frame work over budget. Worst frames stay under 8 ms except one first-scroll frame (8.4–9.4 ms; plain text sometimes spikes there too). p95 is 0.4–1.4 ms above plain text when lines are laid out cold, and plain text is already over 4 ms on this machine on battery. Parsing runs in the background, so it never costs a frame. |
| M5 | **Daily driver** (in progress: soft wrap and icon done 2026-11-20). Soft wrap, find/replace bar, `:s`, macros and marks, Settings window, crash recovery, basic VoiceOver, icon, notarized build with auto-update (e.g. Sparkle). | You use Vie instead of your current editor. |

After v1, if they still seem worth it: project-wide search, split panes, git change markers in
the gutter. LSP only if it can stay optional and out of process.

The speed prototype (`spike/`) was deleted in M1 once Vie matched it; it's in the first commit
(7786c97) for reference.

## Risks

- **Vim fidelity.** Partial emulations feel wrong in small ways. Mitigation: a spec test for
  every behavior, checked against real Vim.
- **Soft wrap on huge files.** Line-anchored scrolling is the design answer, but it's the
  trickiest part of the view. Done in M5: rows are counted only near the view, and lines
  over 4,096 characters wrap at a fixed column count. Wrapping adds 0.1–0.5 ms per frame
  (p95) on the 100 MB file and 0.6–1.6 ms on the 50 MB single-line one.
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
