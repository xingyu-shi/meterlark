#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Meterlark.app"
DEST="$HOME/Applications/Meterlark.app"

# Always package before installing. The app bundle is a build artifact and
# reusing an existing dist/ bundle can silently install stale source changes.
"$ROOT/scripts/package-app.sh"

mkdir -p "$HOME/Applications"
ditto "$APP" "$DEST"
open "$DEST"
print "Installed: $DEST"
