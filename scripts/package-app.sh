#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# This package has no build plugins; disabling SwiftPM's package sandbox keeps
# the release build usable when the managed user/module caches are read-only.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox

APP="$ROOT/dist/Meterlark.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="$ROOT/dist/Meterlark-${VERSION}-arm64.zip"
# Recreate the generated bundle so removed plugins cannot survive a rebuild.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
EXECUTABLE="$BIN_DIR/Meterlark"
if [[ ! -x "$EXECUTABLE" ]]; then
	print -u2 "Release executable not found"
	exit 1
fi

cp "$EXECUTABLE" "$APP/Contents/MacOS/Meterlark"
# Remove debug symbol paths from the distributed copy before signing it.
strip -S "$APP/Contents/MacOS/Meterlark"
if LC_ALL=C grep -a -F -q -- "$ROOT" "$APP/Contents/MacOS/Meterlark"; then
    print -u2 "Release executable contains the local checkout path"
    exit 1
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ ! -x "$ROOT/Resources/ccusage" ]]; then
	print -u2 "Bundled ccusage binary is missing at Resources/ccusage"
	exit 1
fi
DECLARED_CCUSAGE_HASH="$(/usr/libexec/PlistBuddy -c 'Print :CCUsageSHA256' "$ROOT/Resources/Info.plist")"
ACTUAL_CCUSAGE_HASH="$(shasum -a 256 "$ROOT/Resources/ccusage" | awk '{print $1}')"
if [[ "$DECLARED_CCUSAGE_HASH" != "$ACTUAL_CCUSAGE_HASH" ]]; then
	print -u2 "Bundled ccusage hash does not match Resources/Info.plist"
	print -u2 "Declared: $DECLARED_CCUSAGE_HASH"
	print -u2 "Actual:   $ACTUAL_CCUSAGE_HASH"
	exit 1
fi
cp "$ROOT/Resources/ccusage" "$APP/Contents/Resources/ccusage"
chmod 755 "$APP/Contents/Resources/ccusage"
cp "$ROOT/Resources/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp "$ROOT/Resources/Meterlark-mark.png" "$APP/Contents/Resources/Meterlark-mark.png"
codesign --force --deep --sign - "$APP" >/dev/null

for executable in \
	"$APP/Contents/MacOS/Meterlark" \
	"$APP/Contents/Resources/ccusage"; do
	if [[ "$(file -b "$executable")" != *arm64* ]]; then
		print -u2 "Release bundle contains a non-arm64 executable: $executable"
		exit 1
	fi
done
codesign --verify --deep --strict "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
unzip -t "$ARCHIVE" >/dev/null
if unzip -Z1 "$ARCHIVE" | grep -q '\._'; then
	print -u2 "Release archive contains AppleDouble metadata"
	exit 1
fi

print "Packaged: $APP"
print "Archive: $ARCHIVE"
print "Archive SHA-256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
