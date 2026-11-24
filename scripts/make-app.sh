#!/bin/bash
# Assembles Vie.app from the SwiftPM build and signs it.
# Usage: scripts/make-app.sh [debug|release] [signing identity]
set -euo pipefail

config="${1:-release}"
identity="${2:-codexjdub}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/common.sh

swift build "${SCRATCH[@]}" -c "$config" --product Vie
bin="$(swift build "${SCRATCH[@]}" -c "$config" --show-bin-path)/Vie"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin" "$APP/Contents/MacOS/Vie"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp App/ThemeLicenses.txt "$APP/Contents/Resources/ThemeLicenses.txt"
# Help ▸ Vie Help opens the README.
cp README.md "$APP/Contents/Resources/Vie Help.md"
# The licenses of tree-sitter and of the grammars and queries built in, each with the source
# it was fetched from (scripts/fetch-grammars.sh records it in the folder's .source).
vendor="${VENDOR_DIR:-$HOME/Library/Caches/Vie-vendor}"
{
  echo "Vie is built with tree-sitter and these tree-sitter grammars and highlight queries,"
  echo "each under its own license, reproduced here."
  for stamp in "$vendor"/*/.source; do
    IFS='|' read -r name url _ < "$stamp"
    printf '\n\n==== %s\n%s\n\n' "$name" "$url"
    cat "$(dirname "$stamp")/LICENSE"
  done
  nvim="$(grep '^nvim=' scripts/fetch-grammars.sh | cut -d'"' -f2)"
  printf '\n\n==== nvim-treesitter (the LaTeX and BibTeX queries)\n%s\n\n' "$nvim"
  cat "$vendor/nvim-treesitter/LICENSE"
} > "$APP/Contents/Resources/GrammarLicenses.txt"
# Bundled fonts and their licenses (scripts/fetch-fonts.sh); the app registers them for
# itself when first needed (AppDelegate.registerBundledFonts).
fonts="${VENDOR_DIR:-$HOME/Library/Caches/Vie-vendor}/fonts"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$fonts"/*.ttf "$fonts"/*.txt "$APP/Contents/Resources/Fonts/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Hardened runtime, as notarization will require. No secure timestamp for local builds.
codesign --force --options runtime --timestamp=none --sign "$identity" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($config, signed by $identity)"
