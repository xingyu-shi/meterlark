# Changelog

Versions are listed newest first. Public GitHub binary releases for this repository
begin with **1.2.9**. Entries through **1.1.1** preserve the predecessor application's
original version dates and recorded changes; they do not indicate downloadable
releases in this repository. Historical provider integrations are summarized
without organization-specific names or deployment details, and may no longer be
included in Meterlark.

## 1.2.12 · 2026-10-23

### Added

- Add a standard DMG installer that opens with Meterlark and an Applications shortcut, connected by a drag-to-install arrow.
- Publish a signed, notarized, and stapled DMG alongside the ZIP download, with a SHA-256 checksum for each.

### Fixed

- Resize the menu-bar hosting window when the dashboard becomes shorter, keeping its top edge under the menu bar.
- Keep summary tile text on one line and tiles in the same row at equal heights.

### Changed

- Check the app signature and Applications shortcut inside the mounted DMG before signing and publishing the installer.

## 1.2.11 · 2026-10-23

### Fixed

- Restore the expected menu-bar panel appearance in signed downloads by building with macOS SDK 27 instead of SDK 15.5.

### Changed

- Use the Xcode 27 runner for CI and release builds, and reject packaging with a macOS SDK older than 27 before compiling.
- Preserve Developer ID signing, Apple notarization, and stapling in the release workflow. The app's runtime minimum remains macOS 14.

## 1.2.10 · 2026-10-23

### Improved

- Sign release downloads with a Developer ID certificate and notarize them with Apple, so the app opens without a Gatekeeper warning.
- Label the About window's ccusage checksum as the upstream value before signing.

### Verification

- A local Developer ID build passed notarization, stapling, and a Gatekeeper assessment of a quarantined copy.

## 1.2.9 · 2026-10-23

### Fixed

- Keep plugin configuration forms isolated when switching plugins or reopening the editor.
- Publish completed usage scans during continuous source activity while scheduling later changes for the next refresh.
- Reject out-of-range integer progress values without crashing the app.
- Cancel plugin pipe reads and writes on timeout, including when a descendant holds the output pipe open.
- Apply OAuth grant defaults when JSON fields are omitted, while preserving explicit null values.
- Watch Codex sessions in a custom `CODEX_HOME` directory.

### Verification

- The full Release-mode Swift suite passed: 465 tests, zero failures.
- CI passed source-content, credential, Release-mode test, and packaging checks.

## 1.2.8 · 2026-10-23

### Improved

- Keep a single Launch at login toggle and reflect the system's current setting.
- Open Login Items automatically only when an operation fails or needs approval, with a draggable app icon or approval instructions when enabling needs manual setup.

## 1.2.7 · 2026-10-22

### Improved

- Drag anywhere on a Dashboard preview component to reorder it live, with animated movement and a placeholder before releasing the pointer.
- Keep move and remove controls available alongside drag reordering.

## 1.2.6 · 2026-10-22

### Added

- Edit Dashboard components directly in the preview with drag-to-reorder, move, and remove controls.
- Share one draft between the preview and settings; save applies the draft to the main Dashboard.

## 1.2.5 · 2026-10-22

### Improved

- Register launch at login on the first request and reflect the system's current setting.
- When setup needs user action, automatically open Login Items with a floating guide containing a draggable app icon or approval instructions.

## 1.2.4 · 2026-10-22

### Fixed

- Fit the default Dashboard height to its rendered content and limit it to the current screen's available height.
- Accept valid menu-bar formats in optimized builds instead of incorrectly reporting control characters.

### Changed

- Run CI tests in Release mode to cover optimized-build behavior.

## 1.2.3 · 2026-10-22

### Improved

- Show pricing status as a compact colored icon, keeping details in its popover and the last-refresh time on one line.

## 1.2.2 · 2026-10-22

### Fixed

- Restore the expected Solid color appearance in the menu-bar panel by correcting the linked macOS SDK stamp in release packages.

### Changed

- Build packages with the native SwiftPM engine and verify the linked SDK version to catch this packaging regression.

## 1.2.1 · 2026-10-22

### Changed

- Draw solid surfaces with an opaque background that opts out of vibrancy, and apply appearance settings to the plugin paste window. The remaining menu-bar panel appearance regression was resolved in 1.2.2.

## 1.2.0 · 2026-10-22

### Added

- Install HTTP plugins by pasting their complete JSON manifest in Settings → Plugins, with an editable preview and clipboard paste button.

### Changed

