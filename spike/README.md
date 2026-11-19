# VieSpike

Throwaway prototype answering one question: is a Swift/AppKit editor with its own text view fast?
It uses a UTF-8 B-tree rope, lays out only the visible lines with Core Text, caches line layouts,
and implements `NSTextInputClient` itself. It is not the editor and has no editor features.

## Build and run

```bash
swift build -c release
```

```bash
.build/release/VieSpike selftest
```

```bash
.build/release/VieSpike generate /tmp/source-100mb.swift 100
```

```bash
.build/release/VieSpike generate /tmp/longline-50mb.json 50 --long-line
```

```bash
.build/release/VieSpike /tmp/source-100mb.swift
```

Interactive mode shows a HUD with draw time and key-to-draw latency; ⌘Q prints stats.

Flags:

- `--bench` runs a scripted test (scroll, fling, random jumps, typing, backspace, cursor down),
  one step per display refresh, then prints a table and quits.
- `--scale 2` times each frame rendered into a 2x offscreen bitmap (simulated Retina).
  On a Retina Mac, leave it off: the real backing store is already 2x.
- `--launch` prints time from process start to first drawn frame, then quits.
- `--type-line N` picks the line the typing phase edits (default: middle of the file).

## Results (Apple M4, 60 Hz non-Retina display, 2026-11-18)

| | |
|---|---|
| Launch to first frame, empty | ~105 ms |
| Launch to first frame, 100 MB file | ~155 ms |
| Open 100 MB (map + build rope) | ~50 ms |
| Memory with 100 MB file | 129 MB (22 MB is the empty app) |
| Rope insert/delete, 100 MB file | ~4 µs p50, 10 µs max |
| Draw per frame, 2x, 52 visible lines | 2.0 ms p50, 2.3–3.6 ms p95, 7.9 ms max |
| Typing mid-file, 2x, edit + redraw | 2.9 ms p95, 3.9 ms max |
| 50 MB single-line file, 2x | 3–4 ms p95, no stalls |

Not covered: soft wrap, real tree-sitter (a small lexer stands in), selection, undo,
horizontal scroll, large pastes, grapheme clusters, a real 120 Hz or Retina display.
