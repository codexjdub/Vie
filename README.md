# Vie

A native Mac text editor: lightweight, very fast, Vim motions, a file pane.
Early development; see [PLAN.md](PLAN.md) for the architecture and milestones.

Today Vie is a plain text editor: one file per window, Mac text editing keys, mouse
selection, undo, copy and paste, IME input, and saving in the file's own encoding and line
endings. Files that change on disk reload automatically. Vim, the file tree and syntax
highlighting come next.

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

## Layout

| Path | What |
|---|---|
| `Sources/Vie` | App shell: windows, menus, launch options, benchmark mode |
| `Sources/VieEditor` | The text view: Core Text rendering, layout cache, input, scrolling |
| `Sources/VieText` | Persistent rope, Buffer with undo, character and word boundaries, encodings (pure Swift) |
| `Sources/VieVim` | Vim engine (M2) |
| `Sources/VieSyntax` | tree-sitter highlighting (M4) |
| `Sources/VieWorkspace` | Documents on disk (open, save, reload) and file watching; folder tree and fuzzy finder in M3 |
| `Sources/vie-dev` | Developer tool: benchmark file generator |
| `Tests/` | Swift Testing suites for VieText, VieEditor and VieWorkspace |
