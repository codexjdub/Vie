# Vie

A native Mac text editor: lightweight, very fast, Vim motions, a file pane.
Early development; see [PLAN.md](PLAN.md) for the architecture and milestones.

Today Vie is a text editor with a Vim mode and folder windows: a file tree, tabs, a fuzzy
file finder, and the session restored at launch. It highlights 17 languages with tree-sitter,
in 27 color themes (Vie's own, and popular ones such as Catppuccin, Dracula and Solarized)
that follow the system's appearance. It saves in each file's own encoding and
line endings, files that change on disk reload automatically, and unsaved changes survive a
crash.

## Workspaces

Open a folder (File ▸ Open…, or drop it on the Dock icon) to get a window with its file tree,
one tab per open file, and the editor. Files opened on their own share a window of loose
files, whose sidebar (hidden at first) shows the current file's project.

- The tree lists folders as you expand them, so a 100,000-file repository opens instantly.
  It follows changes on disk (FSEvents), dims files git ignores, and has a context menu to
  create, rename, trash and reveal files.
- In the tree, Return opens the file (or opens or closes a folder) and Esc goes back to the
  editor. In Vim mode it takes LazyVim's explorer keys: `j` and `k` move, `l` opens a file or
  folder, `h` closes the folder, `⌃L` goes back to the editor.
- ⌘P finds a file by fuzzy matching on its path (`edv` finds `EditorView.swift`); git-ignored
  files are left out. With nothing typed it lists the open files, most recent first.
- ⌘T opens a tab, ⌘W closes one, ⇧⌘] and ⇧⌘[ switch, ⌘1–⌘9 pick one (hold ⌘ to see the
  numbers), ⌃⌘S shows or hides the sidebar. In a window of loose files the sidebar shows the
  current file's project (the git repository holding it, else its folder) and switches with
  the tab, keeping each project's expanded folders; ⌘P searches the project shown.
- In Vim mode: `:e file` opens a tab, `:ls`, `:b 2` or `:b name`, `:bn`, `:bp`, `:bd`, `gt`,
  `gT`, `:wa`, `:qa`, `:xa`. As in LazyVim, `⇧H` and `⇧L` go to the previous and next tab,
  and Space e shows the sidebar with the keyboard in the tree, on the current file, and hides
  it again from the tree or the editor; `⌃H` moves into the tree while it's showing (a Space
  with no second key moves right after a second, as with a leader key in Vim). Registers,
  searches and `.` carry across tabs.
- File ▸ Open Recent lists recent folders and files, as does the Dock icon's menu: what you
  opened with File ▸ Open…, from Finder, the Dock, Open With, `open` or the command line, and
  files saved under a new name. Files opened from the sidebar, ⌘P or `:e` aren't added.
- Quitting remembers each window's folder, tabs, cursor positions and expanded folders, and
  the next launch reopens them, also when Vie is started by opening a file (from Finder,
  Open With or `open`): the file then opens in the window holding it, or a new one.
- Unsaved changes survive a crash, a force quit or a power cut. While a tab has unsaved
  changes, Vie copies its text to `~/Library/Application Support/Vie/Recovery` a second after
  you type (a second more per 10 MB). The next launch puts the text back into its tab,
  untitled tabs included, as unsaved changes: Undo or File ▸ Revert to Saved goes back to the
  file on disk. If the file changed on disk after the crash (a `git checkout`, say), Vie says
  so when you first see the tab and offers the version on disk instead; Undo brings your text
  back. A deleted file is mentioned too: its text stays, and saving creates it again. A copy
  goes once its tab is saved or closed, and a normal quit, which asks about unsaved changes
  as before, removes them all. Undo history from before a crash isn't kept.

## Syntax highlighting

BibTeX, Shell, C, C++, CSS, Go, HTML, JavaScript (with JSX), JSON, LaTeX, Markdown, Python,
Rust, Swift, TOML, TypeScript (and TSX) and YAML, picked by file name, extension or `#!` line.
Markdown code blocks are highlighted in their own language, as are the scripts and styles in
HTML and the code in LaTeX's `minted` and `pycode` environments.

