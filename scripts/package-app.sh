#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# This package has no build plugins; disabling SwiftPM's package sandbox keeps
# the release build usable when the managed user/module caches are read-only.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# SwiftPM 6.4's default engine records the deployment target as the linked
# SDK version, changing AppKit/SwiftUI behavior (swift-package-manager#10696).
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Keep the SDK baseline of the last verified appearance. A correctly stamped
# older SDK still selects compatibility UI behavior on newer macOS versions.
if (( ${SDK_VERSION%%.*} < 27 )); then
    print -u2 "Packaging requires macOS SDK 27 or newer (Xcode 27+); selected SDK is $SDK_VERSION"
    exit 1
fi
BUILD_ARGS=(-c release --disable-sandbox --build-system native --sdk "$SDK_PATH")
swift build "${BUILD_ARGS[@]}"

APP="$ROOT/dist/Meterlark.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="$ROOT/dist/Meterlark-${VERSION}-arm64.zip"
# Recreate the generated bundle so removed plugins cannot survive a rebuild.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/Meterlark"
if [[ ! -x "$EXECUTABLE" ]]; then
	print -u2 "Release executable not found"
	exit 1
fi

LINKED_SDK_VERSION="$(xcrun vtool -show-build "$EXECUTABLE" | awk '$1 == "sdk" { print $2 }')"
if [[ "$LINKED_SDK_VERSION" != "$SDK_VERSION" ]]; then
    print -u2 "Linked SDK version mismatch: expected $SDK_VERSION, found $LINKED_SDK_VERSION"
    exit 1
fi
print "Verified linked macOS SDK: $LINKED_SDK_VERSION"

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
# Ad-hoc signing by default. A Developer ID build signs the nested ccusage
# executable first with the hardened runtime, because --deep is not suitable
# for distribution signing.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
	codesign --force --deep --sign - "$APP" >/dev/null
else
	SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
	if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
		SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
	fi
	codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/ccusage"
	codesign "${SIGN_ARGS[@]}" "$APP"
fi

for executable in \
	"$APP/Contents/MacOS/Meterlark" \
	"$APP/Contents/Resources/ccusage"; do
	if [[ "$(file -b "$executable")" != *arm64* ]]; then
		print -u2 "Release bundle contains a non-arm64 executable: $executable"
		exit 1
	fi
done
codesign --verify --deep --strict "$APP"

# Notarize only when App Store Connect API key credentials are provided.
if [[ -n "${APPLE_API_KEY_PATH:-}" ]]; then
	if [[ "$SIGN_IDENTITY" == "-" ]]; then
		print -u2 "Notarization requires SIGN_IDENTITY to be a Developer ID identity"
		exit 1
	fi
	NOTARY_UPLOAD="$ROOT/dist/Meterlark-notary-upload.zip"
	trap 'rm -f "$NOTARY_UPLOAD"' EXIT
	ditto -c -k --norsrc --keepParent "$APP" "$NOTARY_UPLOAD"
	"$ROOT/scripts/notarize.sh" "$NOTARY_UPLOAD" "$APP"
	rm -f "$NOTARY_UPLOAD"
	trap - EXIT
	spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
unzip -t "$ARCHIVE" >/dev/null
if unzip -Z1 "$ARCHIVE" | grep -q '\._'; then
	print -u2 "Release archive contains AppleDouble metadata"
	exit 1
fi

print "Packaged: $APP"
print "Archive: $ARCHIVE"
print "Archive SHA-256: $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