- Adopt the Meterlark name and independent bundle, settings, data-directory, and Keychain identities.
- Keep the plugin host independent of any organization-specific service, with reserved-domain gateway and model-catalog examples for plugin authors.
- Recreate the generated app bundle on every build and installation so removed resources cannot survive an update.
- Start the distributable Git history from a sanitized source baseline, with automated public-content and credential checks.

### Removed

- Remove organization-specific plugins, operational scripts, reference pricing snapshots, and unpublished design drafts from the distributed source.
- Remove rename-era data and credential migration code.

## 1.1.1 · 2026-10-15

### Improved

- Update the bundled Apple Silicon `ccusage` binary to 20.0.32, use its documented unified JSON command flags, and match its 272K long-context thresholds for GPT-6 models.
- Use ccusage's verified explicit-zero pricing support for custom schedules and bump the pricing-engine revision so existing snapshots are recalculated after the upgrade.
- Align the app's minimum macOS version with the bundled native `ccusage` binary's macOS 14 deployment target.

### Verification

- Full Swift test suite: 434 tests executed, 1 local-data test skipped under `GITHUB_ACTIONS`, 0 failures; includes `SourceChangeWatcherTests`.
- The release packaging script signed the app and verified the archive contents.

## 1.1.0 · 2026-08-28

### Added

- Add a separate HTTP/JSON model-catalog integration supplying source-aware metadata, availability, routes, context limits, capabilities, and price schedules.
- Add a host-owned model-catalog dashboard component, source-aware model search, and structured catalog-change notifications with read and dismiss controls.

### Fixed

- Treat an explicit finite `0` in an imported price table as known-free `$0`; omitted, `null`, invalid, and unpriced values remain `Unknown`, and null pricing-tier placeholders are ignored.
- Keep unknown-priced usage explicit in the total, budget rows, menu bar, and pricing details. Unknown tokens are excluded from known-cost totals and budgets, which are labelled as potentially understated even when a budget threshold alert is also active.
- Prefer `Unknown` over `Approximate` or stale status when a model has no usable price, while retaining the **Update pricing** action when the active catalog is stale.
- Prevent incomplete pricing responses from silently replacing a valid estimate with a near-zero amount.
- Refresh provider credentials after HTTP 400 responses within the bounded retry flow.

### Improved

- Resolve pricing from mixed sources with the precedence custom pricing → enabled remote model catalog → existing ccusage/default pricing, while preserving source and threshold provenance.
- Separate the low-frequency model-catalog refresh deadline from the usage watchdog. The watchdog no longer performs full catalog de-duplication, sorting, diffing, or JSON fingerprint work every 30 seconds; the expensive batch is prepared on a utility worker and reused by pricing.
- Reuse a trusted catalog at launch, respect the automatic-refresh switch, throttle same-revision retries, fetch newly discovered providers promptly, and preserve manual refresh as an immediate action.
- Bound provider fetch coordination, discard late results after cancellation or provider replacement, and fence catalog persistence by generation so stale data cannot replace a newer provider configuration.
- Preserve catalog search, selection, and valid provider/modality filters across refreshes; clear filters that disappear from the new catalog.
- Localize aggregated catalog-change summaries and keep notification counts structured instead of parsing English text.

### Verification

- Full Swift test suite excluding the known FSEvents-only `SourceChangeWatcherTests`: 432 tests passed.
- Release bundle is signed and its archive is checked for integrity.

## 1.0.0 · 2026-08-24

### Added

- Bundle an initial HTTP/JSON gateway integration that can be configured directly from Settings → Plugins.
- Discover bundled plugin packages alongside user-installed third-party plugins, with a valid user package taking precedence for the same plugin ID.

### Improved

- Keep the bundled integration disabled until its endpoint and refresh credentials are configured and the user explicitly enables it.
- Preserve the existing install flow for third-party `http-json` and `stdio-json` plugins.

## 0.1.21 · 2026-08-24

### Added

- Add an optional periodic source-change verification mode that keeps the watcher active and checks source metadata on a configurable cadence, launching `ccusage` only after a change is detected.
- Add 1, 5, 15, 30, and 60 minute fingerprint-check presets plus a validated custom 1–60 minute interval.
- Extend Developer Diagnostics with verification mode, fingerprint timing and outcome, pending state, and source-change cause.

### Improved

- Keep event-driven verification as the default while retaining watcher-down fingerprint fallback.
- Reorganize the settings menu so usage scope is separate from refresh configuration, and show periodic-check controls only when that mode is enabled.