- Markdown uses Neovim's highlight queries, which color more than the grammar's own: list
  markers and open task boxes stand out, finished tasks (`- [x]`) are dimmed and struck
  through, table headers look like headings, quotes are in italics, and `~~text~~` is struck
  through. The line runs through bold, code and links inside, which keep their colors.
- LaTeX (`.tex`, `.sty`, `.cls`, `.ltx`) and BibTeX (`.bib`) use the latex-lsp grammars with
  Neovim's highlight queries. The LaTeX grammar is release 0.6.0, which doesn't allow `_` in
  label names, so `\label{fig_plot}` is colored only up to the `_`.

- The status bar shows the file's language; click it to pick another, or Plain Text. In Vim
  mode `:set ft=python` does the same (Vim's names work, and `:set ft=` is plain text), and
  `:set ft?` shows it. A language picked by hand stays with the tab through saves and
  restarts.

- Parsing runs in the background: a file shows as plain text first, then in color (about
  140 ms per MB for the first parse), and edits are reparsed incrementally (a few
  milliseconds in typical code).
- Files over 4 MB stay plain text. A parse tree takes about 40 times the file's size in
  memory, so a 4 MB file costs ~160 MB.
- Embedded languages (each Markdown paragraph's inline markup, code blocks, HTML scripts and
  styles, LaTeX listings) get small trees of their own. An edit reparses only the ones it
  touched, so typing costs about 2 ms in a 450 KB Markdown file and 5 ms in a 1.8 MB one. In
  files over 128 KB they're kept only within 64 KB of what's on screen and follow it: after a
  jump, what's being drawn gets its colors in about 5 ms, the rest of that stretch soon after.
- Markdown still takes more memory than code: about 30 MB for a 450 KB file and 95 MB for
  1.8 MB, mostly for the document's structure, whose grammar records every punctuation mark.
- The colors come from the light or dark theme chosen in Settings, whichever matches the
  appearance, and switch with it.

## Markdown lists

In Markdown files, outside code blocks, with the Mac keys and in Vim mode (Insert mode, and
`o` and `O`):

- Return continues a list item or quote: the same bullet, the next number, an empty task box
  (`- [ ] `), the same `>`. On an empty item it outdents the item, or ends the list if it
  isn't nested, so Return twice gets out of a list.
- Tab and ⇧Tab indent and outdent the item the cursor is in, wherever it is in the item,
  with the lines under it. Indenting nests the item under the one above, lined up with its
  text.
- Backspace where an item's text starts removes its task box, then its marker.
- Numbered lists are renumbered after edits that add, remove or indent lines (a nested list
  starts at 1), in the same undo step. A number typed by hand is left as typed.

## Soft wrap

Long lines wrap at the window's width. It's on by default: View ▸ Wrap Lines (⌥⌘L) turns it
off in every window, and `:set nowrap` in one tab.

- Wrapped rows start under the line's text (in Markdown and plain text, under a list item's
  or quote's text), and only a line's first row has a line number.
- ↑ and ↓ move by rows; in Vim mode `j` and `k` move by lines, as in Vim.
- Rows are worked out only for the lines on screen, so wrapping costs the same in a 100 MB
  file as in a small one. Lines over 4,096 characters wrap at a fixed number of columns,
  so a 50 MB line stays fast too.

## Settings, fonts and themes

Vie ▸ Settings (⌘,) holds the editor font, its size and ligatures, the appearance and color
themes, with live previews, and the Vim mode and Wrap Lines switches. Changes apply to every
window at once and are remembered.

- Fonts: SF Mono (the default), JetBrains Mono and Terminus TTF, which come with Vie, and any
  monospaced font installed on the Mac.
- Size: 8 to 40 pt, also from View ▸ Increase Font Size (⌘+ or ⌘=), Decrease Font Size (⌘−)
  and Reset Font Size (⌘0).
- Ligatures are off by default; on, fonts that have them (JetBrains Mono) draw `!=` as ≠ and
  `->` as an arrow.
- Changing the font keeps the text in place: the top line stays, and so does the cursor if it
  was on screen.
- Appearance: System (the default) follows the Mac's light or dark mode; Light or Dark keeps
  Vie in one.
- Themes: on System, one for light mode and one for dark (When light, When dark); on Light
  or Dark, just that one, and the other is kept for later. Each is previewed in the chosen
  font. They color the editor, the tabs and the status bar. Vie's own come first: Vie Light,
  Paper and Mint, Vie Dark and Ember.
- Then popular themes, in their original colors: Catppuccin (Latte, Frappé, Macchiato,
  Mocha), Dracula and its light theme Alucard, GitHub Light and Dark, Gruvbox Light and
  Dark, Nord, One Dark and One Light, Rosé Pine (and Moon, Dawn), Solarized Light and Dark,
  and Tokyo Night (and Storm, Moon, Day). Each follows the theme's own tree-sitter port for
  Neovim where there is one, bold and italics included.
- Vie's own themes keep text at 7:1 contrast or better and code colors at 4.5:1 (comments
  3.5:1), which a test checks. The ports keep their originals' colors, some much softer.
  Vie Dark's code colors are One Dark's.

