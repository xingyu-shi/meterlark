#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/sparkle-paths.sh"
: "${SPARKLE_PRIVATE_KEY_FILE:?Set SPARKLE_PRIVATE_KEY_FILE to the private signing key file}"
INFO="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
ARCHIVE="$ROOT/dist/Meterlark-${VERSION}-arm64.zip"
FEED="$ROOT/dist/appcast.xml"

swift -module-cache-path "$ROOT/.build/clang-module-cache" "$ROOT/scripts/verify-update-key.swift" "$SPARKLE_PRIVATE_KEY_FILE" "$INFO"
# A fresh staging directory is essential: dist may contain old or private
# artifacts. Publish metadata for this exact archive only.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/meterlark-update-feed.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$ARCHIVE" "$STAGING/$(basename "$ARCHIVE")"
python3 "$ROOT/scripts/update-feed.py" prepare "$INFO" "$ARCHIVE" "$STAGING"
"$SPARKLE_ROOT/bin/generate_appcast" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --maximum-deltas 0 \
    --maximum-versions 1 \
    --download-url-prefix "https://github.com/xingyu-shi/meterlark/releases/download/v$VERSION/" \
    --link "https://github.com/xingyu-shi/meterlark" \
    --full-release-notes-url "https://github.com/xingyu-shi/meterlark/blob/v$VERSION/CHANGELOG.md" \
    --embed-release-notes \
    -o "$STAGING/appcast.xml" "$STAGING"
"$SPARKLE_ROOT/bin/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$STAGING/appcast.xml"
"$SPARKLE_ROOT/bin/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$STAGING/appcast.xml"
ARCHIVE_SIGNATURE="$(python3 "$ROOT/scripts/update-feed.py" verify "$INFO" "$ARCHIVE" "$STAGING/appcast.xml")"
"$SPARKLE_ROOT/bin/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"
cp "$STAGING/appcast.xml" "$FEED"
print "Signed update feed: $FEED"
