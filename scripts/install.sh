#!/bin/bash
# Installs the built Vie.app in /Applications (or INSTALL_DIR), replacing the copy there.
# A running Vie is quit first (it asks about unsaved changes, as any quit does) and opened
# again afterwards. The build in BUILD_DIR is then dropped from Launch Services, so Open
# With and `open -a Vie` find the installed copy.
# Usage: scripts/install.sh (run by `make install`, after `make app`)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/common.sh

dest_dir="${INSTALL_DIR:-/Applications}"
dest="$dest_dir/Vie.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' App/Info.plist)"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$APP" ] || { echo "No app at $APP; run make app first." >&2; exit 1; }

# Never replace some other app that happens to be called Vie.
if [ -e "$dest" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing" != "$bundle_id" ]; then
        echo "$dest is not Vie (bundle id: ${existing:-none}); leaving it alone." >&2
        exit 1
    fi
fi

# Quit a running Vie. Without waiting for its reply: with unsaved changes it asks first,
# and the wait below gives a minute to answer.
was_running=false
if pgrep -x Vie >/dev/null; then
    was_running=true
    osascript -e 'ignoring application responses' -e "tell application id \"$bundle_id\" to quit" -e 'end ignoring'
    for _ in $(seq 1 240); do
        pgrep -x Vie >/dev/null || break
        sleep 0.25
    done
    if pgrep -x Vie >/dev/null; then
        echo "Vie is still running (unsaved changes to review?); quit it, then run make install again." >&2
        exit 1
    fi
fi

# Copy beside the old one, then swap, so a failed copy leaves the old app in place.
mkdir -p "$dest_dir"
staging="$dest_dir/.Vie.app.installing"
rm -rf "$staging"
ditto "$APP" "$staging"
codesign --verify --strict "$staging"
rm -rf "$dest"
mv "$staging" "$dest"

"$lsregister" -f "$dest"
"$lsregister" -u "$APP" 2>/dev/null || true

echo "Installed $dest"
if $was_running; then
    # Launch Services can take a moment to let go of the old process, and an open in that
    # window activates the dying one; so check that Vie started, and try again if not.
    for _ in 1 2 3; do
        open "$dest"
        for _ in $(seq 1 20); do
            pgrep -x Vie >/dev/null && break 2
            sleep 0.25
        done
    done
    pgrep -x Vie >/dev/null || echo "Vie didn't reopen; open it from Applications." >&2
fi