## 0.1.20 · 2026-08-24

### Added

- Add host-owned token refresh for HTTP/JSON plugins, covering OAuth-style form exchanges and bounded provider-specific JSON flows.
- Store refresh credentials in Keychain, support refresh-token rotation, expiry skew, unauthorized retry, concurrent refresh sharing, and safe session invalidation.
- Document the versioned token-refresh contract and add redacted OAuth and provider-specific coverage for refresh, failure, and lifecycle behavior.

### Fixed

- Support provider-specific access/refresh token fields and responses without expiry metadata.

## 0.1.19 · 2026-08-24

### Added

- Add a host-owned declarative plugin system with installable `http-json` and `stdio-json` transports, per-plugin configuration, activation, secret handling, and external plugin development documentation.
- Add configurable Dashboard composition for built-in components and active plugin blocks, including visibility, ordering, metric-grid columns, preview updates, and content-aware height controls.
- Add an initial HTTP plugin package and localized dashboard data support.

### Improved

- Reuse the existing host-owned metric and progress components for validated plugin data instead of loading plugin UI code.
- Bound plugin manifest and dashboard content, preserve safe stale diagnostics, and migrate legacy layout identifiers without allowing component-ID collisions.
- Keep invalid but previously enabled plugins switchable off while preventing invalid packages from being enabled.

## 0.1.18 · 2026-08-21

### Improved

- Use a current-calendar-month usage query as the canonical monthly budget and summary total, and project the latest current-day usage onto shorter lookback ranges from a validated whole-month baseline.
- Let whole-month reconciliation proceed after a bounded wait during continuous source activity while preserving trusted values when a result is stale, incomplete, or empty.
- Align chart totals and menu-bar presentation with canonical usage snapshot totals instead of re-summing presentation groups.
- Extend Developer Diagnostics with monthly projection and resolution details, and handle ccusage responses with missing daily or model-breakdown sections more safely.

### Fixed

- Avoid treating missing current-day evidence as zero usage, and prevent stale in-flight usage or monthly results from replacing a newer source generation.

## 0.1.17 · 2026-08-20

### Added

- Add an optional Developer Diagnostics window for watcher, refresh, fallback, pricing, and monthly-budget health details.
- Mark last-known-good monthly budget values when a newer usage or pricing snapshot is waiting for the independent reconciliation pass.

### Improved

- Coalesce source-event callbacks, wait for a two-second quiet period, and enforce the configured usage refresh interval without launching duplicate scans.
- Reconcile whole-month budget data independently at a lower cadence so frequent usage refreshes do not launch an expensive monthly process every time.
- Recover the source watcher after dropped or wrapped FSEvent IDs and use the bounded fingerprint fallback while it is being rebuilt.

### Fixed

- Keep stale in-flight usage and monthly results from replacing a newer source generation; preserve the previous trusted snapshot until a current result is available.

## 0.1.16 · 2026-08-19

### Added

- Make the budget alert threshold configurable from 1% to 100%, defaulting to 80%.

### Improved

- Consolidate daily/monthly budgets and the alert threshold into one configuration window with a live normal/alert preview.
- Unify the About, Model Catalog, and Budget Alerts windows with a shared title, card, color, and control language.
- Add a global Solid color / Frosted glass surface-style option backed by the native macOS visual-effect material.

## 0.1.15 · 2026-08-19

### Added

- Add adjustable interface text sizes at 100%, 110%, 120%, and 130% for users who need larger readable content.
- Apply shared typography and layout-safe scaling across the monitor popover, About window, and model catalog.

### Improved

- Keep larger text presets visually restrained by increasing the surrounding layout only where needed.
- Add extra vertical room for the larger and largest presets when daily or monthly budget sections are enabled.

## 0.1.14 · 2026-08-18

### Added

- Add optional daily and natural-month budget alerts with an 80% threshold, red/bold primary amount and menu bar presentation, and unknown-pricing preservation.
- Persist the monthly budget snapshot separately from the daily usage snapshot so the existing usage schema and query scope remain stable.
- Adapt Compact popover height to 890 points for one budget and 900 points for both budgets, while leaving custom heights unchanged.

## 0.1.13 · 2026-08-18

### Changed

- Set the default menu bar format to `[logo]$[cost]` and migrate the previous `[logo]` default without changing custom formats.

## 0.1.12 · 2026-08-18

### Improved

