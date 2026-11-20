# Vie

A native Mac text editor: lightweight, very fast, Vim motions, a file pane.
Early development; see [PLAN.md](PLAN.md) for the architecture and milestones.

Today Vie is a text editor with a Vim mode and folder windows: a file tree, tabs, a fuzzy
file finder, and the session restored at launch. It saves in each file's own encoding and
line endings, and files that change on disk reload automatically. Syntax highlighting comes
next.

## Workspaces

Open a folder (File ▸ Open…, or drop it on the Dock icon) to get a window with its file tree,
one tab per open file, and the editor. Files opened on their own share a window without a
sidebar.

- The tree lists folders as you expand them, so a 100,000-file repository opens instantly.
  It follows changes on disk (FSEvents), dims files git ignores, and has a context menu to
  create, rename, trash and reveal files.
- ⌘P finds a file by fuzzy matching on its path (`edv` finds `EditorView.swift`); git-ignored
  files are left out. With nothing typed it lists the open files, most recent first.
- ⌘T opens a tab, ⌘W closes one, ⇧⌘] and ⇧⌘[ switch, ⌃⌘S shows or hides the sidebar.
- In Vim mode: `:e file` opens a tab, `:ls`, `:b 2` or `:b name`, `:bn`, `:bp`, `:bd`, `gt`,
  `gT`, `:wa`, `:qa`, `:xa`. Registers, searches and `.` carry across tabs.
- Quitting remembers each window's folder, tabs, cursor positions and expanded folders, and
  the next launch reopens them.

## Vim mode

On by default; Edit ▸ Vim Mode turns it off, and Vie then behaves like a standard Mac text
view. Supported:

- Modes: Normal, Insert, Replace, Visual, Visual line, Visual block, Command line.
- Operators `d c y > < = g~ gu gU`, with counts and registers.
- Motions and text objects: words, `f t ; ,`, `% { } H M L`, `gg G`, marks, search; `iw aw`,
  quotes, brackets, `ip ap`, `it at`.
- `.` repeat, `u` and `⌃R`, registers (unnamed, `a–z`, `0–9`, `"+` for the clipboard), search
  `/ ? n N * #` with offsets, macros `q @`, `⌃A ⌃X`.
- Ex commands with ranges: `:w :q :wq :x :e :s :& :d :y :m :t :j :> :< :pu :norm :k :noh :set`.
- The status bar shows the mode, the command line, messages, keys typed so far and the cursor
  position.

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
make run FILE=path/to/file.txt
```

```bash
make test
```

```bash
make bench
```

`make app` builds and signs `Vie.app` (signing identity: `SIGN_ID`, default `codexjdub`).
`make bench` generates its test files (a 100 MB file, a 50 MB single-line file, a
100,000-file folder) on first run and times launch, scrolling, typing, the file tree and ⌘P.
Build output goes to `~/Library/Caches/Vie-dev` (override with `BUILD_DIR`), not the repo;
`scripts/common.sh` explains why.

Developer flags for the app binary (`Vie.app/Contents/MacOS/Vie`):

- `--hud` shows draw time and key latency, and prints stats on quit.
- `--bench` runs the scripted benchmark on the given file and quits.
- `--launch` prints time to first frame and quits.
- `--scale 2` times rendering at 2x in an offscreen bitmap (simulated Retina).
- `--type-line N` picks the line the benchmark types into.
- `-VimMode NO` starts with Vim mode off (the benchmark types through Insert mode when it's on).

## Layout

| Path | What |
|---|---|
| `Sources/Vie` | App shell: windows, menus, launch options, benchmark mode |
| `Sources/VieEditor` | The text view: Core Text rendering, layout cache, input, scrolling |
| `Sources/VieText` | Persistent rope, Buffer with undo, character and word boundaries, encodings (pure Swift) |
| `Sources/VieVim` | Vim engine: modes, motions, operators, registers, search, ex commands (pure Swift) |
| `Sources/VieSyntax` | tree-sitter highlighting (M4) |
| `Sources/VieWorkspace` | Documents on disk (open, save, reload), file and folder watching, git ignore rules, the file tree, the ⌘P scanner and fuzzy matcher |
| `Sources/vie-dev` | Developer tool: benchmark file and repository generators, `workspace-bench` |
| `Tests/` | Swift Testing suites for VieText, VieEditor, VieVim (the Vim specs), VieWorkspace (ignore rules checked against git) and the app's windows |
| `scripts/vim-oracle.py` | Checks the Vim specs against real Vim |
