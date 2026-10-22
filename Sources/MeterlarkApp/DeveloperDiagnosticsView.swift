import AppKit
import SwiftUI

struct DeveloperDiagnosticsView: View {
    @ObservedObject var store: MonitorStore

    @State private var didCopy = false

    private var copy: L10n { L10n(language: store.settings.language) }
    private var diagnostics: DeveloperDiagnosticsSnapshot { store.developerDiagnostics }

    var body: some View {
        AppWindowShell(
            title: copy.developerDiagnosticsTitle,
            subtitle: copy.developerDiagnosticsSubtitle,
            mark: .symbol("waveform.path.ecg"),
            interfaceTextSize: store.settings.interfaceTextSize,
            appearance: store.settings.appearance,
            surfaceStyle: store.settings.surfaceStyle,
            width: 720,
            height: 780
        ) {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        watcherCard
                        healthAndFallbackCard
                        refreshCard
                        monthlyAndPricingCard
                        schedulerCard
                        runtimeCard
                    }
                    .padding(22)
                }

                Divider()
                footer
            }
        }
    }

    private var watcherCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsWatcher, systemImage: "eye")
                KeyValueRow(copy.developerDiagnosticsState, watcherStateLabel, tint: watcherStateColor)
                KeyValueRow(copy.developerDiagnosticsMessage, diagnostics.watcherMessage ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsRoots, String(diagnostics.watchedRootCount))
                KeyValueRow(copy.developerDiagnosticsStartAttempts, String(diagnostics.watcherStartAttempts))
                KeyValueRow(copy.developerDiagnosticsEvents, String(diagnostics.watcherEventCount))
                KeyValueRow(copy.developerDiagnosticsStartedAt, date(diagnostics.watcherStartedAt))
                KeyValueRow(copy.developerDiagnosticsLastEvent, date(diagnostics.watcherLastEventAt))
                KeyValueRow(copy.developerDiagnosticsRetryAt, date(diagnostics.watcherRetryAt))
            }
        }
    }

    private var healthAndFallbackCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsHealthFallback, systemImage: "stethoscope")
                KeyValueRow(copy.developerDiagnosticsHealthProbes, String(diagnostics.healthProbeCount))
                KeyValueRow(copy.developerDiagnosticsLastProbe, date(diagnostics.lastHealthProbeAt))
                KeyValueRow(copy.developerDiagnosticsProbeDuration, duration(diagnostics.lastHealthProbeDuration))
                KeyValueRow(copy.developerDiagnosticsProbeStatus, diagnostics.healthProbeMessage ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsFallbackScans, String(diagnostics.fallbackScanCount))
                KeyValueRow(copy.developerDiagnosticsLastFallback, date(diagnostics.lastFallbackScanAt))
                KeyValueRow(copy.developerDiagnosticsScanDuration, duration(diagnostics.lastFallbackScanDuration))
                KeyValueRow(copy.developerDiagnosticsConsecutiveFailures, String(diagnostics.fallbackFailureCount), tint: diagnostics.fallbackFailureCount > 0 ? AppWindowTheme.alert : nil)
            }
        }
    }

    private var refreshCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsRefreshPipeline, systemImage: "arrow.clockwise")
                KeyValueRow(copy.developerDiagnosticsPhase, diagnostics.phase)
                KeyValueRow(copy.developerDiagnosticsDirty, yesNo(diagnostics.isDirty), tint: diagnostics.isDirty ? AppWindowTheme.alert : nil)
                KeyValueRow(copy.developerDiagnosticsGeneration, String(diagnostics.dirtyGeneration))
                KeyValueRow(copy.developerDiagnosticsLastRefresh, diagnostics.lastRefreshIntent ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsRefreshStarted, date(diagnostics.lastRefreshStartedAt))
                KeyValueRow(copy.developerDiagnosticsRefreshCompleted, date(diagnostics.lastRefreshCompletedAt))
                KeyValueRow(copy.developerDiagnosticsRefreshDuration, duration(diagnostics.lastRefreshDuration))
                KeyValueRow(copy.developerDiagnosticsRefreshError, diagnostics.lastRefreshError ?? copy.developerDiagnosticsNotAvailable, tint: diagnostics.lastRefreshError == nil ? nil : AppWindowTheme.alert)
                KeyValueRow(copy.developerDiagnosticsRefreshes12Hours, String(diagnostics.refreshCountLast12Hours))
                KeyValueRow(copy.developerDiagnosticsFailures12Hours, String(diagnostics.refreshFailureCountLast12Hours), tint: diagnostics.refreshFailureCountLast12Hours > 0 ? AppWindowTheme.alert : nil)
            }
        }
    }

    private var monthlyAndPricingCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsMonthlyPricing, systemImage: "calendar.badge.clock")
                KeyValueRow(copy.developerDiagnosticsMonthlyRefreshes12Hours, String(diagnostics.monthlyBudgetRefreshCountLast12Hours))
                KeyValueRow(copy.developerDiagnosticsMonthlyFailures12Hours, String(diagnostics.monthlyBudgetRefreshFailureCountLast12Hours), tint: diagnostics.monthlyBudgetRefreshFailureCountLast12Hours > 0 ? AppWindowTheme.alert : nil)
                KeyValueRow(copy.developerDiagnosticsMonthlyLastRefresh, date(diagnostics.monthlyBudgetLastRefreshAt))
                KeyValueRow(copy.developerDiagnosticsMonthlyResult, monthlyResult, tint: monthlyResultColor)
                KeyValueRow(copy.developerDiagnosticsMonthlyError, diagnostics.monthlyBudgetLastRefreshError ?? copy.developerDiagnosticsNotAvailable, tint: diagnostics.monthlyBudgetLastRefreshError == nil ? nil : AppWindowTheme.alert)
                KeyValueRow(copy.developerDiagnosticsMonthlySnapshot, date(diagnostics.monthlyBudgetSnapshotGeneratedAt))
                KeyValueRow(copy.developerDiagnosticsMonthlyInFlight, yesNo(diagnostics.monthlyBudgetRefreshInFlight))
                KeyValueRow(copy.developerDiagnosticsMonthlyDue, date(diagnostics.monthlyBudgetRefreshDueAt))
                KeyValueRow(copy.developerDiagnosticsMonthlyRequested, yesNo(diagnostics.monthlyBudgetRefreshRequested))
                KeyValueRow(copy.developerDiagnosticsMonthlyProjection, yesNo(diagnostics.monthlyBudgetProjectionAvailable))
                KeyValueRow(copy.developerDiagnosticsMonthlyProjectionDay, diagnostics.monthlyBudgetProjectionDay ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsMonthlyProjectedCost, cost(diagnostics.monthlyBudgetProjectedCost))
                KeyValueRow(copy.developerDiagnosticsMonthlyResolution, diagnostics.monthlyBudgetResolution ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsPricingUpdated, date(diagnostics.pricingUpdatedAt))
                KeyValueRow(copy.developerDiagnosticsPricingAttempt, date(diagnostics.pricingAttemptAt))
            }
        }
    }

    private var schedulerCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsScheduler, systemImage: "clock.arrow.2.circlepath")
                KeyValueRow(copy.developerDiagnosticsLastSourceEvent, date(diagnostics.lastSourceEventAt))
                KeyValueRow(copy.developerDiagnosticsScheduledCheck, date(diagnostics.scheduledCheckAt))
                KeyValueRow(copy.developerDiagnosticsVerificationMode, diagnostics.sourceVerificationMode)
                KeyValueRow(copy.developerDiagnosticsFingerprintInterval, seconds(diagnostics.fingerprintCheckInterval))
                KeyValueRow(copy.developerDiagnosticsLastFingerprintCheck, date(diagnostics.lastFingerprintCheckAt))
                KeyValueRow(copy.developerDiagnosticsNextFingerprintCheck, date(diagnostics.nextFingerprintCheckAt))
                KeyValueRow(copy.developerDiagnosticsLastFingerprintDetection, date(diagnostics.lastFingerprintDetectionAt))
                KeyValueRow(copy.developerDiagnosticsSourceChangeCause, diagnostics.lastSourceChangeCause ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsFingerprintOutcome, diagnostics.fingerprintCheckOutcome ?? copy.developerDiagnosticsNotAvailable)
                KeyValueRow(copy.developerDiagnosticsFingerprintPending, yesNo(diagnostics.fingerprintCheckPending))
                KeyValueRow(copy.developerDiagnosticsRefreshInterval, seconds(diagnostics.refreshInterval))
                KeyValueRow(copy.developerDiagnosticsWatchdogInterval, seconds(diagnostics.watchdogInterval))
                KeyValueRow(copy.developerDiagnosticsSettleInterval, seconds(diagnostics.sourceSettleInterval))
            }
        }
    }

    private var runtimeCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle(copy.developerDiagnosticsRuntime, systemImage: "info.circle")
                KeyValueRow(copy.developerDiagnosticsCapturedAt, date(diagnostics.capturedAt))
                KeyValueRow(copy.developerDiagnosticsVersion, diagnostics.appVersion)
                KeyValueRow(copy.developerDiagnosticsBuild, diagnostics.appBuild)
                KeyValueRow(copy.developerDiagnosticsCCUsage, diagnostics.bundledCCUsageVersion)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.runDeveloperHealthCheck()
            } label: {
                Label(copy.developerDiagnosticsRunHealthCheck, systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .disabled(diagnostics.healthProbeInFlight)

            Button {
                store.copyDeveloperDiagnostics()
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    didCopy = false
                }
            } label: {
                Label(didCopy ? copy.developerDiagnosticsCopied : copy.developerDiagnosticsCopy, systemImage: didCopy ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private func cardTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .appFont(.bodyEmphasis)
            .foregroundStyle(AppWindowTheme.primary)
            .padding(.bottom, 2)
    }

    private var watcherStateLabel: String {
        switch diagnostics.watcherState {
        case .unknown: return copy.developerDiagnosticsUnknown
        case .running: return copy.developerDiagnosticsRunning
        case .degraded: return copy.developerDiagnosticsDegraded
        case .down: return copy.developerDiagnosticsDown
        }
    }

    private var watcherStateColor: Color {
        switch diagnostics.watcherState {
        case .unknown: return AppWindowTheme.secondary
        case .running: return AppWindowTheme.signal
        case .degraded: return Color(nsColor: .systemOrange)
        case .down: return AppWindowTheme.alert
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? copy.developerDiagnosticsYes : copy.developerDiagnosticsNo
    }

    private var monthlyResult: String {
        guard let succeeded = diagnostics.monthlyBudgetLastRefreshSucceeded else {
            return copy.developerDiagnosticsNotAvailable
        }
        return succeeded ? copy.developerDiagnosticsYes : copy.developerDiagnosticsNo
    }

    private var monthlyResultColor: Color? {
        guard let succeeded = diagnostics.monthlyBudgetLastRefreshSucceeded else { return nil }
        return succeeded ? AppWindowTheme.signal : AppWindowTheme.alert
    }

    private func date(_ value: Date?) -> String {
        guard let value else { return copy.developerDiagnosticsNotAvailable }
        return ISO8601DateFormatter().string(from: value)
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return copy.developerDiagnosticsNotAvailable }
        return String(format: "%.3f s", value)
    }

    private func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    private func cost(_ value: Double?) -> String {
        guard let value else { return copy.developerDiagnosticsNotAvailable }
        return Currency.format(value)
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String
    let tint: Color?

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .appFont(.caption)
                .foregroundStyle(AppWindowTheme.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .appFont(.body)
                .foregroundStyle(tint ?? AppWindowTheme.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