- Update the bundled Apple Silicon `ccusage` binary to 20.0.20, including its improved model-specific long-context pricing behavior.
- Route active LiteLLM-style custom pricing through an isolated ccusage compatibility adapter, including safe 272K long-context translation for models whose bundled ccusage profile explicitly supports that threshold; ccusage remains the single cost engine.
- Invalidate cached costs once when the pricing engine changes, so an upgrade cannot keep presenting an old zero or differently calculated snapshot until the next 24-hour interval.
- Recalculate cost during every usage refresh with the active offline pricing config, without conflating that calculation with refreshing the remote price table.
- Align fallback fingerprint checks with the configured usage refresh interval and retry failed watcher/fingerprint paths with bounded backoff.
- Run the 24-hour automatic pricing check independently of usage-file activity; manual pricing refresh remains available when automatic pricing is disabled.
- Track `ccusage`, custom, mixed, and unknown pricing provenance in the local snapshot.
- Show app/build and bundled `ccusage` metadata in Settings, including the bundled binary SHA-256.
- Persist the exact usage query scope and custom-pricing revision so a cached report cannot be presented under a different range or price table.
- Re-read custom pricing before a pricing refresh and record model-discovery and candidate-integrity details in the local refresh log.
- Move app metadata into a native About window with the same compact, left-aligned visual language as the settings UI.
- Tighten the default Compact popover height to 780pt and migrate the previous 790pt value back to the new default.
- Preserve imported model metadata and expose a searchable model catalog from Settings → Pricing only while a custom price list is active.
- Keep active custom pricing authoritative when persisting legacy `pricingOverrides`, and prevent replaced or removed custom rates from surviving an offline pricing fallback.
- Emphasize model-detail metadata with semantic provider and modality colors/icons while keeping mode labels neutral.
- Add composable model-catalog filters for provider, modality, capability, input price, and maximum context length.
- Show per-model input, output, cache read, and cache write usage with expandable exact counts.
- Show base and long-context unit rates per model, including the selected tier and the backend threshold actually used.
- Preserve model-level pricing provenance and distinguish exact custom, approximate custom, ccusage fallback, and unknown pricing.
- Map ordinary non-200K tiers to ccusage’s single approximate alternate tier and select a deterministic tier from multi-tier schedules.

### Fixed

- Reject future, invalid, duplicate, negative, and numerically unsafe snapshots instead of allowing corrupted state to reach the UI.
- Quarantine unreadable snapshots and preserve the previous trusted snapshot on failed writes.
- Prevent stale asynchronous refreshes from overwriting newer pricing or lookback requests.
- Bound runner timeout and pipe-drain cleanup so descendant processes cannot hold a refresh indefinitely.
- Make Today an inclusive single-calendar-day query, including an explicit `--until` bound, and keep partial/unknown pricing from silently replacing a trusted estimate.
- Allow valid large pricing changes and model renames while rejecting incomplete automatic reports and partial model pricing.
- Keep usable ccusage fallback results when custom tier schedules are approximate or a model has no matching price.
- Keep custom pricing and generated compatibility config aligned for date-pinned model names.

## 0.1.11 · 2026-08-14

### Improved

- Keep token and cost totals visible in the chart summary.
- Refine the usage monitor hierarchy with clearer period, status, pricing, and refresh labels.
- Show the current period summary before a chart date is selected, with clearer pinned-date behavior.
- Migrate the compact popover to a slightly taller layout and improve long legend-label handling.

### Fixed

- Align odd legend items consistently in the chart grid.

## 0.1.10 · 2026-08-13

### Improved

- Use only the pinned bundled `ccusage` binary from the app bundle.
- Refresh usage after source changes with the configured interval measured from refresh start.
- Add current-calendar-month lookback and live relative-time labels.
- Repackage the app before user installation so stale bundles are not reused.

### Fixed

- Remove external executable-path, PATH, and npx fallback discovery for `ccusage`.

## 0.1.9 · 2026-08-13

### Added

- Add configurable launch-at-login behavior with explicit macOS approval handling.
- Add Automatic, Light, and Dark appearance choices; Automatic follows the macOS appearance.
- Add a live preview to the menu bar format editor, including inline validation and save eligibility.
- Show Light and Dark product screenshots side by side in the README.

### Improved

- Use semantic setting icons and native Picker controls for refresh, display, language, and chart choices.
- Keep AppKit and SwiftUI appearance state synchronized so explicit Light and Dark choices affect the actual popover window.
- Document the supported harness agents exposed by the bundled `ccusage` binary.

### Fixed