JetBrains Mono and Terminus TTF are under the SIL Open Font License; their license files ship
next to them in `Vie.app/Contents/Resources/Fonts`. The licenses of tree-sitter, the grammars
and the queries ship as `Vie.app/Contents/Resources/GrammarLicenses.txt`, which `make app` puts
together from the downloaded sources. The ported themes' licenses (MIT, and
Apache 2.0 for tokyonight.nvim) ship as `Vie.app/Contents/Resources/ThemeLicenses.txt`, from
`App/ThemeLicenses.txt`.

## Vim mode

On by default. Edit ▸ Vim Mode (⌃⌘V), the V switch at the right end of the status bar, or
Settings turns it off and on again, in every window; off, Vie behaves like a standard Mac text
view. Supported:

- Modes: Normal, Insert, Replace, Visual, Visual line, Visual block, Command line.
- Operators `d c y > < = g~ gu gU`, with counts and registers.
- Motions and text objects: words, `f t ; ,`, `% { } H M L`, `gg G`, marks, search; `iw aw`,
  quotes, brackets, `ip ap`, `it at`. `H` and `L` move to the screen's top and bottom after an
  operator or in Visual mode; on their own they switch tabs, as in LazyVim.
- `.` repeat, `u` and `⌃R`, registers (unnamed, `a–z`, `0–9`, `"+` for the clipboard), search
  `/ ? n N * #` with offsets, macros `q @`, `⌃A ⌃X`.
- Ex commands with ranges: `:w :q :wq :x :e :s :& :d :y :m :t :j :> :< :pu :norm :k :noh :set`.
- Command-line history (100 searches, shared by `/` and `?`, and 100 commands, until Vie
  quits): ↑ and ↓ step through the entries that begin with what's typed, `⌃P` and `⌃N`
  through all of them.
- The status bar shows the mode, the command line, messages, keys typed so far, the cursor
  position and the file's language.
- The cursor is a block in Normal and Visual mode, steady as in Neovim; in Insert mode it's
  the Mac's blinking caret, as it is with Vim mode off.

Text typed in Insert mode and on the command line goes through the input method, so Japanese
or Chinese input works there. Leaving Insert mode with Esc switches to an ASCII input source,
so Normal-mode keys are commands again. ⌘ shortcuts (⌘S, ⌘Z, ⌘V…) keep working in every mode.

Behavior is checked against real Vim: each line in `Tests/VieVimTests/Specs` is a spec like
`"hel|lo world" → dw → "hel|world"`, run by `make test` and by `scripts/vim-oracle.py`, which
feeds the same keys to a headless Vim (needs `vim` on the PATH).

## Requirements

