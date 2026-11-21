#!/bin/bash
# Generates benchmark files once, then measures launch time and runs the scripted benchmark.
# Requires Vie.app (make app). Windows appear on screen while it runs.
# BENCH_SCALE=2 (default) times rendering at 2x even on a non-Retina display; set it to
# empty on a Retina Mac, where the real backing store is already 2x.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/common.sh
scale="${BENCH_SCALE-2}"
scale_args=()
[ -n "$scale" ] && scale_args=(--scale "$scale")

swift build "${SCRATCH[@]}" -c release --product vie-dev
dev="$(swift build "${SCRATCH[@]}" -c release --show-bin-path)/vie-dev"
files="$BUILD_DIR/bench-files"
mkdir -p "$files"
[ -f "$files/source-100mb.swift" ] || "$dev" generate "$files/source-100mb.swift" 100
[ -f "$files/source-3mb.swift" ] || "$dev" generate "$files/source-3mb.swift" 3
[ -f "$files/longline-50mb.json" ] || "$dev" generate "$files/longline-50mb.json" 50 --long-line
[ -d "$files/repo-100k" ] || "$dev" generate-repo "$files/repo-100k" 100000

vie="$APP/Contents/MacOS/Vie"
[ -x "$vie" ] || { echo "$APP missing; run make app" >&2; exit 1; }

echo "== launch, empty (first run warms caches)"
for _ in 1 2 3 4; do "$vie" --launch; done
echo
echo "== launch, 100 MB file"
for _ in 1 2 3 4; do "$vie" "$files/source-100mb.swift" --launch; done
echo
"$vie" "$files/source-100mb.swift" --bench "${scale_args[@]}"
echo
"$vie" "$files/longline-50mb.json" --bench --type-line 0 "${scale_args[@]}"
echo
echo "== highlighted: 3 MB of Swift (under the 4 MB syntax limit)"
"$vie" "$files/source-3mb.swift" --bench "${scale_args[@]}"
echo
"$dev" syntax-bench "$files/source-3mb.swift"
echo
echo "== launch, 100,000-file folder (first frame with the tree)"
for _ in 1 2 3 4; do "$vie" "$files/repo-100k" --launch; done
echo
"$dev" workspace-bench "$files/repo-100k"