- Distinguish enabled, approval-required, unavailable, and unregistered login-item states.
- Avoid unregistering a login item when macOS reports that its service is not found.

## 0.1.8-beta · 2026-08-11

### Fixed

- Keep menu bar logo, separators, currency symbols, and cost values on one native rendering surface so adjacent formats cannot split or lose their amount.
- Calibrate ordinary cost text and Money Lens text independently against the macOS status-item baseline.
- Keep Money Lens values centered inside their four-corner frame at menu-bar pixel scale.

### Improved

- Merge adjacent literal and cost text into one run to avoid artificial spacing in formats such as `$[cost:1]`.
- Reject control characters and invalid stored formats, cap pathological menu bar widths, and safely handle non-finite cost values.
- Center and rebalance the README wordmark asset for light backgrounds.

## 0.1.7-beta · 2026-08-10

### Added

- Add configurable menu bar formats with `[logo]`, Money Lens, and precision-aware `[money:*]` and `[cost:*]` tokens.
- Add inline format guidance, examples, validation, and persistence under Settings → Display.
- Add plain Money Lens variants that omit the currency symbol while keeping the amount inside the monitor frame.

### Improved

- Render menu bar marks and Money Lens values as native template images so macOS keeps each status item visually together.
- Make the monochrome Signal Lens mark distinct from the menu bar amount while keeping the full mark in the popover and app icon.

## 0.1.6-beta · 2026-08-09

### Added

- Merge custom price-list imports by default while retaining an explicit whole-list replacement option.
- Export the active custom price list as a sorted LiteLLM-compatible JSON file for sharing.
- Expand the `Other` model series in the chart while keeping colors consistent with the legend and details.

### Improved

- Ask before falling back from a failed merge save to a whole-list replacement.
- Preserve original model-name casing in exported price lists while keeping matching case-insensitive.
- Treat a zero custom rate as a signal to use ccusage's market price for that model.

## 0.1.5-beta · 2026-08-07

### Added

- Import a LiteLLM-style custom price list from Settings → Pricing.
- Show custom input, output, cache-write, and cache-read rates in model details.

### Improved

- Use custom pricing for matching models, including explicit zero prices; models absent from the custom list keep ccusage's calculated cost.
- Label ccusage-calculated costs as official API reference prices when unit rates are not exposed in its JSON output.
- Keep model price details inline so the detail panel does not jump during hover transitions.
- Organize settings around refresh, display, pricing, and current values.

## 0.1.4-beta · 2026-08-06

### Fixed

- Prevent an incomplete automatic pricing refresh from replacing a valid estimate with a near-zero amount.
- Keep the previous pricing snapshot when the new result loses known model prices or drops unexpectedly for the same date range.
- Continue refreshing a newly selected lookback range, with automatic fallback to offline pricing when online pricing is unavailable.

## 0.1.3-beta · 2026-08-06

### Improved

- Add a clear Quit action under the settings gear, with English and Chinese labels.
- Make `Tokens · by Model` the default chart view.
- Let long hover model details expand with the popover's single outer scroll instead of nesting a second scroll view.

## 0.1.2-beta · 2026-08-06

### Improved

- Include the application brand mark in the menu bar, app bundle, and README preview.
- Keep the downloadable app, source tree, and release tag aligned.

## 0.1.1-beta · 2026-08-06

### Improved

- Bundle the pinned Apple Silicon `ccusage 20.0.19` native binary inside the app, so release users do not need Node, npm, nvm, or a manual executable path.
- Preserve external ccusage discovery as a fallback for advanced users.

## 0.1.0-beta · 2026-08-06

The first personal beta of the predecessor application.

### Added

- A native macOS menu-bar monitor for local `ccusage` reports.
- API-equivalent estimated cost for today and configurable lookback windows.
- Token visibility for input, output, cache creation, and cache reads.
- A unified `Usage by day` chart with explicit `Tokens · by Agent`, `Tokens · by Model`, `Cost · by Agent`, and `Cost · by Model` views.
- Hover details for dates, agents, and every underlying model behind the chart's `Other` series.
- Support for all agent sources returned by ccusage's unified report.
- English, 中文, and System language choices.
- Atomic local snapshots, file-change coalescing, configurable refresh intervals, and manual refresh.

### Notes

- This beta targets Apple Silicon Macs running macOS 13 or newer.
- The app is ad-hoc signed and not notarized yet.
- `ccusage` remains a separate local prerequisite.
- Cost is an API-equivalent estimate, not a provider invoice or gateway bill.
