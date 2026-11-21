#!/bin/bash
# Downloads the fonts bundled with Vie (JetBrains Mono and Terminus TTF, both under the SIL
# Open Font License) at pinned versions, checks each download's SHA-256, and keeps the font
# files and their licenses in VENDOR_DIR/fonts. scripts/make-app.sh copies them into the app.
# Run by make; does nothing when the fonts are already there.
set -euo pipefail

vendor="${VENDOR_DIR:-$HOME/Library/Caches/Vie-vendor}"
dest="$vendor/fonts"

# saved name | URL | SHA-256 | for a zip: files to keep, as path-in-archive[:saved name]
FILES=(
  "JetBrainsMono-Regular.ttf|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/ttf/JetBrainsMono-Regular.ttf|a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f|"
  "JetBrainsMono-Bold.ttf|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/ttf/JetBrainsMono-Bold.ttf|5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb|"
  "JetBrainsMono-Italic.ttf|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/ttf/JetBrainsMono-Italic.ttf|9d0a1f7a708e6af183f1193b7e81d40da294f5c67682c085d8401c60aac8ded4|"
  "JetBrainsMono-BoldItalic.ttf|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/ttf/JetBrainsMono-BoldItalic.ttf|4039d5ce0ed225bf9c8b2c8c6436290ae2f356b7e90d70fa666227238324aa3b|"
  "JetBrainsMono-OFL.txt|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/OFL.txt|30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad|"
  "terminus-ttf-4.49.3.zip|https://files.ax86.net/terminus-ttf/files/4.49.3/terminus-ttf-4.49.3.zip|0ead921d98d99a4590ffe6cd66dc037fc0a2ceea1c735d866ba73fe058257577|TerminusTTF-4.49.3.ttf TerminusTTF-Bold-4.49.3.ttf TerminusTTF-Italic-4.49.3.ttf TerminusTTF-Bold-Italic-4.49.3.ttf COPYING:TerminusTTF-COPYING.txt"
)

manifest="$(printf '%s\n' "${FILES[@]}" | shasum -a 256 | cut -d' ' -f1)"
if [ -f "$dest/.manifest" ] && [ "$(cat "$dest/.manifest")" = "$manifest" ]; then exit 0; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"
unpinned=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r name url sum keep <<< "$entry"
  echo "fetching $name"
  curl -fsSL --retry 2 -o "$work/$name" "$url"
  actual="$(shasum -a 256 "$work/$name" | cut -d' ' -f1)"
  if [ "$sum" = "-" ]; then
    echo "  unpinned; SHA-256 $actual"
    unpinned=1
  elif [ "$sum" != "$actual" ]; then
    echo "SHA-256 mismatch for $name: expected $sum, got $actual" >&2
    exit 1
  fi
  if [ -z "$keep" ]; then
    mv "$work/$name" "$work/out/$name"
    continue
  fi
  mkdir -p "$work/unzip"
  unzip -q -o "$work/$name" -d "$work/unzip"
  # The archive has one top folder.
  top="$(find "$work/unzip" -mindepth 1 -maxdepth 1 -type d | head -1)"
  for k in $keep; do
    src="${k%%:*}"; as="${k#*:}"
    [ -f "$top/$src" ] || { echo "missing $src in $name" >&2; exit 1; }
    cp "$top/$src" "$work/out/$as"
  done
  rm -rf "$work/unzip"
done

rm -rf "$dest"
mkdir -p "$vendor"
mv "$work/out" "$dest"
if [ "$unpinned" = 1 ]; then
  echo "some fonts aren't pinned yet; add their SHA-256 sums to $0" >&2
else
  echo "$manifest" > "$dest/.manifest"
fi
echo "fonts in $dest"