- macOS 27
- Swift 6.4 (Command Line Tools are enough; Xcode isn't needed)

## Build

```bash
make app
```

```bash
make install
```

```bash
make run FILE=path/to/file.txt
```

```bash
make test
```

```bash
make bench
```

`make app` builds and signs `Vie.app` (signing identity: `SIGN_ID`, default `codexjdub`).
`make install` builds it and puts it in `/Applications` (override with `INSTALL_DIR`) in place
of the copy there. A running Vie quits first, asking about unsaved changes as any quit does,
and reopens from the new copy. The build in `BUILD_DIR` is then dropped from Launch Services,
so Open With finds the installed copy. Signed with your own certificate, the app runs on the
Mac that built it; Gatekeeper rejects it on others, which needs a Developer ID and
notarization.
The first build downloads the tree-sitter library and grammars (`make grammars`, run by
`make app` and `make test`): `scripts/fetch-grammars.sh` fetches pinned releases, checks
their SHA-256, and unpacks them into `~/Library/Caches/Vie-vendor`, which the repo reaches
through a `Vendor` link; after a change to the script it fetches only what changed. The bundled fonts come the same way (`make fonts`,
`scripts/fetch-fonts.sh`, into `Vie-vendor/fonts`). Both stay out of git; later builds work
offline.
`make bench` generates its test files (a 100 MB file, a 50 MB single-line file, 3 MB of Swift
for highlighting, a 100,000-file folder) on first run and times launch, scrolling, typing,
highlighting, the file tree and ⌘P.
Build output goes to `~/Library/Caches/Vie-dev` (override with `BUILD_DIR`), not the repo;
`scripts/common.sh` explains why.
The app icon, `App/AppIcon.icns`, is drawn in code by `scripts/make-icon.swift` and checked
in; `make icon` redraws it after the script changes.

Developer flags for the app binary (`Vie.app/Contents/MacOS/Vie`):

- `--hud` shows draw time and key latency, and prints stats on quit.
- `--bench` runs the scripted benchmark on the given file and quits.
- `--launch` prints time to first frame and quits.
- `--scale 2` times rendering at 2x in an offscreen bitmap (simulated Retina).
- `--type-line N` picks the line the benchmark types into.
- `-VimMode NO` starts with Vim mode off (the benchmark types through Insert mode when it's on).
- `-WrapLines NO` starts with wrapping off.
- `-FontName "JetBrains Mono"`, `-FontSize 16` and `-Ligatures YES` start with that font
  (benchmarks always use SF Mono at 13 pt).
- `-Appearance dark` (or `light`, `system`), `-LightTheme Paper` and `-DarkTheme Nord`
  start with that appearance and those themes (benchmarks always use the default themes).

## Layout

| Path | What |
|---|---|
| `Sources/Vie` | App shell: windows, menus, settings and the Settings window (SwiftUI), launch options, benchmark mode |
| `Sources/VieEditor` | The text view: Core Text rendering, layout cache, input, scrolling |
| `Sources/VieText` | Persistent rope, Buffer with undo, character and word boundaries, encodings (pure Swift) |
| `Sources/VieVim` | Vim engine: modes, motions, operators, registers, search, ex commands (pure Swift) |
| `Sources/VieSyntax` | Highlighting: languages, tree-sitter queries, background parsing, injected languages |
| `Sources/TreeSitterGrammars` | The grammars' C sources (from `Vendor`) and their highlight queries, embedded in the app |
| `Sources/VieWorkspace` | Documents on disk (open, save, reload), copies of unsaved text for crash recovery, file and folder watching, git ignore rules, the file tree, the ⌘P scanner and fuzzy matcher |
| `Sources/vie-dev` | Developer tool: benchmark file and repository generators, `workspace-bench`, `syntax-bench` |
| `Tests/` | Swift Testing suites for VieText, VieEditor, VieVim (the Vim specs), VieSyntax, VieWorkspace (ignore rules checked against git) and the app's windows |
| `App/` | `Info.plist` and `AppIcon.icns`, copied into the bundle by `scripts/make-app.sh` |
| `scripts/make-icon.swift` | Draws the app icon in Core Graphics at every size and packs it with `iconutil` (`make icon`) |
| `scripts/install.sh` | Replaces the installed `Vie.app` with the build, quitting and reopening a running Vie (`make install`) |
| `scripts/fetch-fonts.sh` | Downloads the pinned JetBrains Mono and Terminus TTF files into `~/Library/Caches/Vie-vendor/fonts` |
| `scripts/fetch-grammars.sh` | Downloads the pinned tree-sitter sources (and Neovim's LaTeX, BibTeX and Markdown queries) into `~/Library/Caches/Vie-vendor` |
| `scripts/vim-oracle.py` | Checks the Vim specs against real Vim |
