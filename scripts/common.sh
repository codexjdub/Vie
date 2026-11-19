# Shared settings for the build scripts (sourced, not run).
#
# Build output lives outside the repo. The repo may sit in an iCloud Drive-synced folder,
# whose extended attributes make codesign fail ("resource fork, Finder information, or
# similar detritus not allowed"), and iCloud shouldn't upload build products anyway.
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/Vie-dev}"
SCRATCH=(--scratch-path "$BUILD_DIR/swiftpm")
APP="$BUILD_DIR/Vie.app"
