# Changelog

## Unreleased

### Added

- Install HTTP plugins by pasting their complete JSON manifest in Settings → Plugins, with an editable preview and clipboard paste button.

### Changed

- Fit the default dashboard height to its rendered content and limit it to the current screen's available height.
- Fix valid menu-bar formats being rejected as control characters in optimized builds, and run CI tests in Release mode.
- Show pricing status as a compact colored icon, keeping details in its popover and the last-refresh time on one line.
- Apply appearance settings to the plugin paste window.
- Build release packages with the native SwiftPM engine and verify the linked SDK version, avoiding incorrect system UI behavior from SwiftPM 6.4's default engine.
- Establish Meterlark as an independent macOS menu-bar application for AI coding usage, cost estimates, budgets, and extensible dashboards.
- Use Meterlark bundle, settings, data-directory, and Keychain identities.
- Keep the plugin host independent of any organization-specific service. Provide optional reserved-domain gateway and model-catalog examples for plugin authors.
- Recreate the generated app bundle on every build and resolve its executable through SwiftPM's reported output directory.

### Removed

- Remove organization-specific plugins, operational scripts, reference pricing snapshots, and unpublished design drafts from the distributed source.

### Verification

- Add automated public-content and credential checks.
- Start the distributable Git history from the sanitized source baseline.
