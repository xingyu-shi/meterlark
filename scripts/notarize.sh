#!/bin/zsh
set -euo pipefail

# Submit an archive or disk image, then staple its distributable target.
if (( $# != 2 )); then
    print -u2 "Usage: notarize.sh <submission> <app-or-dmg-to-staple>"
    exit 1
fi
: "${APPLE_API_KEY_PATH:?Notarization requires APPLE_API_KEY_PATH}"
: "${APPLE_API_KEY:?Notarization requires APPLE_API_KEY}"
: "${APPLE_API_ISSUER:?Notarization requires APPLE_API_ISSUER}"

NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
NOTARY_RESULT="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json)" || true
NOTARY_STATUS="$(print -r -- "$NOTARY_RESULT" | plutil -extract status raw -o - - 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    print -u2 "Notarization failed: $NOTARY_RESULT"
    NOTARY_ID="$(print -r -- "$NOTARY_RESULT" | plutil -extract id raw -o - - 2>/dev/null || true)"
    if [[ -n "$NOTARY_ID" ]]; then
        xcrun notarytool log "$NOTARY_ID" "${NOTARY_ARGS[@]}" >&2 || true
    fi
    exit 1
fi
xcrun stapler staple "$2"
xcrun stapler validate "$2"
