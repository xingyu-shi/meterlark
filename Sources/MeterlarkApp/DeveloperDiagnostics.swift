import Foundation

enum DeveloperWatcherState: String, Equatable, Sendable {
    case unknown
    case running
    case degraded
    case down
}

struct DeveloperDiagnosticsSnapshot: Equatable, Sendable {
    let capturedAt: Date

    let watcherState: DeveloperWatcherState
    let watcherStartAttempts: Int
    let watcherEventCount: Int
    let watcherStartedAt: Date?
    let watcherLastEventAt: Date?
    let watcherRetryAt: Date?
    let watcherMessage: String?
    let watchedRootCount: Int

    let sourceVerificationMode: String
    let fingerprintCheckInterval: TimeInterval
    let lastFingerprintCheckAt: Date?
    let nextFingerprintCheckAt: Date?
    let lastFingerprintDetectionAt: Date?
    let lastSourceChangeCause: String?
    let fingerprintCheckOutcome: String?
    let fingerprintCheckPending: Bool

    let fallbackScanCount: Int
    let lastFallbackScanAt: Date?
    let lastFallbackScanDuration: TimeInterval?
    let fallbackFailureCount: Int
    let fallbackScanInFlight: Bool

    let healthProbeCount: Int
    let lastHealthProbeAt: Date?
    let lastHealthProbeDuration: TimeInterval?
    let healthProbeMessage: String?
    let healthProbeInFlight: Bool

    let isDirty: Bool
    let dirtyGeneration: Int
    let phase: String
    let lastSourceEventAt: Date?
    let scheduledCheckAt: Date?
    let watchdogInterval: TimeInterval
    let sourceSettleInterval: TimeInterval
    let refreshInterval: TimeInterval

    let lastRefreshIntent: String?
    let lastRefreshStartedAt: Date?
    let lastRefreshCompletedAt: Date?
    let lastRefreshDuration: TimeInterval?
    let lastRefreshError: String?
    let refreshCountLast12Hours: Int
    let refreshFailureCountLast12Hours: Int
    let monthlyBudgetRefreshCountLast12Hours: Int
    let monthlyBudgetRefreshFailureCountLast12Hours: Int
    let monthlyBudgetLastRefreshAt: Date?
    let monthlyBudgetLastRefreshSucceeded: Bool?
    let monthlyBudgetLastRefreshError: String?
    let monthlyBudgetRefreshInFlight: Bool
    let monthlyBudgetRefreshDueAt: Date?
    let monthlyBudgetRefreshRequested: Bool
    let monthlyBudgetSnapshotGeneratedAt: Date?
    let monthlyBudgetProjectionAvailable: Bool
    let monthlyBudgetProjectionDay: String?
    let monthlyBudgetProjectedCost: Double?
    let monthlyBudgetResolution: String?
    let pricingUpdatedAt: Date?
    let pricingAttemptAt: Date?

    let appVersion: String
    let appBuild: String
    let bundledCCUsageVersion: String

    static let empty = DeveloperDiagnosticsSnapshot(
        capturedAt: .distantPast,
        watcherState: .unknown,
        watcherStartAttempts: 0,
        watcherEventCount: 0,
        watcherStartedAt: nil,
        watcherLastEventAt: nil,
        watcherRetryAt: nil,
        watcherMessage: nil,
        watchedRootCount: 0,
        sourceVerificationMode: SourceVerificationMode.eventDriven.rawValue,
        fingerprintCheckInterval: MonitorSettings.defaultFingerprintCheckInterval,
        lastFingerprintCheckAt: nil,
        nextFingerprintCheckAt: nil,
        lastFingerprintDetectionAt: nil,
        lastSourceChangeCause: nil,
        fingerprintCheckOutcome: nil,
        fingerprintCheckPending: false,
        fallbackScanCount: 0,
        lastFallbackScanAt: nil,
        lastFallbackScanDuration: nil,
        fallbackFailureCount: 0,
        fallbackScanInFlight: false,
        healthProbeCount: 0,
        lastHealthProbeAt: nil,
        lastHealthProbeDuration: nil,
        healthProbeMessage: nil,
        healthProbeInFlight: false,
        isDirty: false,
        dirtyGeneration: 0,
        phase: "idle",
        lastSourceEventAt: nil,
        scheduledCheckAt: nil,
        watchdogInterval: 30,
        sourceSettleInterval: 2,
        refreshInterval: 60,
        lastRefreshIntent: nil,
        lastRefreshStartedAt: nil,
        lastRefreshCompletedAt: nil,
        lastRefreshDuration: nil,
        lastRefreshError: nil,
        refreshCountLast12Hours: 0,
        refreshFailureCountLast12Hours: 0,
        monthlyBudgetRefreshCountLast12Hours: 0,
        monthlyBudgetRefreshFailureCountLast12Hours: 0,
        monthlyBudgetLastRefreshAt: nil,
        monthlyBudgetLastRefreshSucceeded: nil,
        monthlyBudgetLastRefreshError: nil,
        monthlyBudgetRefreshInFlight: false,
        monthlyBudgetRefreshDueAt: nil,
        monthlyBudgetRefreshRequested: false,
        monthlyBudgetSnapshotGeneratedAt: nil,
        monthlyBudgetProjectionAvailable: false,
        monthlyBudgetProjectionDay: nil,
        monthlyBudgetProjectedCost: nil,
        monthlyBudgetResolution: nil,
        pricingUpdatedAt: nil,
        pricingAttemptAt: nil,
        appVersion: "Development",
        appBuild: "Development",
        bundledCCUsageVersion: "unknown"
    )
}
