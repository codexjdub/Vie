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
