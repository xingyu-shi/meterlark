#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Meterlark.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/dist/Meterlark-${VERSION}-arm64.dmg"

if [[ ! -d "$APP" ]]; then
    print -u2 "Build dist/Meterlark.app with scripts/package-app.sh first"
    exit 1
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" || "$APP_BUILD" != "$EXPECTED_BUILD" ]]; then
    print -u2 "App bundle is stale; rebuild with scripts/package-app.sh first"
    exit 1
fi
codesign --verify --deep --strict "$APP"

# Keep installer tooling outside the app bundle and system Python.
VENV="$ROOT/.build/dmg-venv"
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r "$ROOT/scripts/requirements-dmg.txt"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D "app=$APP" Meterlark "$DMG"

# Verify the copied app, not only the input: Finder customization must not
# alter signed bundle metadata, and the drop target must resolve correctly.
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/meterlark-dmg-check.XXXXXX")"
cleanup() {
    hdiutil detach "$VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
    rmdir "$VERIFY_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" -quiet
codesign --verify --deep --strict "$VERIFY_MOUNT/Meterlark.app"
if [[ ! -L "$VERIFY_MOUNT/Applications" || "$(readlink "$VERIFY_MOUNT/Applications")" != /Applications ]]; then
    print -u2 "DMG is missing its Applications drop target"
    exit 1
fi
hdiutil detach "$VERIFY_MOUNT" -quiet
rmdir "$VERIFY_MOUNT"
trap - EXIT

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS=(--force --timestamp --sign "$SIGN_IDENTITY")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
        SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
    fi
    codesign "${SIGN_ARGS[@]}" "$DMG"
    codesign --verify --strict "$DMG"
fi
if [[ -n "${APPLE_API_KEY_PATH:-}" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        print -u2 "Notarization requires SIGN_IDENTITY to be a Developer ID identity"
        exit 1
    fi
    "$ROOT/scripts/notarize.sh" "$DMG" "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
hdiutil verify "$DMG"
print "Installer: $DMG"
print "Installer SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
