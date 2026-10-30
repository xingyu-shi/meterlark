# Sourced by zsh packaging scripts after SwiftPM resolves the binary target.
# ROOT is the repository root. Do not copy the distribution's signing tools
# into the app; only Sparkle.framework and its license are runtime resources.
SPARKLE_ARTIFACTS=("$ROOT"/.build/artifacts/*/Sparkle(N/))
if (( ${#SPARKLE_ARTIFACTS} != 1 )); then
    print -u2 "Expected one resolved Sparkle artifact; run swift package resolve first"
    exit 1
fi
SPARKLE_ROOT="${SPARKLE_ARTIFACTS[1]}"
SPARKLE_FRAMEWORK_SOURCE="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" || ! -x "$SPARKLE_ROOT/bin/generate_appcast" ]]; then
    print -u2 "Resolved Sparkle artifact is missing its framework or publishing tools"
    exit 1
fi
