# Vie

A native Mac text editor: lightweight, very fast, Vim motions, a file pane.
Early development; see [PLAN.md](PLAN.md) for the architecture and milestones.

Today Vie is a text editor with a Vim mode: one file per window, mouse selection, undo,
copy and paste, IME input, and saving in the file's own encoding and line endings. Files
that change on disk reload automatically. The file tree and syntax highlighting come next.

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
| `Sources/VieWorkspace` | Documents on disk (open, save, reload) and file watching; folder tree and fuzzy finder in M3 |
| `Sources/vie-dev` | Developer tool: benchmark file generator |
| `Tests/` | Swift Testing suites for VieText, VieEditor, VieVim (the Vim specs) and VieWorkspace |
| `scripts/vim-oracle.py` | Checks the Vim specs against real Vim |
