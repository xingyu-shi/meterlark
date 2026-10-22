import AppKit
import Combine
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

enum RefreshPhase: Equatable {
    case idle
    case waiting
    case refreshing
    case updatingPricing
    case failed(String)
}

enum CustomPricingImportMode: Equatable {
    case merge
    case replace
}

private enum RefreshIntent {
    case usage
    case pricing(fallbackToOffline: Bool, allowEmptyCandidate: Bool)
    case offlinePricing(allowEmptyCandidate: Bool)

    var isPricing: Bool {
        switch self {
        case .usage: return false
        case .pricing, .offlinePricing: return true
        }
    }

    var usesOnlinePricing: Bool {
        if case .pricing = self { return true }
        return false
    }

    var fallbackToOffline: Bool {
        if case let .pricing(fallback, _) = self { return fallback }
        return false
    }

    var allowEmptyCandidate: Bool {
        switch self {
        case .usage: return false
        case let .pricing(_, allowEmpty), let .offlinePricing(allowEmpty): return allowEmpty
        }
    }

    var runnerMode: CCUsageRunMode {
        switch self {
        case .usage: return .usage
        case .pricing: return .onlinePricing
        case .offlinePricing: return .offlinePricing
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .usage:
            return "usage"
        case let .pricing(fallbackToOffline, _):
            return fallbackToOffline ? "pricing (online, fallback enabled)" : "pricing (online)"
        case .offlinePricing:
            return "pricing (offline)"
        }
    }
}

private struct CustomPricingFileFingerprint: Equatable {
    let modificationDate: Date?
    let fileSize: Int64?
}

private struct PricingExecutionIdentity: Equatable, Sendable {
    let generation: Int
    let revision: String?
    let modelCatalogRevision: String?
    let artifactURL: URL
}

private struct ActivePricingBasisCacheKey: Equatable {
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    let providerIDs: [String]
}

private struct MonthlyBudgetRefreshKey: Equatable {
    let month: String
    let day: String
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    let pricingUpdatedAt: Date?
}

private struct RefreshDiagnosticRecord {
    let completedAt: Date
    let succeeded: Bool
}

private enum SourceChangeCause: String, Sendable {
    case launch
    case watcherEvent
    case periodicFingerprint
    case watcherDownFallback
    case sourceRoot
    case developerHealthProbe
    case queryScope
    case manual
}

private final class DashboardLayoutWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

enum RefreshSchedule {
    static func isUsageRefreshDue(lastStartedAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard interval.isFinite, interval >= 0 else { return false }
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= interval
    }

    /// Fallback fingerprint scans follow the usage refresh cadence. An
    /// immediate check still runs at launch; after that, scans are gated by
    /// the same interval that throttles usage refreshes.
    static func isFallbackCheckDue(lastCheckAt: Date?, now: Date, refreshInterval: TimeInterval) -> Bool {
        guard let lastCheckAt else { return true }
        guard refreshInterval.isFinite, refreshInterval >= 0 else { return false }
        return now.timeIntervalSince(lastCheckAt) >= refreshInterval
    }

    static func isPricingRefreshDue(
        lastSuccessfulAt: Date?,
        lastAttemptAt: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard interval.isFinite, interval > 0 else { return false }
        let latest = [lastSuccessfulAt, lastAttemptAt].compactMap { $0 }.max()
        guard let latest else { return true }
        return now.timeIntervalSince(latest) >= interval
    }

    /// Backoff for failed fallback scans: the next retry waits a third of the
    /// refresh interval, so repeated failures do not rescan on every 5-second
    /// tick while still allowing the watcher to recover promptly.
    static func fallbackRetryDelay(refreshInterval: TimeInterval) -> TimeInterval {
        max(refreshInterval / 3, 5)
    }
}

protocol CCUsageRunnerProtocol: Sendable {
    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot
    func run(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?
    ) throws -> UsageSnapshot
    func runWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        pricingContext: PricingResolutionContext
    ) throws -> UsageSnapshotBuildResult
    func runMonthlyBudget(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date
    ) throws -> MonthlyBudgetSnapshot
    func runMonthlyBudgetWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date,
        pricingContext: PricingResolutionContext
    ) throws -> MonthlyBudgetBuildResult
}

extension CCUsageRunnerProtocol {
    func run(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?
    ) throws -> UsageSnapshot {
        try run(settings: settings, mode: mode, previousPricingDate: previousPricingDate)
    }

    func runWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        pricingContext: PricingResolutionContext
    ) throws -> UsageSnapshotBuildResult {
        _ = pricingContext
        return UsageSnapshotBuildResult(
            snapshot: try run(
                settings: settings,
                mode: mode,
                previousPricingDate: previousPricingDate,
                pricingConfigURL: pricingConfigURL
            ),
            pricingAssessment: .empty
        )
    }

    func runMonthlyBudget(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date
    ) throws -> MonthlyBudgetSnapshot {
        _ = settings
        _ = mode
        _ = previousPricingDate
        _ = pricingConfigURL
        _ = customPricingRevision
        _ = now
        throw CCUsageRunnerError.monthlyDataUnavailable
    }

    func runMonthlyBudgetWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date,
        pricingContext: PricingResolutionContext
    ) throws -> MonthlyBudgetBuildResult {
        _ = pricingContext
        return MonthlyBudgetBuildResult(
            snapshot: try runMonthlyBudget(
                settings: settings,
                mode: mode,
                previousPricingDate: previousPricingDate,
                pricingConfigURL: pricingConfigURL,
                customPricingRevision: customPricingRevision,
                now: now
            ),
            pricingAssessment: .empty
        )
    }
}

extension CCUsageRunner: CCUsageRunnerProtocol {}

protocol SourceChangeWatcherProtocol: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
}

extension SourceChangeWatcher: SourceChangeWatcherProtocol {}

@MainActor
final class MonitorStore: ObservableObject {
    /// Bump when the cost path changes incompatibly. The first launch after
    /// this value changes automatically reprices the cached snapshot instead
    /// of presenting a result produced by the old cost engine until the normal
    /// 24-hour pricing interval elapses.
    private static let pricingEngineRevision = "ccusage-20.0.32-config-v4-unified-provider-overrides"
    /// The watcher is the normal refresh trigger. This watchdog only covers
    /// state that cannot be delivered reliably as a file event: new roots,
    /// watcher recovery, date/pricing rollovers, and fallback scans.
    private static let watchdogInterval: TimeInterval = 30
    private static let sourceSettleInterval: TimeInterval = 2
    /// Monthly budget data is intentionally eventually consistent. The daily
    /// usage path remains responsive, while this expensive whole-month query
    /// reconciles historical edits and delayed records at a lower cadence.
    private static let monthlyBudgetRefreshInterval: TimeInterval = 60 * 60
    private static let monthlyBudgetRefreshRetryInterval: TimeInterval = 5 * 60
    /// A dirty source is normally allowed to settle before the expensive
    /// whole-month scan starts. This bound prevents a permanent event storm or
    /// repeated usage failures from starving monthly reconciliation forever.
    private static let monthlyBudgetMaxDirtyWaitInterval: TimeInterval = 5 * 60
    private static let developerHealthProbeInterval: TimeInterval = 15 * 60

    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var monthlyBudget: MonthlyBudgetSnapshot?
    @Published private(set) var phase: RefreshPhase = .idle
    @Published private(set) var isDirty = false
    @Published private(set) var lastRefreshDuration: TimeInterval?
    @Published private(set) var customPricingModelCount = 0
    @Published private(set) var customPricingError: String?
    @Published private(set) var modelCatalogEntries: [ModelCatalogEntry] = []
    @Published private(set) var modelCatalogStatus: ModelCatalogStatus = .empty
    @Published private(set) var notificationEvents: [NotificationFeedEvent] = []
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered
    @Published private(set) var developerDiagnostics = DeveloperDiagnosticsSnapshot.empty
    @Published private(set) var pluginStates: [DashboardPluginRuntimeSnapshot] = []
    @Published private(set) var dashboardLayout: DashboardLayout
    @Published private(set) var externalPlugins: [ExternalPluginRecord] = []
    @Published private(set) var externalPluginIssues: [PluginDiscoveryIssue] = []
    @Published private(set) var externalPluginError: String?
    @Published var settings: MonitorSettings {
        didSet { settingsStore.save(settings) }
    }

    private let snapshotStore: SnapshotStore
    private let budgetSnapshotStore: BudgetSnapshotStore
    private let settingsStore: SettingsStore
    private let pluginHost: DashboardPluginHost?
    private let dashboardLayoutStore: DashboardLayoutStore
    private let externalPluginRegistry: ExternalPluginRegistry?
    private let basePluginProviders: [any DashboardPluginProvider]
    private var runner: CCUsageRunnerProtocol
    private var pricingReferenceSnapshot: UsageSnapshot
    private let sourceRootsProvider: () -> [URL]
    private let watcherFactory: ([URL], @escaping () -> Void) -> SourceChangeWatcherProtocol
    private let nowProvider: () -> Date
    private let fingerprintReader: @Sendable () throws -> [SourceFingerprint]
    private let generatedPricingDirectory: URL
    private var watcher: SourceChangeWatcherProtocol?
    private var pendingWatcherRoots: [URL]?
    private var watcherRetryAt: Date?
    private var watchdogTimer: Timer?
    private var scheduledCheckTimer: Timer?
    private var scheduledCheckAt: Date?
    private var developerHealthTimer: Timer?
    private var lastUsageRefreshStartedAt: Date?
    private var lastRefreshStartedAt: Date?
    private var lastRefreshCompletedAt: Date?
    private var lastRefreshIntent: String?
    private var lastRefreshError: String?
    private var refreshDiagnosticRecords: [RefreshDiagnosticRecord] = []
    private var pricingRefreshInFlight = false
    private var refreshInFlight = false
    private var monthlyBudgetRefreshInFlight = false
    private var pendingRefreshIntent: RefreshIntent?
    private var pendingRefreshGeneration: Int?
    private var pendingForcedUsageRefresh = false
    private var pendingForcedUsageGeneration: Int?
    private var pendingUsageRefresh = false
    private var knownSourceRoots: Set<String> = []
    private var dirtyGeneration = 0
    private var dirtySince: Date?
    private var lastSourceEventAt: Date?
    private var lastFallbackCheckAt: Date?
    private var fallbackCheckFailures = 0
    private var pricingGeneration = 0
    private var fallbackCheckInFlight = false
    private var lastMonthlyBudgetRefreshAttemptAt: Date?
    private var lastMonthlyBudgetRefreshAttemptKey: MonthlyBudgetRefreshKey?
    private var lastMonthlyBudgetRefreshAttemptSucceeded = false
    private var monthlyBudgetRefreshRequested = false
    private var lastFallbackFingerprints: [SourceFingerprint] = []
    private var hasFallbackFingerprintBaseline = false
    private var fingerprintBaselineEventCount: Int?
    private var fingerprintBaselineRootGeneration: Int?
    private var fingerprintCheckRequested = false
    private var sourceRootGeneration = 0
    private var fallbackScanCount = 0
    private var lastFallbackScanDuration: TimeInterval?
    private var lastFingerprintDetectionAt: Date?
    private var lastSourceChangeCause: SourceChangeCause?
    private var fingerprintCheckOutcome: String?
    private var watcherState: DeveloperWatcherState = .unknown
    private var watcherStartAttempts = 0
    private var watcherEventCount = 0
    private var watcherStartedAt: Date?
    private var watcherLastEventAt: Date?
    private var watcherMessage: String?
    private var developerHealthProbeInFlight = false
    private var developerHealthProbeFingerprints: [SourceFingerprint]?
    private var developerHealthProbeEventCount = 0
    private var healthProbeCount = 0
    private var lastHealthProbeAt: Date?
    private var lastHealthProbeDuration: TimeInterval?
    private var healthProbeMessage: String?
    private var monthlyBudgetRefreshDates: [Date] = []
    private var monthlyBudgetRefreshFailureDates: [Date] = []
    private var monthlyBudgetLastRefreshAt: Date?
    private var monthlyBudgetLastRefreshSucceeded: Bool?
    private var monthlyBudgetLastRefreshError: String?
    private var customPricingTable: CustomPricingTable
    private var modelCatalogStore: ModelCatalogStore
    private let notificationFeedCoordinator: NotificationFeedCoordinator
    private let mockNotificationFeedPlugin: MockNotificationFeedPlugin
    private let modelCatalogGenerationFence = ModelCatalogGenerationFence()
    private let modelCatalogPersistence: ModelCatalogPersistence
    private let modelCatalogProviderTimeout: TimeInterval
    private var modelCatalogProviders: [any ModelCatalogPluginProvider]
    private let baseModelCatalogProviders: [any ModelCatalogPluginProvider]
    private var modelCatalogRefreshTask: Task<Void, Never>?
    private var modelCatalogRefreshRequestID = 0
    private var activePricingBasisCacheKey: ActivePricingBasisCacheKey?
    private var activePricingBasisCache: PricingExecutionBasis?
    private var modelCatalogProviderGeneration = 0
    private var lastModelCatalogRefreshStartedAt: Date?
    private var activeCustomPricingRevision: String?
    private var activeCustomPricingFileFingerprint: CustomPricingFileFingerprint?
    private let logger = Logger(subsystem: "com.xingyu.meterlark", category: "refresh")
    private var testingNow: Date?
    private var aboutWindow: NSWindow?
    private var modelCatalogWindow: NSWindow?
    private let modelCatalogViewState = ModelCatalogViewState()
    private var budgetSettingsWindow: NSWindow?
    private var developerDiagnosticsWindow: NSWindow?
    private var customPricingPanel: NSOpenPanel?
    private var externalPluginPanel: NSOpenPanel?
    private var pluginSettingsWindow: NSWindow?
    private var pluginConfigurationWindow: NSWindow?
    private var pluginConfigurationPluginID: String?
    private var dashboardLayoutSettingsWindow: NSWindow?
    private var dashboardLayoutWindowDelegate: DashboardLayoutWindowDelegate?
    /// The layout being edited is intentionally separate from the committed
    /// Dashboard layout. Keep it while the editor is open so plugin runtime
    /// updates can refresh the component catalog without discarding the
    /// user's in-progress choices.
    private var dashboardLayoutEditingDraft: DashboardLayout?
    private var dashboardLayoutEditingPopoverHeight: Double?
    private var dashboardPreviewWindow: NSWindow?
    private var dashboardPreviewState: DashboardLayoutPreviewState?
    private var lastPluginRefreshStartedAt: Date?

    init(
        snapshotStore: SnapshotStore = SnapshotStore(),
        budgetSnapshotStore: BudgetSnapshotStore = BudgetSnapshotStore(),
        settingsStore: SettingsStore = SettingsStore(),
        runner: CCUsageRunnerProtocol? = nil,
        sourceRootsProvider: (() -> [URL])? = nil,
        watcherFactory: (([URL], @escaping () -> Void) -> SourceChangeWatcherProtocol)? = nil,
        nowProvider: (() -> Date)? = nil,
        fingerprintReader: (@Sendable () throws -> [SourceFingerprint])? = nil,
        generatedPricingDirectory: URL? = nil,
        pluginHost: DashboardPluginHost? = nil,
        dashboardLayoutStore: DashboardLayoutStore = DashboardLayoutStore(),
        externalPluginRegistry: ExternalPluginRegistry? = nil,
        basePluginProviders: [any DashboardPluginProvider] = [],
        modelCatalogStore: ModelCatalogStore = ModelCatalogStore(),
        notificationFeedStore: NotificationFeedStore = NotificationFeedStore(),
        baseModelCatalogProviders: [any ModelCatalogPluginProvider] = [],
        modelCatalogProviderTimeout: TimeInterval = ModelCatalogFetchBatch.defaultProviderTimeout
    ) {
        self.snapshotStore = snapshotStore
        self.budgetSnapshotStore = budgetSnapshotStore
        self.settingsStore = settingsStore
        self.pluginHost = pluginHost
        self.dashboardLayoutStore = dashboardLayoutStore
        self.externalPluginRegistry = externalPluginRegistry
        self.basePluginProviders = basePluginProviders
        self.modelCatalogStore = modelCatalogStore
        self.modelCatalogProviderTimeout = modelCatalogProviderTimeout.isFinite && modelCatalogProviderTimeout > 0
            ? modelCatalogProviderTimeout
            : ModelCatalogFetchBatch.defaultProviderTimeout
        let notificationCoordinator = NotificationFeedCoordinator(store: notificationFeedStore)
        self.notificationFeedCoordinator = notificationCoordinator
        self.mockNotificationFeedPlugin = MockNotificationFeedPlugin(sink: notificationCoordinator)
        self.modelCatalogProviders = baseModelCatalogProviders
        self.baseModelCatalogProviders = baseModelCatalogProviders
        self.runner = runner ?? CCUsageRunner()
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sourceRootsProvider = sourceRootsProvider ?? { SourceFingerprintReader.sourceRoots(home: home) }
        self.watcherFactory = watcherFactory ?? { paths, handler in
            SourceChangeWatcher(paths: paths, handler: handler)
        }
        self.nowProvider = nowProvider ?? { Date() }
        self.fingerprintReader = fingerprintReader ?? { SourceFingerprintReader.read() }
        self.generatedPricingDirectory = generatedPricingDirectory ?? Self.managedPricingDirectory()
        let loadedSnapshot = snapshotStore.load() ?? .empty
        self.snapshot = loadedSnapshot
        self.monthlyBudget = budgetSnapshotStore.load()
        self.pricingReferenceSnapshot = loadedSnapshot
        let initialSettings = settingsStore.load()
        self.settings = initialSettings
        self.modelCatalogPersistence = ModelCatalogPersistence(fence: modelCatalogGenerationFence)
        let loadedCustomPricing = Self.loadCustomPricing(path: initialSettings.customPricingPath)
        self.customPricingTable = loadedCustomPricing.table
        self.activeCustomPricingRevision = loadedCustomPricing.table.revision
        self.activeCustomPricingFileFingerprint = Self.customPricingFileFingerprint(path: initialSettings.customPricingPath)
        self.customPricingModelCount = loadedCustomPricing.table.modelCount
        self.customPricingError = loadedCustomPricing.error
        let initialModelCatalogProviderIDs = Set(baseModelCatalogProviders.map { $0.manifest.id })
        self.modelCatalogEntries = modelCatalogStore.entries(for: initialModelCatalogProviderIDs)
        self.modelCatalogStatus = modelCatalogStore.status(for: initialModelCatalogProviderIDs)
        self.notificationEvents = self.notificationFeedCoordinator.visibleEvents
        self.launchAtLoginStatus = LaunchAtLoginService.currentStatus()
        self.pluginStates = pluginHost?.snapshots ?? []
        self.dashboardLayout = dashboardLayoutStore.loadOrDefault()
        self.externalPlugins = []
        self.externalPluginIssues = []
        pluginHost?.setLanguage(initialSettings.language)
        self.pluginStates = pluginHost?.snapshots ?? []
        let initialScope = CCUsageRunner.queryScope(
            for: initialSettings.lookbackDays,
            now: (nowProvider ?? { Date() })()
        )
        if loadedSnapshot.hasData, loadedSnapshot.queryScope != initialScope {
            // A legacy snapshot has no proof of its date range, so do not
            // present it under current settings. Keep it privately as a
            // pricing reference so trusted overlapping costs survive the
            // reconciliation.
            self.snapshot = .empty
        }
        if pluginHost != nil {
            pluginHost?.onChange = { [weak self] snapshots in
                self?.pluginStates = snapshots
                self?.refreshDashboardLayoutSettingsWindow()
                self?.refreshDashboardPreviewWindow()
            }
        }
        if externalPluginRegistry != nil {
            // Discovery at launch must respect the persisted catalog deadline;
            // installing or reconfiguring a plugin later still forces a fetch.
            reloadExternalPlugins(forceModelCatalogRefresh: false)
        }
        Self.reconcileManagedCcusagePricingArtifacts(
            table: loadedCustomPricing.table,
            remoteEntries: modelCatalogStore.entries(for: initialModelCatalogProviderIDs),
            generation: self.pricingGeneration,
            directory: self.generatedPricingDirectory
        )
        logger.info("MonitorStore initialized; hasSnapshot=\(self.snapshot.hasData, privacy: .public)")
        reconcileLaunchAtLogin()
        startMonitoring()
        refreshPluginsIfDue(force: true)
        refreshModelCatalogIfDue()
        configureDeveloperHealthTimer()
        if initialSettings.developerMode {
            runDeveloperHealthCheck()
        }
        publishDeveloperDiagnostics()
    }

    deinit {
        watchdogTimer?.invalidate()
        scheduledCheckTimer?.invalidate()
        developerHealthTimer?.invalidate()
        watcher?.stop()
        modelCatalogRefreshTask?.cancel()
    }

    var menuBarFormat: MenuBarFormat {
        MenuBarFormat(rawValue: settings.menuBarFormat)
    }

    var notificationUnreadCount: Int {
        notificationEvents.reduce(into: 0) { count, event in
            if !event.isRead { count += 1 }
        }
    }

    var effectivePopoverHeight: Double {
        effectivePopoverHeight(for: nil)
    }

    func effectivePopoverHeight(
        for layout: DashboardLayout?,
        storedHeight: Double? = nil,
        contentHeight: Double? = nil,
        maximumVisibleHeight: Double? = nil
    ) -> Double {
        let selectedLayout = layout ?? dashboardLayout
        return MonitorSettings.effectivePopoverHeight(
            storedHeight: storedHeight ?? settings.popoverHeight,
            dailyCostLimit: settings.dailyCostLimit,
            monthlyCostLimit: settings.monthlyCostLimit,
            interfaceTextSize: settings.interfaceTextSize,
            contentHeight: contentHeight ?? DashboardLayoutMetrics.estimatedPopoverHeight(
                components: visibleDashboardComponents(for: selectedLayout),
                layout: selectedLayout,
                interfaceTextSize: settings.interfaceTextSize
            ),
            maximumVisibleHeight: maximumVisibleHeight
        )
    }

    var budgetStatus: BudgetStatus {
        BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthlyBudget,
            settings: settings,
            now: currentDate
        )
    }

    var primaryCostTitle: String {
        Currency.format(snapshot.primaryEstimatedCost)
    }

    var menuBarHelpText: String {
        let copy = L10n(language: settings.language)
        var base = copy.text(
            "Today's estimated API-equivalent cost: " + primaryCostTitle + ". Open for details.",
            "今天的 API 等价费用估算：" + primaryCostTitle + "。点开查看详情。"
        )
        if budgetStatus.hasUncertainPricing {
            base += " " + copy.budgetDataIncomplete + (copy.language == .chinese ? "。" : ".")
        }
        guard settings.notificationFeedEnabled, notificationUnreadCount > 0 else { return base }
        let unread = copy.notificationFeedUnreadCount(notificationUnreadCount)
        return copy.text(
            base + " " + unread + ".",
            base + " " + unread + "。"
        )
    }

    func editMenuBarFormat() {
        let copy = L10n(language: settings.language)
        let draft = settings.menuBarFormat
        let previewCost = 12.34

        while true {
            let alert = NSAlert()
            alert.messageText = copy.menuBarFormat
            alert.informativeText = copy.menuBarFormatMessage

            let field = NSTextField(string: draft)
            field.placeholderString = MenuBarFormat.defaultValue
            field.usesSingleLineMode = true
            field.focusRingType = .default
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

            let previewTitle = NSTextField(labelWithString: copy.menuBarFormatPreview)
            previewTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            previewTitle.textColor = .secondaryLabelColor

            let previewHost = NSHostingView(
                rootView: MenuBarFormatPreviewView(
                    format: MenuBarFormatPreviewState(rawValue: draft).format,
                    cost: previewCost
                )
            )
            previewHost.setContentHuggingPriority(.required, for: .vertical)
            previewHost.setContentCompressionResistancePriority(.required, for: .vertical)

            let previewStatus = NSTextField(labelWithString: copy.menuBarFormatPreviewHint)
            previewStatus.font = NSFont.systemFont(ofSize: 11)
            previewStatus.textColor = .secondaryLabelColor
            previewStatus.maximumNumberOfLines = 0
            previewStatus.preferredMaxLayoutWidth = 360

            let stack = NSStackView(views: [field, previewTitle, previewHost, previewStatus])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.setFrameSize(NSSize(width: 360, height: 132))
            alert.accessoryView = stack
            let saveButton = alert.addButton(withTitle: copy.save)
            alert.addButton(withTitle: copy.cancel)
            alert.window.initialFirstResponder = field

            func updatePreview(for rawValue: String) {
                let state = MenuBarFormatPreviewState(rawValue: rawValue)
                previewHost.rootView = MenuBarFormatPreviewView(format: state.format, cost: previewCost)
                if state.canSave {
                    previewStatus.stringValue = copy.menuBarFormatPreviewHint
                    previewStatus.textColor = .secondaryLabelColor
                    saveButton.isEnabled = true
                } else {
                    previewStatus.stringValue = copy.menuBarFormatError(state.format.validationError)
                    previewStatus.textColor = .systemRed
                    saveButton.isEnabled = false
                }
            }

            updatePreview(for: field.stringValue)
            let textChangeObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidChangeNotification,
                object: field,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    updatePreview(for: field.stringValue)
                }
            }
            defer { NotificationCenter.default.removeObserver(textChangeObserver) }

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let candidate = MenuBarFormat(rawValue: field.stringValue)
            guard candidate.isValid else { continue }

            settings.menuBarFormat = candidate.rawValue
            return
        }
    }

    var statusText: String {
        let copy = L10n(language: settings.language)
        switch phase {
        case .idle: return snapshot.hasData ? copy.ready : copy.waitingForUsage
        case .waiting: return copy.changesPending
        case .refreshing: return copy.updatingUsage
        case .updatingPricing: return copy.updatingPricing
        case let .failed(message): return message
        }
    }

    var lastUpdatedText: String {
        lastUpdatedText(relativeTo: Date())
    }

    func lastUpdatedText(relativeTo now: Date) -> String {
        guard snapshot.generatedAt != .distantPast else { return L10n(language: settings.language).noSnapshot }
        return RelativeTime.localizedString(
            for: snapshot.generatedAt,
            relativeTo: now,
            language: settings.language
        )
    }

    var pricingStatusText: String {
        pricingStatusText(relativeTo: Date())
    }

    func pricingStatusText(relativeTo now: Date) -> String {
        let copy = L10n(language: settings.language)
        guard let pricingUpdatedAt = snapshot.pricingUpdatedAt else { return copy.pricing + " " + copy.noSnapshot.lowercased() }
        let prefix = pricingStatusIsStale(relativeTo: now) ? copy.pricing + " " + copy.stale + " · " : copy.pricing + " "
        return prefix + RelativeTime.localizedString(
            for: pricingUpdatedAt,
            relativeTo: now,
            language: settings.language
        )
    }

    func pricingIsStale(relativeTo now: Date) -> Bool {
        if snapshotScopeMismatch { return true }
        if snapshot.hasData, snapshot.modelCatalogRevision != activeModelCatalogRevision { return true }
        if customPricingRevisionMismatch { return true }
        if customPricingFileChanged { return true }
        guard let pricingUpdatedAt = snapshot.pricingUpdatedAt else { return false }
        return now.timeIntervalSince(pricingUpdatedAt) >= pricingRefreshInterval
    }

    /// The displayed snapshot can be stale while its replacement is already
    /// being prepared. Keep that internal correctness signal intact, but do
    /// not turn the expected catalog/pricing reconciliation window into a
    /// warning badge or yellow footer label.
    func pricingStatusIsStale(relativeTo now: Date) -> Bool {
        pricingIsStale(relativeTo: now) && !pricingUpdatePending
    }

    private var pricingUpdatePending: Bool {
        if modelCatalogRefreshTask != nil
            || pricingRefreshInFlight
            || pendingRefreshIntent?.isPricing == true {
            return true
        }

        // A usage refresh can be the first step of an automatic pricing
        // refresh. Suppress the stale warning during that handoff as well;
        // finishRefresh starts the queued pricing run once usage completes.
        return settings.automaticPricingRefresh
            && (isDirty || phase == .refreshing)
            && pricingIsDue
    }

    private var customPricingRevisionMismatch: Bool {
        snapshot.hasData && snapshot.customPricingRevision != activeCustomPricingRevision
    }

    private var customPricingFileChanged: Bool {
        let current = Self.customPricingFileFingerprint(path: settings.customPricingPath)
        guard current != activeCustomPricingFileFingerprint else { return false }

        // A path or local mtime is only a reload hint. If the file now
        // resolves to the same canonical content revision, it must not make a
        // trusted snapshot appear stale merely because it was copied or
        // atomically rewritten on another path.
        guard !settings.customPricingPath.isEmpty,
              let table = try? CustomPricingTable(
                contentsOf: URL(fileURLWithPath: settings.customPricingPath)
              ) else {
            return true
        }
        guard table.revision == activeCustomPricingRevision else { return true }
        // The content hash is unchanged, so this fingerprint has now been
        // reconciled. Cache it to avoid reparsing the same file on every stale
        // or due check until the next actual file change.
        activeCustomPricingFileFingerprint = current
        return false
    }

    private var snapshotScopeMismatch: Bool {
        guard snapshot.hasData, let savedScope = snapshot.queryScope else { return false }
        return savedScope != currentQueryScope
    }

    var customPricingStatusText: String {
        let copy = L10n(language: settings.language)
        if customPricingError != nil {
            return copy.customPricingUnavailable
        }
        guard !settings.customPricingPath.isEmpty else {
            return copy.notConfigured
        }
        return "\(customPricingModelCount) \(copy.models)"
    }

    var hasCustomPricing: Bool {
        !customPricingTable.isEmpty
    }

    var hasModelCatalogEntries: Bool {
        !modelCatalogEntries.isEmpty
    }

    var allModelCatalogEntries: [ModelCatalogEntry] {
        (customPricingTable.modelCatalogEntries + modelCatalogEntries).sorted { lhs, rhs in
            let lhsName = lhs.modelName.lowercased()
            let rhsName = rhs.modelName.lowercased()
            if lhsName == rhsName { return lhs.id < rhs.id }
            return lhsName < rhsName
        }
    }

    /// Display names are owned by the plugin manifest, not by the pricing
    /// resolver. Keep this mapping separate from catalog entries so a model
    /// backend such as `bedrock` is never mistaken for the price-list source.
    var modelCatalogProviderDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: modelCatalogProviders.map { provider in
            (
                provider.manifest.id,
                provider.manifest.localizedDisplayName(for: settings.language)
            )
        })
    }

    func customPricing(for modelName: String, tokens: TokenTotals) -> CustomModelPricing? {
        guard let pricing = customPricingTable.pricing(for: modelName),
              pricing.hasCompleteRates(for: tokens) else {
            return nil
        }
        return pricing
    }

    func canonicalPricing(for modelName: String) -> CanonicalModelPricing? {
        pricingDetails(for: modelName)?.schedule
    }

    /// The view-facing lookup uses the same composed catalog as the runner.
    /// Views receive one resolved schedule and never need to know whether it
    /// came from custom pricing or an enabled model-catalog provider.
    func pricingDetails(for modelName: String) -> PricingCatalogMatch? {
        let basis = activePricingBasis
        guard snapshot.hasData,
              basis.matches(
                  customPricingRevision: snapshot.customPricingRevision,
                  modelCatalogRevision: snapshot.modelCatalogRevision
              ) else {
            // The current catalog may already have changed while the last
            // snapshot is still being displayed. Do not show the new schedule
            // beside a cost calculated from the old schedule.
            return nil
        }
        return basis.composition.match(for: modelName)
    }

    func refreshNow() {
        refreshPluginsIfDue(force: true)
        // A manual usage refresh should also repair a snapshot whose pricing
        // basis is already stale. The catalog fetch remains asynchronous; the
        // refresh coordinator waits for it before starting pricing. Queue the
        // pricing intent explicitly so this remains true even when automatic
        // pricing refresh is disabled or the usage scan finishes first.
        // An empty launch snapshot has no displayed pricing warning to repair.
        // In particular, the pricing-engine migration marker can make
        // `pricingIsDue` true before the first usage scan; queueing pricing in
        // that state would turn a manual usage refresh into an unexpected
        // second runner call. Once a report exists, the due check covers stale
        // custom/catalog basis and the normal pricing interval.
        let pricingNeedsRefresh = snapshot.hasData && pricingIsDue
        if pricingNeedsRefresh {
            refreshModelCatalogIfDue(force: true)
        }
        markDirty(cause: .manual)
        if pricingNeedsRefresh {
            queueRefresh(
                intent: .pricing(fallbackToOffline: false, allowEmptyCandidate: false),
                generation: dirtyGeneration
            )
        }
        beginRefresh(intent: .usage, bypassInterval: true, generation: dirtyGeneration)
    }

    func updatePricingNow() {
        refreshModelCatalogIfDue(force: true)
        beginRefresh(intent: .pricing(fallbackToOffline: false, allowEmptyCandidate: false), bypassInterval: true)
    }

    func refreshPlugins() {
        refreshPluginsIfDue(force: true)
        refreshModelCatalogIfDue(force: true)
    }

    func markNotificationRead(_ id: String) {
        notificationFeedCoordinator.markRead(id)
        notificationEvents = notificationFeedCoordinator.visibleEvents
    }

    func markAllNotificationsRead() {
        notificationFeedCoordinator.markAllRead()
        notificationEvents = notificationFeedCoordinator.visibleEvents
    }

    func dismissNotification(_ id: String) {
        notificationFeedCoordinator.dismiss(id)
        notificationEvents = notificationFeedCoordinator.visibleEvents
    }

    func dismissAllNotifications() {
        notificationFeedCoordinator.dismissAll()
        notificationEvents = notificationFeedCoordinator.visibleEvents
    }

    /// Emits a deterministic-looking batch with fresh occurrence identities
    /// so the developer can inspect unread, read, dismiss, severity, and
    /// namespaced-event presentation through the real notification feed.
    @discardableResult
    func publishMockNotificationEvents() -> Int {
        guard settings.developerMode else { return 0 }
        let events = mockNotificationFeedPlugin.publishSampleBatch(
            language: settings.language,
            now: currentDate
        )
        notificationEvents = notificationFeedCoordinator.visibleEvents
        return events.count
    }

    /// Host-owned publishing seam for future internal modules and plugin
    /// adapters. Producers receive this sink rather than the large MonitorStore
    /// or any view, keeping notification persistence source-independent.
    var notificationFeedSink: any NotificationFeedSink {
        notificationFeedCoordinator
    }

    var externalPluginManagementAvailable: Bool {
        externalPluginRegistry != nil
    }

    /// Components exposed to the global Dashboard editor and renderer. The
    /// plugin list is deliberately derived from active providers, not from
    /// every discovered package, so an uninstalled, disabled, or invalid
    /// plugin cannot leak into the Dashboard.
    var availableDashboardComponents: [DashboardLayoutComponent] {
        var components = [
            DashboardLayoutComponent(
                builtIn: .summary,
                title: L10n(language: settings.language).dashboardSummary
            )
        ]
        if settings.dailyCostLimit > 0 || settings.monthlyCostLimit > 0 {
            components.append(DashboardLayoutComponent(
                builtIn: .budget,
                title: L10n(language: settings.language).budget
            ))
        }

        if DashboardComponentAvailability.includesModelCatalog(
            activeCatalogProviderCount: modelCatalogProviders.count
        ) {
            components.append(DashboardLayoutComponent(
                builtIn: .modelCatalog,
                title: L10n(language: settings.language).modelCatalogTitle
            ))
        }
        for snapshot in pluginStates {
            let blocks = pluginLayoutBlocks(for: snapshot)
            for block in blocks {
                components.append(DashboardLayoutComponent(
                    pluginID: snapshot.id,
                    blockID: block.id,
                    title: "\(snapshot.manifest.localizedDisplayName(for: settings.language)) · \(block.title)",
                    blockKind: block.kind,
                    itemCount: block.itemCount,
                    defaultColumns: block.defaultColumns
                ))
            }
        }

        components.append(DashboardLayoutComponent(
            builtIn: .daily,
            title: L10n(language: settings.language).usageByDay
        ))
        return components
    }

    var visibleDashboardComponents: [DashboardLayoutComponent] {
        visibleDashboardComponents(for: nil)
    }

    func visibleDashboardComponents(for layout: DashboardLayout?) -> [DashboardLayoutComponent] {
        let components = availableDashboardComponents
        let normalized = (layout ?? dashboardLayout).normalized(for: components)
        let hidden = Set(normalized.hiddenComponentIDs)
        let byID = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        return normalized.componentOrder.compactMap { componentID in
            guard !hidden.contains(componentID) else { return nil }
            return byID[componentID]
        }
    }

    func dashboardComponentColumns(
        for component: DashboardLayoutComponent,
        layout: DashboardLayout? = nil
    ) -> Int? {
        guard let defaultColumns = component.defaultColumns else { return nil }
        let normalized = (layout ?? dashboardLayout).normalized(for: availableDashboardComponents)
        return normalized.columns(for: component.id, default: defaultColumns)
    }

    func saveDashboardLayout(
        _ layout: DashboardLayout,
        popoverHeight: Double? = nil
    ) throws {
        let normalized = layout.normalized(for: availableDashboardComponents)
        try normalized.validate()
        let selectedPopoverHeight = popoverHeight ?? settings.popoverHeight
        guard MonitorSettings.isValidPopoverHeight(selectedPopoverHeight) else {
            throw DashboardLayoutValidationError.invalidPopoverHeight
        }
        try dashboardLayoutStore.save(normalized)
        dashboardLayout = normalized
        dashboardLayoutEditingDraft = normalized
        dashboardLayoutEditingPopoverHeight = selectedPopoverHeight
        settings.popoverHeight = selectedPopoverHeight
        refreshDashboardLayoutSettingsWindow()
        updateDashboardPreviewLayout(normalized, popoverHeight: selectedPopoverHeight)
    }

    func resetDashboardLayout() throws {
        try dashboardLayoutStore.remove()
        dashboardLayout = .default
        dashboardLayoutEditingDraft = dashboardLayout.normalized(for: availableDashboardComponents)
        dashboardLayoutEditingPopoverHeight = settings.popoverHeight
        refreshDashboardLayoutSettingsWindow()
        updateDashboardPreviewLayout(
            dashboardLayout,
            popoverHeight: settings.popoverHeight
        )
    }

    func showDashboardLayoutSettings() {
        let copy = L10n(language: settings.language)
        let shouldArrangeWindows = dashboardLayoutSettingsWindow == nil || dashboardPreviewWindow == nil
        let previewWindow = showDashboardPreviewWindow(copy: copy)
        let components = availableDashboardComponents
        let editingLayout = (dashboardLayoutEditingDraft ?? dashboardLayout)
            .normalized(for: components)
        let editingPopoverHeight = dashboardLayoutEditingPopoverHeight ?? settings.popoverHeight
        dashboardLayoutEditingDraft = editingLayout
        dashboardLayoutEditingPopoverHeight = editingPopoverHeight
        let rootView = makeDashboardLayoutSettingsView(
            components: components,
            layout: editingLayout,
            popoverHeight: editingPopoverHeight
        )

        let window: NSWindow
        if let existing = dashboardLayoutSettingsWindow {
            window = existing
            window.title = copy.dashboardLayoutSettingsTitle
            if let hostingView = existing.contentView as? NSHostingView<DashboardLayoutSettingsView> {
                hostingView.rootView = rootView
            }
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.dashboardLayoutSettingsTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            let delegate = DashboardLayoutWindowDelegate { [weak self] in
                self?.closeDashboardLayoutSession()
            }
            window.delegate = delegate
            dashboardLayoutWindowDelegate = delegate
            dashboardLayoutSettingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        if shouldArrangeWindows {
            arrangeDashboardLayoutWindows(settingsWindow: window, previewWindow: previewWindow)
        }
        previewWindow.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func showDashboardPreviewWindow(copy: L10n) -> NSWindow {
        let previewState = dashboardPreviewState ?? DashboardLayoutPreviewState(
            layout: dashboardLayout.normalized(for: availableDashboardComponents),
            popoverHeight: dashboardLayoutEditingPopoverHeight ?? settings.popoverHeight
        )
        dashboardPreviewState = previewState

        let window: NSWindow
        if let existing = dashboardPreviewWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: DashboardPreviewView(store: self, previewState: previewState)
            )
            dashboardPreviewWindow = window
        }

        if let hostingView = window.contentView as? NSHostingView<DashboardPreviewView> {
            hostingView.rootView = DashboardPreviewView(store: self, previewState: previewState)
        }
        window.title = copy.dashboardLayoutPreviewTitle
        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.popoverWidth),
            height: CGFloat(effectivePopoverHeight(
                for: previewState.layout,
                storedHeight: previewState.popoverHeight
            ))
        ))
        return window
    }

    private func closeDashboardLayoutSession() {
        dashboardLayoutEditingDraft = nil
        dashboardLayoutEditingPopoverHeight = nil
        dashboardPreviewState?.layout = dashboardLayout.normalized(for: availableDashboardComponents)
        dashboardPreviewState?.popoverHeight = settings.popoverHeight
        dashboardLayoutSettingsWindow?.orderOut(nil)
        dashboardPreviewWindow?.orderOut(nil)
    }

    private func updateDashboardLayoutDraft(
        _ layout: DashboardLayout,
        popoverHeight: Double
    ) {
        let normalized = layout.normalized(for: availableDashboardComponents)
        guard MonitorSettings.isValidPopoverHeight(popoverHeight) else { return }
        dashboardLayoutEditingDraft = normalized
        dashboardLayoutEditingPopoverHeight = popoverHeight
        updateDashboardPreviewLayout(normalized, popoverHeight: popoverHeight)
    }

    private func updateDashboardPreviewLayout(
        _ layout: DashboardLayout,
        popoverHeight: Double? = nil
    ) {
        guard let previewState = dashboardPreviewState else { return }
        previewState.layout = layout.normalized(for: availableDashboardComponents)
        if let popoverHeight {
            previewState.popoverHeight = popoverHeight
        }
        refreshDashboardPreviewWindow()
    }

    private func arrangeDashboardLayoutWindows(settingsWindow: NSWindow, previewWindow: NSWindow) {
        guard let screen = settingsWindow.screen ?? NSScreen.main else {
            settingsWindow.center()
            previewWindow.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let gap: CGFloat = 20
        let margin: CGFloat = 16
        let totalWidth = previewWindow.frame.width + gap + settingsWindow.frame.width
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - totalWidth - margin
        let originX = max(
            minimumX,
            min(visibleFrame.midX - totalWidth / 2, maximumX)
        )
        let topY = visibleFrame.maxY - margin

        previewWindow.setFrameOrigin(NSPoint(
            x: originX,
            y: topY - previewWindow.frame.height
        ))
        settingsWindow.setFrameOrigin(NSPoint(
            x: originX + previewWindow.frame.width + gap,
            y: topY - settingsWindow.frame.height
        ))
    }

    func refreshExternalPlugins() {
        reloadExternalPlugins()
        refreshPluginsIfDue(force: true)
    }

    func chooseAndInstallExternalPlugin() {
        guard externalPluginRegistry != nil, externalPluginPanel == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.presentExternalPluginPanel()
        }
    }

    func installExternalPlugin(manifestJSON: String) throws {
        guard let externalPluginRegistry else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        let installed = try externalPluginRegistry.install(manifestJSON: manifestJSON)
        didInstallExternalPlugin(installed)
    }

    func setExternalPluginEnabled(pluginID: String, enabled: Bool) {
        guard let externalPluginRegistry else { return }
        do {
            try externalPluginRegistry.setEnabled(enabled, pluginID: pluginID)
            externalPluginError = nil
            reloadExternalPlugins(
                replacingIDs: [pluginID],
                pluginIDsToRefresh: enabled ? [pluginID] : []
            )
        } catch {
            externalPluginError = error.localizedDescription
            refreshPluginSettingsWindow()
        }
    }

    func showPluginConfiguration(pluginID: String) {
        guard let externalPluginRegistry,
              let record = externalPlugins.first(where: { $0.id == pluginID }),
              let schema = record.manifest.configuration else {
            return
        }

        let draft: PluginConfigurationDraft
        do {
            draft = try externalPluginRegistry.loadConfigurationDraft(pluginID: pluginID)
        } catch {
            externalPluginError = error.localizedDescription
            refreshPluginSettingsWindow()
            return
        }

        let copy = L10n(language: settings.language)
        let rootView = PluginConfigurationView(
            record: record,
            schema: schema,
            draft: draft,
            language: settings.language,
            appearance: settings.appearance,
            surfaceStyle: settings.surfaceStyle,
            interfaceTextSize: settings.interfaceTextSize,
            onSave: { [weak self] submission in
                try self?.saveExternalPluginConfiguration(submission, pluginID: pluginID)
            },
            onReset: { [weak self] in
                try self?.resetExternalPluginConfiguration(pluginID: pluginID)
            },
            onClose: { [weak self] in self?.pluginConfigurationWindow?.orderOut(nil) }
        )

        let window: NSWindow
        if let existing = pluginConfigurationWindow {
            window = existing
            window.title = copy.pluginConfigurationTitle(record.manifest.localizedDisplayName(for: settings.language))
            if let hostingView = existing.contentView as? NSHostingView<PluginConfigurationView> {
                hostingView.rootView = rootView
            }
            pluginConfigurationPluginID = pluginID
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.pluginConfigurationTitle(record.manifest.localizedDisplayName(for: settings.language))
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            pluginConfigurationWindow = window
            pluginConfigurationPluginID = pluginID
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveExternalPluginConfiguration(
        _ submission: PluginConfigurationSubmission,
        pluginID: String
    ) throws {
        guard let externalPluginRegistry else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        try externalPluginRegistry.saveConfiguration(pluginID: pluginID, submission: submission)
        externalPluginError = nil
        reloadExternalPlugins(replacingIDs: [pluginID], pluginIDsToRefresh: [pluginID])
    }

    private func resetExternalPluginConfiguration(pluginID: String) throws {
        guard let externalPluginRegistry else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        try externalPluginRegistry.resetConfiguration(pluginID: pluginID)
        externalPluginError = nil
        reloadExternalPlugins(replacingIDs: [pluginID], pluginIDsToRefresh: [pluginID])
    }

    func setDeveloperMode(_ enabled: Bool) {
        guard settings.developerMode != enabled else { return }
        settings.developerMode = enabled
        configureDeveloperHealthTimer()
        if enabled {
            watcherState = watcher?.isRunning == true ? .running : .down
            healthProbeMessage = "Health check pending"
            runDeveloperHealthCheck()
        } else {
            developerDiagnosticsWindow?.orderOut(nil)
        }
        publishDeveloperDiagnostics()
    }

    func showDeveloperDiagnostics() {
        guard settings.developerMode else { return }
        runDeveloperHealthCheck()
        let copy = L10n(language: settings.language)
        let window: NSWindow
        if let existing = developerDiagnosticsWindow {
            window = existing
            window.title = copy.developerDiagnosticsTitle
            refreshDeveloperDiagnosticsWindow()
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.developerDiagnosticsTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DeveloperDiagnosticsView(store: self))
            window.center()
            developerDiagnosticsWindow = window
        }

        window.setContentSize(NSSize(width: 720, height: 780))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func runDeveloperHealthCheck() {
        guard settings.developerMode, !developerHealthProbeInFlight else { return }
        developerHealthProbeInFlight = true
        healthProbeCount += 1
        publishDeveloperDiagnostics()

        let reader = fingerprintReader
        let started = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result: Result<[SourceFingerprint], Error>
            do {
                result = .success(try reader())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                self?.finishDeveloperHealthCheck(result, started: started)
            }
        }
    }

    func copyDeveloperDiagnostics() {
        let formatter = ISO8601DateFormatter()
        let diagnostics = developerDiagnostics
        let date: (Date?) -> String = { value in
            guard let value else { return "n/a" }
            return formatter.string(from: value)
        }
        let duration: (TimeInterval?) -> String = { value in
            guard let value else { return "n/a" }
            return String(format: "%.3fs", value)
        }
        let text = [
            "Meterlark developer diagnostics",
            "capturedAt=\(date(diagnostics.capturedAt))",
            "appVersion=\(diagnostics.appVersion)",
            "appBuild=\(diagnostics.appBuild)",
            "bundledCCUsage=\(diagnostics.bundledCCUsageVersion)",
            "watcherState=\(diagnostics.watcherState.rawValue)",
            "watcherMessage=\(redactedDiagnosticText(diagnostics.watcherMessage))",
            "watchedRootCount=\(diagnostics.watchedRootCount)",
            "watcherStartAttempts=\(diagnostics.watcherStartAttempts)",
            "watcherEventCount=\(diagnostics.watcherEventCount)",
            "watcherStartedAt=\(date(diagnostics.watcherStartedAt))",
            "watcherLastEventAt=\(date(diagnostics.watcherLastEventAt))",
            "watcherRetryAt=\(date(diagnostics.watcherRetryAt))",
            "sourceVerificationMode=\(diagnostics.sourceVerificationMode)",
            "fingerprintCheckInterval=\(diagnostics.fingerprintCheckInterval)s",
            "lastFingerprintCheckAt=\(date(diagnostics.lastFingerprintCheckAt))",
            "nextFingerprintCheckAt=\(date(diagnostics.nextFingerprintCheckAt))",
            "lastFingerprintDetectionAt=\(date(diagnostics.lastFingerprintDetectionAt))",
            "lastSourceChangeCause=\(diagnostics.lastSourceChangeCause ?? "n/a")",
            "fingerprintCheckOutcome=\(diagnostics.fingerprintCheckOutcome ?? "n/a")",
            "fingerprintCheckPending=\(diagnostics.fingerprintCheckPending)",
            "fallbackScanCount=\(diagnostics.fallbackScanCount)",
            "lastFallbackScanAt=\(date(diagnostics.lastFallbackScanAt))",
            "lastFallbackScanDuration=\(duration(diagnostics.lastFallbackScanDuration))",
            "fallbackFailureCount=\(diagnostics.fallbackFailureCount)",
            "healthProbeCount=\(diagnostics.healthProbeCount)",
            "lastHealthProbeAt=\(date(diagnostics.lastHealthProbeAt))",
            "lastHealthProbeDuration=\(duration(diagnostics.lastHealthProbeDuration))",
            "healthProbeMessage=\(redactedDiagnosticText(diagnostics.healthProbeMessage))",
            "phase=\(diagnostics.phase)",
            "isDirty=\(diagnostics.isDirty)",
            "dirtyGeneration=\(diagnostics.dirtyGeneration)",
            "lastSourceEventAt=\(date(diagnostics.lastSourceEventAt))",
            "scheduledCheckAt=\(date(diagnostics.scheduledCheckAt))",
            "watchdogInterval=\(diagnostics.watchdogInterval)s",
            "sourceSettleInterval=\(diagnostics.sourceSettleInterval)s",
            "refreshInterval=\(diagnostics.refreshInterval)s",
            "lastRefreshIntent=\(diagnostics.lastRefreshIntent ?? "n/a")",
            "lastRefreshStartedAt=\(date(diagnostics.lastRefreshStartedAt))",
            "lastRefreshCompletedAt=\(date(diagnostics.lastRefreshCompletedAt))",
            "lastRefreshDuration=\(duration(diagnostics.lastRefreshDuration))",
            "lastRefreshError=\(redactedDiagnosticText(diagnostics.lastRefreshError))",
            "refreshCountLast12Hours=\(diagnostics.refreshCountLast12Hours)",
            "refreshFailureCountLast12Hours=\(diagnostics.refreshFailureCountLast12Hours)",
            "monthlyBudgetRefreshCountLast12Hours=\(diagnostics.monthlyBudgetRefreshCountLast12Hours)",
            "monthlyBudgetRefreshFailureCountLast12Hours=\(diagnostics.monthlyBudgetRefreshFailureCountLast12Hours)",
            "monthlyBudgetLastRefreshAt=\(date(diagnostics.monthlyBudgetLastRefreshAt))",
            "monthlyBudgetLastRefreshSucceeded=\(diagnostics.monthlyBudgetLastRefreshSucceeded.map(String.init) ?? "n/a")",
            "monthlyBudgetLastRefreshError=\(redactedDiagnosticText(diagnostics.monthlyBudgetLastRefreshError))",
            "monthlyBudgetRefreshInFlight=\(diagnostics.monthlyBudgetRefreshInFlight)",
            "monthlyBudgetRefreshDueAt=\(date(diagnostics.monthlyBudgetRefreshDueAt))",
            "monthlyBudgetRefreshRequested=\(diagnostics.monthlyBudgetRefreshRequested)",
            "monthlyBudgetSnapshotGeneratedAt=\(date(diagnostics.monthlyBudgetSnapshotGeneratedAt))",
            "monthlyBudgetProjectionAvailable=\(diagnostics.monthlyBudgetProjectionAvailable)",
            "monthlyBudgetProjectionDay=\(diagnostics.monthlyBudgetProjectionDay ?? "n/a")",
            "monthlyBudgetProjectedCost=\(diagnostics.monthlyBudgetProjectedCost.map(Currency.format) ?? "n/a")",
            "monthlyBudgetResolution=\(diagnostics.monthlyBudgetResolution ?? "n/a")",
            "pricingUpdatedAt=\(date(diagnostics.pricingUpdatedAt))",
            "pricingAttemptAt=\(date(diagnostics.pricingAttemptAt))"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func redactedDiagnosticText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "n/a" }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let redacted = value
            .replacingOccurrences(of: homePath, with: "~")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if redacted.count <= 240 { return redacted }
        return String(redacted.prefix(240)) + "…"
    }

    func showAbout() {
        let copy = L10n(language: settings.language)
        let window: NSWindow
        if let existing = aboutWindow {
            window = existing
            window.title = copy.aboutWindowTitle
            if let hostingView = existing.contentView as? NSHostingView<AboutView> {
                hostingView.rootView = AboutView(
                    language: settings.language,
                    interfaceTextSize: settings.interfaceTextSize,
                    appearance: settings.appearance,
                    surfaceStyle: settings.surfaceStyle
                )
            }
        } else {
            window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(settings.interfaceTextSize.aboutWindowWidth),
                    height: CGFloat(settings.interfaceTextSize.aboutWindowHeight)
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.aboutWindowTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: AboutView(
                    language: settings.language,
                    interfaceTextSize: settings.interfaceTextSize,
                    appearance: settings.appearance,
                    surfaceStyle: settings.surfaceStyle
                )
            )
            window.center()
            aboutWindow = window
        }

        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.aboutWindowWidth),
            height: CGFloat(settings.interfaceTextSize.aboutWindowHeight)
        ))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showBudgetSettings() {
        let copy = L10n(language: settings.language)
        let rootView = BudgetSettingsView(
            store: self,
            onCancel: { [weak self] in self?.budgetSettingsWindow?.orderOut(nil) },
            onSave: { [weak self] in self?.budgetSettingsWindow?.orderOut(nil) }
        )
        let window: NSWindow
        if let existing = budgetSettingsWindow {
            window = existing
            window.title = copy.budgetSettingsTitle
        } else {
            window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(settings.interfaceTextSize.budgetSettingsWidth),
                    height: CGFloat(settings.interfaceTextSize.budgetSettingsHeight)
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.budgetSettingsTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            budgetSettingsWindow = window
        }

        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.budgetSettingsWidth),
            height: CGFloat(settings.interfaceTextSize.budgetSettingsHeight)
        ))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPluginSettings() {
        let copy = L10n(language: settings.language)
        let rootView = PluginSettingsView(
            store: self,
            onClose: { [weak self] in self?.pluginSettingsWindow?.orderOut(nil) }
        )
        let window: NSWindow
        if let existing = pluginSettingsWindow {
            window = existing
            window.title = copy.pluginSettingsTitle
            if let hostingView = existing.contentView as? NSHostingView<PluginSettingsView> {
                hostingView.rootView = rootView
            }
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.pluginSettingsTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            pluginSettingsWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showModelCatalog() {
        guard !allModelCatalogEntries.isEmpty else { return }
        let copy = L10n(language: settings.language)
        let entries = allModelCatalogEntries
        let window: NSWindow
        if let existing = modelCatalogWindow {
            window = existing
            window.title = copy.modelCatalogTitle
            if let hostingView = existing.contentView as? NSHostingView<ModelCatalogView> {
                hostingView.rootView = ModelCatalogView(
                    entries: entries,
                    language: settings.language,
                    state: modelCatalogViewState,
                    projectionRevision: modelCatalogProjectionRevision,
                    interfaceTextSize: settings.interfaceTextSize,
                    appearance: settings.appearance,
                    surfaceStyle: settings.surfaceStyle
                )
            }
        } else {
            window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(settings.interfaceTextSize.modelCatalogWidth),
                    height: CGFloat(settings.interfaceTextSize.modelCatalogHeight)
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = copy.modelCatalogTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: ModelCatalogView(
                    entries: entries,
                    language: settings.language,
                    state: modelCatalogViewState,
                    projectionRevision: modelCatalogProjectionRevision,
                    interfaceTextSize: settings.interfaceTextSize,
                    appearance: settings.appearance,
                    surfaceStyle: settings.surfaceStyle
                )
            )
            window.center()
            modelCatalogWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseCustomPricing() {
        importCustomPricing(mode: .merge)
    }

    func importCustomPricing(mode: CustomPricingImportMode) {
        guard customPricingPanel == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.presentCustomPricingPanel(mode: mode)
        }
    }

    private func presentCustomPricingPanel(mode: CustomPricingImportMode) {
        guard customPricingPanel == nil else { return }
        let copy = L10n(language: settings.language)
        let panel = NSOpenPanel()
        panel.title = mode == .merge ? copy.importAndMergeCustomPricing : copy.replaceCustomPricing
        panel.message = mode == .merge ? copy.mergeCustomPricingMessage : copy.replaceCustomPricingMessage
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText]
        panel.level = .modalPanel
        customPricingPanel = panel

        // This is an accessory (menu-bar-only) app, so opening an asynchronous
        // panel does not always activate the app or put the panel above the
        // currently active application's windows by itself.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            let url = panel?.url
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.customPricingPanel = nil
                guard response == .OK, let url else { return }
                self.finishImportCustomPricing(mode: mode, url: url)
            }
        }

        // `begin` schedules presentation asynchronously. Reassert the
        // foreground/key-window state on the next run-loop turn so the panel
        // cannot remain behind another app's window after the menu closes.
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private func presentExternalPluginPanel() {
        guard externalPluginRegistry != nil, externalPluginPanel == nil else { return }
        let copy = L10n(language: settings.language)
        let panel = NSOpenPanel()
        panel.title = copy.installExternalPlugin
        panel.message = copy.externalPluginInstallMessage
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.level = .modalPanel
        externalPluginPanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            let url = panel?.url
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.externalPluginPanel = nil
                guard response == .OK, let url else { return }
                self.finishInstallExternalPlugin(from: url)
            }
        }

        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private func finishInstallExternalPlugin(from sourceURL: URL) {
        guard let externalPluginRegistry else { return }
        do {
            let installed = try externalPluginRegistry.install(from: sourceURL)
            didInstallExternalPlugin(installed)
        } catch {
            externalPluginError = error.localizedDescription
            refreshPluginSettingsWindow()
        }
    }

    private func didInstallExternalPlugin(_ installed: ValidatedPluginPackage) {
        externalPluginError = nil
        reloadExternalPlugins(
            replacingIDs: [installed.manifest.id],
            pluginIDsToRefresh: [installed.manifest.id]
        )
    }

    private func finishImportCustomPricing(mode: CustomPricingImportMode, url: URL) {
        let copy = L10n(language: settings.language)
        do {
            let incoming = try CustomPricingTable(contentsOf: url)
            let imported: CustomPricingTable
            switch mode {
            case .merge:
                imported = customPricingTable.merged(with: incoming)
            case .replace:
                imported = incoming
            }

            do {
                let managedURL = Self.managedCustomPricingURL()
                try imported.write(to: managedURL)
                activateCustomPricing(imported, path: managedURL.path)
            } catch {
                logger.error("Could not persist imported price list; falling back to selected file, error=\(error.localizedDescription, privacy: .public)")
                let hadExistingPricing = !customPricingTable.isEmpty
                if mode == .merge, hadExistingPricing {
                    guard confirmMergeFallback(copy: copy) else { return }
                }
                activateCustomPricing(incoming, path: url.path)
                if mode == .replace || !hadExistingPricing {
                    showPricingAlert(title: copy.customPricingImportFallbackTitle, message: copy.customPricingImportFallbackMessage)
                }
            }
        } catch {
            logger.error("Could not import price list; error=\(error.localizedDescription, privacy: .public)")
            showPricingAlert(title: copy.customPricingUnavailable, message: error.localizedDescription)
            return
        }

        beginRefresh(intent: .pricing(fallbackToOffline: true, allowEmptyCandidate: false), bypassInterval: true)
    }

    func exportCustomPricing() {
        let copy = L10n(language: settings.language)
        guard !customPricingTable.isEmpty else {
            showPricingAlert(title: copy.customPricing, message: copy.noCustomPricingToExport)
            return
        }

        let panel = NSSavePanel()
        panel.title = copy.exportCustomPricing
        panel.message = copy.exportCustomPricingMessage
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = copy.customPricingFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try customPricingTable.write(to: url)
        } catch {
            logger.error("Could not export price list; error=\(error.localizedDescription, privacy: .public)")
            showPricingAlert(title: copy.exportCustomPricing, message: error.localizedDescription)
        }
    }

    func removeCustomPricing() {
        settings.customPricingPath = ""
        customPricingTable = .empty
        activeCustomPricingRevision = nil
        activeCustomPricingFileFingerprint = nil
        customPricingModelCount = 0
        customPricingError = nil
        pricingGeneration += 1
        refreshModelCatalogWindow()
        Self.removeManagedCustomPricingArtifact()
        Self.removeManagedCcusagePricingArtifacts(directory: generatedPricingDirectory)
        // Removing a local table changes the pricing source. If a remote model
        // catalog is enabled, fetch its current rates before recalculating so
        // the first replacement snapshot cannot silently use ccusage's market
        // table while the ExampleGateway catalog is still being refreshed.
        refreshModelCatalogIfDue(force: true)
        beginRefresh(intent: .pricing(fallbackToOffline: true, allowEmptyCandidate: false), bypassInterval: true)
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard MonitorSettings.allowedIntervals.contains(interval) else { return }
        settings.refreshInterval = interval
        if watcher?.isRunning != true {
            // A shorter cadence should apply to the next failed-scan retry.
            fallbackCheckFailures = 0
        }
        if isDirty { phase = .waiting }
        // Re-evaluate any one-shot throttle deadline immediately. The old
        // repeating timer would notice this on its next tick; the event-driven
        // path must not leave a deadline based on the previous interval.
        schedulePeriodicCheck(after: 0)
        publishDeveloperDiagnostics()
    }

    func setSourceVerificationMode(_ mode: SourceVerificationMode) {
        guard settings.sourceVerificationMode != mode else { return }
        settings.sourceVerificationMode = mode
        fallbackCheckFailures = 0
        if mode == .periodicFingerprint, !hasFallbackFingerprintBaseline {
            fingerprintCheckRequested = true
        } else if mode == .eventDriven {
            fingerprintCheckRequested = false
        }
        schedulePeriodicCheck(after: 0)
        publishDeveloperDiagnostics()
    }

    func setFingerprintCheckInterval(_ interval: TimeInterval) {
        guard MonitorSettings.isValidFingerprintCheckInterval(interval) else { return }
        settings.fingerprintCheckInterval = interval
        fallbackCheckFailures = 0
        schedulePeriodicCheck(after: 0)
        publishDeveloperDiagnostics()
    }

    func showCustomFingerprintIntervalEditor() {
        let copy = L10n(language: settings.language)
        let alert = NSAlert()
        alert.messageText = copy.customFingerprintInterval
        alert.informativeText = copy.customFingerprintIntervalHelp
        let field = NSTextField(string: String(Int(settings.fingerprintCheckInterval / 60)))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = copy.customFingerprintIntervalPlaceholder
        alert.accessoryView = field
        alert.addButton(withTitle: copy.save)
        alert.addButton(withTitle: copy.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let interval = MonitorSettings.parseFingerprintCheckInterval(field.stringValue) else {
            let invalid = NSAlert()
            invalid.messageText = copy.invalidFingerprintInterval
            invalid.informativeText = copy.customFingerprintIntervalHelp
            invalid.addButton(withTitle: copy.ok)
            invalid.runModal()
            return
        }
        setFingerprintCheckInterval(interval)
    }

    func setLookbackDays(_ days: Int) {
        guard settings.lookbackDays != days else { return }
        settings.lookbackDays = days
        dirtyGeneration += 1
        isDirty = true
        dirtySince = dirtySince ?? currentDate
        phase = .waiting
        // Do not let a report for the previous scope remain visible under the
        // new setting. The private pricing reference is retained for overlap
        // cost preservation while the new query is running.
        snapshot = .empty
        lastSourceEventAt = currentDate
        beginRefresh(
            intent: .pricing(fallbackToOffline: true, allowEmptyCandidate: true),
            bypassInterval: true,
            generation: dirtyGeneration,
        )
    }

    func setLanguage(_ language: AppLanguage) {
        settings.language = language
        pluginHost?.setLanguage(language)
        refreshBudgetSettingsWindow()
        refreshPluginSettingsWindow()
        refreshPluginConfigurationWindow()
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        refreshDeveloperDiagnosticsWindow()
    }

    func setInterfaceTextSize(_ textSize: InterfaceTextSize) {
        settings.interfaceTextSize = textSize
        refreshAboutWindow()
        refreshModelCatalogWindow()
        if let window = modelCatalogWindow {
            window.setContentSize(NSSize(
                width: CGFloat(textSize.modelCatalogWidth),
                height: CGFloat(textSize.modelCatalogHeight)
            ))
        }
        refreshBudgetSettingsWindow()
        refreshPluginSettingsWindow()
        refreshPluginConfigurationWindow()
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        refreshDeveloperDiagnosticsWindow()
    }

    func setBudgetSettings(dailyCostLimit: Double, monthlyCostLimit: Double, budgetAlertThreshold: Double) {
        var updated = settings
        updated.dailyCostLimit = MonitorSettings.validCostLimit(dailyCostLimit)
        updated.monthlyCostLimit = MonitorSettings.validCostLimit(monthlyCostLimit)
        updated.budgetAlertThreshold = MonitorSettings.validBudgetAlertThreshold(budgetAlertThreshold)
        let monthlyLimitChanged = updated.monthlyCostLimit != settings.monthlyCostLimit
        let limitsChanged = updated.dailyCostLimit != settings.dailyCostLimit
            || monthlyLimitChanged
        if settings.monthlyCostLimit <= 0, updated.monthlyCostLimit > 0 {
            // Enabling a monthly limit should populate its data promptly even
            // when the existing snapshot happens to be within the normal
            // reconciliation interval.
            monthlyBudgetRefreshRequested = true
        } else if updated.monthlyCostLimit <= 0 {
            monthlyBudgetRefreshRequested = false
        }
        settings = updated
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        if limitsChanged {
            refreshNow()
        }
    }

    func setAppearance(_ appearance: AppAppearance) {
        settings.appearance = appearance
        refreshAboutWindow()
        refreshModelCatalogWindow()
        refreshBudgetSettingsWindow()
        refreshPluginSettingsWindow()
        refreshPluginConfigurationWindow()
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        refreshDeveloperDiagnosticsWindow()
    }

    func setSurfaceStyle(_ surfaceStyle: AppSurfaceStyle) {
        guard settings.surfaceStyle != surfaceStyle else { return }
        settings.surfaceStyle = surfaceStyle
        refreshAboutWindow()
        refreshModelCatalogWindow()
        refreshBudgetSettingsWindow()
        refreshPluginSettingsWindow()
        refreshPluginConfigurationWindow()
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        refreshDeveloperDiagnosticsWindow()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard settings.launchAtLogin != enabled else { return }

        do {
            let status = try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginStatus = status
            settings.launchAtLogin = enabled
            if enabled, status == .requiresApproval {
                showLaunchAtLoginApprovalAlert()
            }
        } catch {
            launchAtLoginStatus = LaunchAtLoginService.currentStatus()
            logger.error("Could not update launch-at-login setting; enabled=\(enabled, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            let copy = L10n(language: settings.language)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = copy.launchAtLogin
            alert.informativeText = copy.launchAtLoginError(error.localizedDescription)
            alert.addButton(withTitle: copy.ok)
            alert.runModal()
        }
    }

    func markDirty() {
        markDirty(cause: .manual)
    }

    private func markDirty(cause: SourceChangeCause) {
        let wasDirty = isDirty
        if !wasDirty {
            isDirty = true
            dirtySince = currentDate
        }
        dirtyGeneration += 1
        lastSourceEventAt = currentDate
        lastSourceChangeCause = cause
        if pendingRefreshIntent != nil {
            pendingRefreshGeneration = dirtyGeneration
        }
        if pendingForcedUsageRefresh {
            pendingForcedUsageGeneration = dirtyGeneration
        }
        if pricingRefreshInFlight || pendingRefreshIntent?.isPricing == true {
            pendingUsageRefresh = true
        }
        if !wasDirty || phase != .waiting {
            phase = .waiting
            logger.debug("Source marked dirty; generation=\(self.dirtyGeneration, privacy: .public)")
        }
        scheduleSourceSettleCheck()
        publishDeveloperDiagnostics()
    }

    private var canRefreshNow: Bool {
        RefreshSchedule.isUsageRefreshDue(
            lastStartedAt: lastUsageRefreshStartedAt,
            now: currentDate,
            interval: settings.refreshInterval
        )
    }

    private var dirtyWaitHasReachedRefreshInterval: Bool {
        guard let dirtySince,
              settings.refreshInterval.isFinite,
              settings.refreshInterval >= 0 else {
            return false
        }
        return currentDate.timeIntervalSince(dirtySince) >= settings.refreshInterval
    }

    private func startMonitoring() {
        let roots = sourceRootsProvider()
        knownSourceRoots = Set(roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
        installWatcher(for: roots)

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.periodicCheck()
            }
        }

        // A launch is an explicit opportunity to reconcile the cached snapshot.
        markDirty(cause: .launch)
        // Start the fallback path immediately when the watcher could not be
        // installed. Usage still waits for the normal settle window below.
        periodicCheck()
    }

    private func configureDeveloperHealthTimer() {
        developerHealthTimer?.invalidate()
        developerHealthTimer = nil
        guard settings.developerMode else { return }

        developerHealthTimer = Timer.scheduledTimer(
            withTimeInterval: Self.developerHealthProbeInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runDeveloperHealthCheck()
            }
        }
    }

    private func finishDeveloperHealthCheck(
        _ result: Result<[SourceFingerprint], Error>,
        started: Date
    ) {
        developerHealthProbeInFlight = false
        let completedAt = Date()
        lastHealthProbeAt = completedAt
        lastHealthProbeDuration = completedAt.timeIntervalSince(started)

        switch result {
        case let .success(fingerprints):
            let watcherRunning = watcher?.isRunning == true
            let watcherHasPendingReplacement = pendingWatcherRoots != nil
            if let previousFingerprints = developerHealthProbeFingerprints {
                let sourceChanged = previousFingerprints != fingerprints
                let eventsSinceProbe = watcherEventCount - developerHealthProbeEventCount

                if !watcherRunning {
                    watcherState = .down
                    watcherMessage = "FSEventStream is not running"
                } else if watcherHasPendingReplacement {
                    watcherState = .degraded
                    watcherMessage = "A watcher replacement is pending"
                } else if sourceChanged, eventsSinceProbe == 0 {
                    watcherState = .degraded
                    watcherMessage = "Source fingerprint changed without a watcher event"
                    markDirty(cause: .developerHealthProbe)
                } else {
                    watcherState = .running
                    watcherMessage = sourceChanged
                        ? "Source change matched a watcher event"
                        : "No source change detected"
                }
            } else if !watcherRunning {
                watcherState = .down
                watcherMessage = "FSEventStream is not running"
            } else if watcherHasPendingReplacement {
                watcherState = .degraded
                watcherMessage = "A watcher replacement is pending"
            } else {
                watcherState = .running
                watcherMessage = "Baseline fingerprint captured"
            }

            developerHealthProbeFingerprints = fingerprints
            developerHealthProbeEventCount = watcherEventCount
        case let .failure(error):
            watcherState = watcher?.isRunning == true ? .degraded : .down
            watcherMessage = "Health check failed: \(error.localizedDescription)"
            healthProbeMessage = error.localizedDescription
        }

        if case .success = result {
            healthProbeMessage = watcherMessage
        }
        publishDeveloperDiagnostics()
    }

    private func recordRefreshCompletion(
        intent: RefreshIntent,
        started: Date,
        failed: Bool,
        error: String? = nil
    ) {
        let completedAt = currentDate
        lastRefreshCompletedAt = completedAt
        lastRefreshIntent = intent.diagnosticLabel
        lastRefreshDuration = max(0, completedAt.timeIntervalSince(started))
        lastRefreshError = failed ? error : nil
        refreshDiagnosticRecords.append(
            RefreshDiagnosticRecord(completedAt: completedAt, succeeded: !failed)
        )
        pruneDiagnosticRecords(now: completedAt)
        publishDeveloperDiagnostics()
    }

    private func recordMonthlyBudgetRefreshStarted(at startedAt: Date) {
        monthlyBudgetRefreshDates.append(startedAt)
        monthlyBudgetLastRefreshAt = startedAt
        pruneDiagnosticRecords(now: startedAt)
        publishDeveloperDiagnostics()
    }

    private func pruneDiagnosticRecords(now: Date) {
        let cutoff = now.addingTimeInterval(-12 * 60 * 60)
        refreshDiagnosticRecords.removeAll { $0.completedAt < cutoff }
        monthlyBudgetRefreshDates.removeAll { $0 < cutoff }
        monthlyBudgetRefreshFailureDates.removeAll { $0 < cutoff }
    }

    private func publishDeveloperDiagnostics() {
        guard settings.developerMode else { return }
        let now = Date()
        pruneDiagnosticRecords(now: now)
        let phaseLabel: String
        switch phase {
        case .idle: phaseLabel = "idle"
        case .waiting: phaseLabel = "waiting"
        case .refreshing: phaseLabel = "refreshing"
        case .updatingPricing: phaseLabel = "updating pricing"
        case .failed: phaseLabel = "failed"
        }
        let monthlyCostResolution = MonthlyCostResolver.resolve(
            snapshot: snapshot,
            monthlySnapshot: monthlyBudget,
            now: currentDate
        )
        let monthlyBudgetProjectionAvailable: Bool
        let monthlyBudgetProjectionDay: String?
        switch monthlyCostResolution?.source {
        case .liveUsage:
            monthlyBudgetProjectionAvailable = true
            monthlyBudgetProjectionDay = MonthlyBudgetSnapshot.dayPeriod(for: currentDate)
        case .realtimeProjection:
            monthlyBudgetProjectionAvailable = true
            monthlyBudgetProjectionDay = monthlyBudget?.realtimeAnchorDay
        case .calibratedSnapshot, nil:
            monthlyBudgetProjectionAvailable = false
            monthlyBudgetProjectionDay = nil
        }
        developerDiagnostics = DeveloperDiagnosticsSnapshot(
            capturedAt: now,
            watcherState: watcherState,
            watcherStartAttempts: watcherStartAttempts,
            watcherEventCount: watcherEventCount,
            watcherStartedAt: watcherStartedAt,
            watcherLastEventAt: watcherLastEventAt,
            watcherRetryAt: watcherRetryAt,
            watcherMessage: watcherMessage,
            watchedRootCount: knownSourceRoots.count,
            sourceVerificationMode: settings.sourceVerificationMode.rawValue,
            fingerprintCheckInterval: settings.fingerprintCheckInterval,
            lastFingerprintCheckAt: lastFallbackCheckAt,
            nextFingerprintCheckAt: nextFingerprintCheckAt,
            lastFingerprintDetectionAt: lastFingerprintDetectionAt,
            lastSourceChangeCause: lastSourceChangeCause?.rawValue,
            fingerprintCheckOutcome: fingerprintCheckOutcome,
            fingerprintCheckPending: fingerprintCheckPending,
            fallbackScanCount: fallbackScanCount,
            lastFallbackScanAt: lastFallbackCheckAt,
            lastFallbackScanDuration: lastFallbackScanDuration,
            fallbackFailureCount: fallbackCheckFailures,
            fallbackScanInFlight: fallbackCheckInFlight,
            healthProbeCount: healthProbeCount,
            lastHealthProbeAt: lastHealthProbeAt,
            lastHealthProbeDuration: lastHealthProbeDuration,
            healthProbeMessage: healthProbeMessage,
            healthProbeInFlight: developerHealthProbeInFlight,
            isDirty: isDirty,
            dirtyGeneration: dirtyGeneration,
            phase: phaseLabel,
            lastSourceEventAt: lastSourceEventAt,
            scheduledCheckAt: scheduledCheckAt,
            watchdogInterval: Self.watchdogInterval,
            sourceSettleInterval: Self.sourceSettleInterval,
            refreshInterval: settings.refreshInterval,
            lastRefreshIntent: lastRefreshIntent,
            lastRefreshStartedAt: lastRefreshStartedAt,
            lastRefreshCompletedAt: lastRefreshCompletedAt,
            lastRefreshDuration: lastRefreshDuration,
            lastRefreshError: lastRefreshError,
            refreshCountLast12Hours: refreshDiagnosticRecords.count,
            refreshFailureCountLast12Hours: refreshDiagnosticRecords.filter { !$0.succeeded }.count,
            monthlyBudgetRefreshCountLast12Hours: monthlyBudgetRefreshDates.count,
            monthlyBudgetRefreshFailureCountLast12Hours: monthlyBudgetRefreshFailureDates.count,
            monthlyBudgetLastRefreshAt: monthlyBudgetLastRefreshAt,
            monthlyBudgetLastRefreshSucceeded: monthlyBudgetLastRefreshSucceeded,
            monthlyBudgetLastRefreshError: monthlyBudgetLastRefreshError,
            monthlyBudgetRefreshInFlight: monthlyBudgetRefreshInFlight,
            monthlyBudgetRefreshDueAt: monthlyBudgetRefreshDueAt,
            monthlyBudgetRefreshRequested: monthlyBudgetRefreshRequested,
            monthlyBudgetSnapshotGeneratedAt: monthlyBudget?.generatedAt,
            monthlyBudgetProjectionAvailable: monthlyBudgetProjectionAvailable,
            monthlyBudgetProjectionDay: monthlyBudgetProjectionDay,
            monthlyBudgetProjectedCost: monthlyCostResolution?.cost,
            monthlyBudgetResolution: monthlyCostResolution?.source.diagnosticLabel,
            pricingUpdatedAt: snapshot.pricingUpdatedAt,
            pricingAttemptAt: settingsStore.lastPricingAttemptAt(),
            appVersion: AppMetadata.version,
            appBuild: AppMetadata.build,
            bundledCCUsageVersion: AppMetadata.bundledCCUsageVersion
        )
    }

    /// Schedules the earliest pending maintenance or refresh check. The
    /// watchdog remains as a safety net, while source events and throttled
    /// refreshes use this one-shot path to avoid periodic 5-second wakeups.
    private func schedulePeriodicCheck(after delay: TimeInterval) {
        // The testing seam drives the scheduler explicitly with a fake clock;
        // do not create real timers from those deterministic checks.
        guard testingNow == nil else { return }
        // A source storm can repeatedly request an already-due check. Keep a
        // quarter-second floor so the scheduler itself cannot become a tight
        // wakeup loop while the two-second settle window is still open.
        let normalizedDelay = max(delay, 0.25)
        let requestedAt = Date().addingTimeInterval(normalizedDelay)
        if let scheduledCheckAt, scheduledCheckAt <= requestedAt {
            return
        }

        scheduledCheckTimer?.invalidate()
        scheduledCheckAt = requestedAt
        publishDeveloperDiagnostics()
        scheduledCheckTimer = Timer.scheduledTimer(withTimeInterval: normalizedDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledCheckTimer = nil
                self.scheduledCheckAt = nil
                self.publishDeveloperDiagnostics()
                self.periodicCheck()
            }
        }
    }

    private func scheduleSourceSettleCheck() {
        guard let lastSourceEventAt else { return }
        let remaining = Self.sourceSettleInterval - currentDate.timeIntervalSince(lastSourceEventAt)
        schedulePeriodicCheck(after: max(remaining, 0.05))
    }

    private func scheduleUsageRefreshCheck() {
        guard isDirty, let lastUsageRefreshStartedAt else { return }
        let remaining = settings.refreshInterval - currentDate.timeIntervalSince(lastUsageRefreshStartedAt)
        schedulePeriodicCheck(after: max(remaining, 0.05))
    }

    private func scheduleFallbackCheck() {
        guard fingerprintCheckSchedulingEnabled,
              !fallbackCheckInFlight,
              !monthlyBudgetRefreshInFlight else {
            return
        }

        var deadlines: [Date] = []
        if let watcherRetryAt, watcherRetryAt > currentDate {
            deadlines.append(watcherRetryAt)
        }
        if let lastFallbackCheckAt {
            let interval = fallbackCheckFailures > 0
                ? RefreshSchedule.fallbackRetryDelay(refreshInterval: activeFingerprintCheckInterval)
                : activeFingerprintCheckInterval
            guard interval.isFinite, interval >= 0 else { return }
            deadlines.append(lastFallbackCheckAt.addingTimeInterval(interval))
        }
        guard let nextDeadline = deadlines.min() else {
            // No completed scan exists yet. The current periodic pass will
            // start the initial fallback scan immediately unless monthly work
            // is holding the maintenance gate.
            return
        }
        schedulePeriodicCheck(after: max(nextDeadline.timeIntervalSince(currentDate), 0.05))
    }

    private var currentMonthlyBudgetRefreshKey: MonthlyBudgetRefreshKey {
        MonthlyBudgetRefreshKey(
            month: MonthlyBudgetSnapshot.monthPeriod(for: currentDate),
            day: MonthlyBudgetSnapshot.dayPeriod(for: currentDate),
            customPricingRevision: activeCustomPricingRevision,
            modelCatalogRevision: activeModelCatalogRevision,
            pricingUpdatedAt: pricingReferenceSnapshot.pricingUpdatedAt
        )
    }

    private var hasCurrentMonthlyBudgetSnapshot: Bool {
        let key = currentMonthlyBudgetRefreshKey
        guard let monthlyBudget else { return false }
        return monthlyBudget.month == key.month
            && monthlyBudget.realtimeAnchorDay == key.day
            && monthlyBudget.customPricingRevision == key.customPricingRevision
            && monthlyBudget.modelCatalogRevision == key.modelCatalogRevision
            && monthlyBudget.pricingUpdatedAt == key.pricingUpdatedAt
            && !monthlyBudget.pricingBasisPreserved
            && monthlyBudget.hasRealtimeProjection
            && monthlyBudget.hasData
    }

    private var monthlyBudgetRefreshDueAt: Date? {
        guard settings.monthlyCostLimit > 0 else { return nil }
        if monthlyBudgetRefreshRequested {
            return currentDate
        }
        let key = currentMonthlyBudgetRefreshKey
        if let attemptAt = lastMonthlyBudgetRefreshAttemptAt,
           lastMonthlyBudgetRefreshAttemptKey == key {
            let interval = lastMonthlyBudgetRefreshAttemptSucceeded
                ? Self.monthlyBudgetRefreshInterval
                : Self.monthlyBudgetRefreshRetryInterval
            return attemptAt.addingTimeInterval(interval)
        }
        if monthlyBudgetRefreshRequested || !hasCurrentMonthlyBudgetSnapshot {
            return currentDate
        }
        return monthlyBudget?.generatedAt.addingTimeInterval(Self.monthlyBudgetRefreshInterval)
    }

    private var monthlyBudgetRefreshIsDue: Bool {
        guard let dueAt = monthlyBudgetRefreshDueAt else { return false }
        return currentDate >= dueAt
    }

    private func scheduleMonthlyBudgetCheck() {
        guard settings.monthlyCostLimit > 0,
              !refreshInFlight,
              !pricingRefreshInFlight,
              !monthlyBudgetRefreshInFlight,
              !fallbackCheckInFlight,
              let dueAt = monthlyBudgetRefreshDueAt else {
            return
        }
        let dirtyWaitDeadline: Date?
        if isDirty, let dirtySince {
            dirtyWaitDeadline = dirtySince.addingTimeInterval(Self.monthlyBudgetMaxDirtyWaitInterval)
        } else {
            dirtyWaitDeadline = nil
        }
        let nextDeadline = max(dueAt, dirtyWaitDeadline ?? dueAt)
        schedulePeriodicCheck(after: max(nextDeadline.timeIntervalSince(currentDate), 0.05))
    }

    private var monthlyBudgetRefreshMayRunWhileDirty: Bool {
        guard isDirty else { return true }
        guard let dirtySince else { return false }
        return currentDate.timeIntervalSince(dirtySince) >= Self.monthlyBudgetMaxDirtyWaitInterval
    }

    private func beginMonthlyBudgetRefresh() {
        guard settings.monthlyCostLimit > 0,
              monthlyBudgetRefreshIsDue,
              !refreshInFlight,
              !pricingRefreshInFlight,
              !monthlyBudgetRefreshInFlight,
              !fallbackCheckInFlight else {
            return
        }

        let started = currentDate
        let key = currentMonthlyBudgetRefreshKey
        monthlyBudgetRefreshInFlight = true
        // Enabling the budget creates a one-shot immediate request. Consume
        // it when the attempt starts so a failed attempt can use the normal
        // retry interval instead of spinning immediately.
        monthlyBudgetRefreshRequested = false
        lastMonthlyBudgetRefreshAttemptAt = started
        lastMonthlyBudgetRefreshAttemptKey = key
        lastMonthlyBudgetRefreshAttemptSucceeded = false
        recordMonthlyBudgetRefreshStarted(at: started)
        publishDeveloperDiagnostics()

        let currentSettings = settings
        let currentRunner = runner
        let previousPricingDate = pricingReferenceSnapshot.pricingUpdatedAt
        let pricingBasis = PricingExecutionBasis(
            customTable: customPricingTable,
            remoteCatalogEntries: activeModelCatalogEntries,
            modelCatalogRevision: activeModelCatalogRevision
        )
        let currentCustomPricing = pricingBasis.customTable
        let currentModelCatalogRevision = pricingBasis.modelCatalogRevision
        let pricingGenerationAtStart = pricingGeneration
        let dirtyGenerationAtStart = dirtyGeneration
        let startedWhileDirty = isDirty
        let pricingConfigURL = Self.managedCcusagePricingURL(
            for: pricingGenerationAtStart,
            directory: generatedPricingDirectory
        )
        let pricingIdentity = PricingExecutionIdentity(
            generation: pricingGenerationAtStart,
            revision: currentCustomPricing.revision,
            modelCatalogRevision: currentModelCatalogRevision,
            artifactURL: pricingConfigURL
        )
        let refreshLogger = logger

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let preparation: CcusagePricingPreparation
                let configURL: URL?
                if pricingBasis.composition.catalog.models.isEmpty {
                    preparation = .empty
                    configURL = nil
                } else {
                    preparation = try CcusagePricingAdapter.bundledV20.prepare(
                        composition: pricingBasis.composition,
                        writeTo: pricingConfigURL
                    )
                    configURL = preparation.hasOverrides ? pricingConfigURL : nil
                    if !preparation.diagnostics.isEmpty {
                        refreshLogger.warning(
                            "Applied approximate custom tier mapping to monthly budget; models=\(preparation.approximateModelNames.count, privacy: .public), diagnostics=\(preparation.diagnostics.count, privacy: .public)"
                        )
                    }
                }
                let monthlyResult = try currentRunner.runMonthlyBudgetWithPricingContext(
                    settings: currentSettings,
                    mode: .usage,
                    previousPricingDate: previousPricingDate,
                    pricingConfigURL: configURL,
                    customPricingRevision: currentCustomPricing.revision,
                    now: started,
                    pricingContext: PricingResolutionContext(
                        basis: pricingBasis,
                        preparation: preparation
                    )
                )
                Task { @MainActor [weak self] in
                    self?.finishMonthlyBudgetRefresh(
                        monthlyResult.snapshot,
                        pricingAssessment: monthlyResult.pricingAssessment,
                        key: key,
                        pricingIdentity: pricingIdentity,
                        dirtyGenerationAtStart: dirtyGenerationAtStart,
                        startedWhileDirty: startedWhileDirty
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.failMonthlyBudgetRefresh(
                        error,
                        key: key,
                        pricingIdentity: pricingIdentity
                    )
                }
            }
        }
    }

    private func finishMonthlyBudgetRefresh(
        _ candidate: MonthlyBudgetSnapshot,
        pricingAssessment: PricingAssessmentContext,
        key: MonthlyBudgetRefreshKey,
        pricingIdentity: PricingExecutionIdentity,
        dirtyGenerationAtStart: Int,
        startedWhileDirty: Bool
    ) {
        monthlyBudgetRefreshInFlight = false
        let executionStillCurrent = currentMonthlyBudgetRefreshKey == key
            && isPricingExecutionCurrent(pricingIdentity)
            && settings.monthlyCostLimit > 0
        let sourceChangedDuringRefresh = dirtyGeneration != dirtyGenerationAtStart
        let sourceResultIsAcceptable = !sourceChangedDuringRefresh || startedWhileDirty
        let candidateMatchesCurrentKey = candidate.month == key.month
            && candidate.customPricingRevision == key.customPricingRevision
            && candidate.modelCatalogRevision == key.modelCatalogRevision
            && candidate.pricingUpdatedAt == key.pricingUpdatedAt
        guard executionStillCurrent && sourceResultIsAcceptable && candidateMatchesCurrentKey else {
            if !isPricingExecutionCurrent(pricingIdentity) {
                Self.removeManagedCcusagePricingArtifact(
                    at: pricingIdentity.artifactURL,
                    directory: generatedPricingDirectory
                )
            } else if !sourceResultIsAcceptable {
                // A source event superseded this point-in-time monthly scan.
                // It is stale work, not a failed monthly reconciliation: do
                // not add a failure/backoff entry or overwrite the last
                // successful diagnostic state. Request a new scan after the
                // normal dirty-settle gate.
                monthlyBudgetRefreshRequested = settings.monthlyCostLimit > 0
                lastMonthlyBudgetRefreshAttemptAt = nil
                lastMonthlyBudgetRefreshAttemptKey = nil
                lastMonthlyBudgetRefreshAttemptSucceeded = false
                phase = .waiting
                publishDeveloperDiagnostics()
                if drainPendingRefresh() { return }
                periodicCheck()
                return
            }
            if executionStillCurrent {
                // The runner returned a result for the wrong month/revision
                // even though the request itself is still current. Treat it
                // like a failed attempt and back off; otherwise a malformed
                // or stale backend result can create a tight monthly loop.
                lastMonthlyBudgetRefreshAttemptAt = currentDate
                lastMonthlyBudgetRefreshAttemptKey = key
                lastMonthlyBudgetRefreshAttemptSucceeded = false
                monthlyBudgetRefreshFailureDates.append(currentDate)
                monthlyBudgetLastRefreshSucceeded = false
                monthlyBudgetLastRefreshError = "Monthly budget candidate does not match the current scope"
                logger.warning(
                    "Monthly budget candidate rejected; expectedMonth=\(key.month, privacy: .public), candidateMonth=\(candidate.month, privacy: .public)"
                )
            } else {
                monthlyBudgetRefreshRequested = settings.monthlyCostLimit > 0
                lastMonthlyBudgetRefreshAttemptAt = nil
                lastMonthlyBudgetRefreshAttemptKey = nil
                lastMonthlyBudgetRefreshAttemptSucceeded = false
            }
            if drainPendingRefresh() { return }
            periodicCheck()
            return
        }

        // An ambiguous or incomplete remote record is a catalog gap, not a
        // valid zero-cost monthly result. Keep the last trusted calibration
        // visible, persist the explicit preservation marker, and use the
        // normal failure backoff. The marker also invalidates the realtime
        // projection path until a fresh catalog-backed reconciliation wins.
        if pricingAssessment.hasCatalogGap,
           let previous = monthlyBudget,
           previous.month == key.month,
           previous.hasData {
            let preserved = previous.markingPricingBasisPreserved()
            do {
                try budgetSnapshotStore.save(preserved)
                monthlyBudget = preserved
                lastMonthlyBudgetRefreshAttemptSucceeded = false
                monthlyBudgetRefreshRequested = false
                monthlyBudgetRefreshFailureDates.append(currentDate)
                monthlyBudgetLastRefreshSucceeded = false
                monthlyBudgetLastRefreshError = "Monthly budget retained while the model catalog has an unresolved price"
                logger.warning(
                    "Monthly budget retained after catalog gap; month=\(previous.month, privacy: .public), models=\(pricingAssessment.catalogGapModelKeys.count, privacy: .public)"
                )
            } catch {
                lastMonthlyBudgetRefreshAttemptSucceeded = false
                monthlyBudgetRefreshFailureDates.append(currentDate)
                monthlyBudgetLastRefreshSucceeded = false
                monthlyBudgetLastRefreshError = error.localizedDescription
                logger.error("Could not save preserved monthly budget snapshot; error=\(error.localizedDescription, privacy: .public)")
            }
            publishDeveloperDiagnostics()
            if drainPendingRefresh() { return }
            periodicCheck()
            return
        }

        do {
            if candidate.hasData {
                try budgetSnapshotStore.save(candidate)
                monthlyBudget = candidate
                monthlyBudgetRefreshRequested = false
                lastMonthlyBudgetRefreshAttemptSucceeded = true
                monthlyBudgetLastRefreshSucceeded = true
                monthlyBudgetLastRefreshError = nil
                logger.info(
                    "Monthly budget refresh succeeded; month=\(candidate.month, privacy: .public), cost=\(candidate.estimatedCost, privacy: .public), realtimeProjection=\(candidate.hasRealtimeProjection, privacy: .public), sourceChangedDuringRefresh=\(sourceChangedDuringRefresh, privacy: .public)"
                )
            } else {
                // An empty result is a valid no-data snapshot, but it is not a
                // successful reconciliation. Keep the previous snapshot in
                // memory and on disk, then retry on the short backoff so a
                // transient empty response cannot hide known monthly usage or
                // turn it into a misleading zero for the full one-hour
                // success interval.
                lastMonthlyBudgetRefreshAttemptSucceeded = false
                monthlyBudgetRefreshFailureDates.append(currentDate)
                monthlyBudgetLastRefreshSucceeded = false
                monthlyBudgetLastRefreshError = "Monthly budget returned no usage data"
                logger.warning(
                    "Monthly budget refresh returned no usage data; retrying with backoff, month=\(candidate.month, privacy: .public)"
                )
            }
        } catch {
            lastMonthlyBudgetRefreshAttemptSucceeded = false
            monthlyBudgetRefreshFailureDates.append(currentDate)
            monthlyBudgetLastRefreshSucceeded = false
            monthlyBudgetLastRefreshError = error.localizedDescription
            logger.error("Could not save monthly budget snapshot; error=\(error.localizedDescription, privacy: .public)")
        }
        publishDeveloperDiagnostics()
        if drainPendingRefresh() { return }
        periodicCheck()
    }

    private func failMonthlyBudgetRefresh(
        _ error: Error,
        key: MonthlyBudgetRefreshKey,
        pricingIdentity: PricingExecutionIdentity
    ) {
        monthlyBudgetRefreshInFlight = false
        guard currentMonthlyBudgetRefreshKey == key,
              isPricingExecutionCurrent(pricingIdentity) else {
            if !isPricingExecutionCurrent(pricingIdentity) {
                Self.removeManagedCcusagePricingArtifact(
                    at: pricingIdentity.artifactURL,
                    directory: generatedPricingDirectory
                )
            }
            monthlyBudgetRefreshRequested = settings.monthlyCostLimit > 0
            lastMonthlyBudgetRefreshAttemptAt = nil
            lastMonthlyBudgetRefreshAttemptKey = nil
            lastMonthlyBudgetRefreshAttemptSucceeded = false
            if drainPendingRefresh() { return }
            periodicCheck()
            return
        }
        lastMonthlyBudgetRefreshAttemptSucceeded = false
        monthlyBudgetRefreshFailureDates.append(currentDate)
        monthlyBudgetLastRefreshSucceeded = false
        monthlyBudgetLastRefreshError = error.localizedDescription
        logger.warning("Monthly budget refresh failed; retrying with backoff, error=\(error.localizedDescription, privacy: .public)")
        publishDeveloperDiagnostics()
        if drainPendingRefresh() { return }
        periodicCheck()
    }

    private func reconcileLaunchAtLogin() {
        let enabled = settings.launchAtLogin
        do {
            launchAtLoginStatus = try LaunchAtLoginService.setEnabled(enabled)
        } catch {
            launchAtLoginStatus = LaunchAtLoginService.currentStatus()
            logger.error("Could not reconcile launch-at-login setting; enabled=\(enabled, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func showLaunchAtLoginApprovalAlert() {
        let copy = L10n(language: settings.language)
        let alert = NSAlert()
        alert.messageText = copy.launchAtLoginApprovalTitle
        alert.informativeText = copy.launchAtLoginApprovalMessage
        alert.addButton(withTitle: copy.openLoginItems)
        alert.addButton(withTitle: copy.cancel)
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func installWatcher(for roots: [URL]) {
        let existing = watcher
        let filteredRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let eventGate = SourceEventGate { [weak self] callbackCount, completion in
            Task { @MainActor [weak self] in
                self?.handleWatcherEvent(callbackCount: callbackCount)
                completion()
            }
        }
        let created = watcherFactory(filteredRoots) { [eventGate] in
            eventGate.submit()
        }
        watcherStartAttempts += 1
        created.start()
        if created.isRunning || existing?.isRunning != true {
            watcher = created
            if let existing, existing !== created {
                existing.stop()
            }
            if created.isRunning {
                pendingWatcherRoots = nil
                watcherRetryAt = nil
                watcherState = .running
                watcherStartedAt = currentDate
                watcherMessage = "FSEventStream is running"
            } else {
                pendingWatcherRoots = filteredRoots
                watcherRetryAt = currentDate.addingTimeInterval(
                    RefreshSchedule.fallbackRetryDelay(refreshInterval: settings.refreshInterval)
                )
                watcherState = .down
                watcherMessage = "FSEventStream failed to start"
            }
        } else {
            // A failed replacement must not take down a healthy watcher.
            created.stop()
            pendingWatcherRoots = filteredRoots
            watcherRetryAt = currentDate.addingTimeInterval(
                RefreshSchedule.fallbackRetryDelay(refreshInterval: settings.refreshInterval)
            )
            watcherState = .degraded
            watcherMessage = "A watcher replacement failed; keeping the existing watcher"
        }
        publishDeveloperDiagnostics()
    }

    private func handleWatcherEvent(callbackCount: Int = 1) {
        watcherEventCount += callbackCount
        watcherLastEventAt = currentDate
        if watcher?.isRunning == true, pendingWatcherRoots == nil {
            watcherState = .running
            watcherMessage = "Watcher delivered an event"
        }
        markDirty(cause: .watcherEvent)
        publishDeveloperDiagnostics()
    }

    /// Retries a failed watcher install. A brand-new stream avoids wedged
    /// FSEventStreamStart calls on a partially initialized stream.
    private func reinstallWatcher() {
        guard watcher?.isRunning != true else { return }
        let roots = sourceRootsProvider()
        knownSourceRoots = Set(roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
        installWatcher(for: roots)
    }

    private func periodicCheck() {
        if snapshot.hasData,
           let savedScope = snapshot.queryScope,
           savedScope != currentQueryScope {
            markScopeRollover()
            if refreshInFlight || pricingRefreshInFlight || monthlyBudgetRefreshInFlight {
                // A scope rollover is an explicit correctness boundary. Keep
                // it as a forced request while the current operation drains;
                // ordinary file changes are handled by the deferred path
                // below when an in-flight refresh completes.
                queueRefresh(intent: .usage, generation: dirtyGeneration)
            }
            logger.debug("Query scope rolled over; scheduling a fresh snapshot, generation=\(self.dirtyGeneration, privacy: .public)")
        }
        let roots = sourceRootsProvider()
        let currentSourceRoots = Set(roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
        if currentSourceRoots != knownSourceRoots {
            knownSourceRoots = currentSourceRoots
            sourceRootGeneration += 1
            installWatcher(for: roots)
            markDirty(cause: .sourceRoot)
        } else if let pendingWatcherRoots,
                  watcherRetryAt.map({ currentDate >= $0 }) ?? true {
            installWatcher(for: pendingWatcherRoots)
        }
        if watcher?.isRunning != true {
            // A stream can stop receiving complete events after a dropped or
            // wrapped event ID while its opaque pointer is still allocated.
            // Treat that state like a failed install so the next scheduler
            // pass creates a fresh stream and the fallback scan covers the
            // gap.
            if pendingWatcherRoots == nil {
                pendingWatcherRoots = roots
                watcherRetryAt = currentDate
            }
            watcherState = .down
            if watcherMessage == nil || watcherMessage == "FSEventStream is running" {
                watcherMessage = "FSEventStream is not running"
            }
        } else if pendingWatcherRoots != nil {
            watcherState = .degraded
        } else if watcherState == .unknown || watcherState == .down {
            watcherState = .running
            watcherMessage = "FSEventStream is running"
        }
        if fingerprintCheckSchedulingEnabled {
            if !fallbackCheckInFlight,
               !monthlyBudgetRefreshInFlight,
               fallbackCheckIsDue {
                runFallbackFingerprintCheck()
            } else if !fallbackCheckInFlight {
                scheduleFallbackCheck()
            }
        }
        let hasSettled = lastSourceEventAt.map {
            currentDate.timeIntervalSince($0) >= Self.sourceSettleInterval
        } ?? true
        // Debounce ordinary bursts, but do not let a never-ending stream of
        // source events starve usage forever. The generation check in
        // finishRefresh still discards a result if another event arrives
        // during the scan; the configured interval bounds how often such a
        // storm can start another attempt.
        let sourceRefreshReady = hasSettled || dirtyWaitHasReachedRefreshInterval
        if isDirty,
           sourceRefreshReady,
           canRefreshNow,
           !refreshInFlight,
           !pricingRefreshInFlight,
           !monthlyBudgetRefreshInFlight {
            beginRefresh(intent: .usage, bypassInterval: false, generation: dirtyGeneration)
        } else if isDirty, !sourceRefreshReady {
            scheduleSourceSettleCheck()
        } else if isDirty, !canRefreshNow {
            scheduleUsageRefreshCheck()
        }
        // Model catalog refreshes are the source of the remote pricing basis.
        // Start that low-frequency work before deciding whether pricing is due;
        // otherwise a coincident deadline prices once with the old catalog and
        // immediately prices again after the new revision is committed.
        refreshPluginsIfDue()
        if !pricingRefreshInFlight {
            refreshModelCatalogIfDue()
        }
        scheduleModelCatalogCheck()

        if !isDirty,
           settings.automaticPricingRefresh,
           pricingIsDue,
           !refreshInFlight,
           !pricingRefreshInFlight,
           !monthlyBudgetRefreshInFlight,
           modelCatalogRefreshTask == nil {
            beginRefresh(
                intent: .pricing(fallbackToOffline: false, allowEmptyCandidate: false),
                bypassInterval: true,
                generation: dirtyGeneration
            )
        }
        // A monthly scan is an expensive full-history reconciliation. Normally
        // wait for the source to become clean; after the bounded dirty wait,
        // accept one point-in-time full scan so a permanent storm or repeated
        // usage failures cannot starve calibration forever. The realtime
        // projection keeps the baseline useful while the usage path catches up.
        if monthlyBudgetRefreshMayRunWhileDirty,
           monthlyBudgetRefreshIsDue,
           !refreshInFlight,
           !pricingRefreshInFlight,
           !monthlyBudgetRefreshInFlight,
           !fallbackCheckInFlight {
            beginMonthlyBudgetRefresh()
        } else if settings.monthlyCostLimit > 0,
                  !refreshInFlight,
                  !pricingRefreshInFlight,
                  !monthlyBudgetRefreshInFlight,
                  !fallbackCheckInFlight {
            scheduleMonthlyBudgetCheck()
        }
        publishDeveloperDiagnostics()
    }

    private func markScopeRollover() {
        dirtyGeneration += 1
        dirtySince = dirtySince ?? currentDate
        isDirty = true
        phase = .waiting
        snapshot = .empty
        lastSourceEventAt = currentDate
        lastSourceChangeCause = .queryScope
        // A queued explicit request must target the new calendar scope, not
        // the generation that was current before the rollover was observed.
        if pendingRefreshIntent != nil {
            pendingRefreshGeneration = dirtyGeneration
        }
        if pendingForcedUsageRefresh {
            pendingForcedUsageGeneration = dirtyGeneration
        }
    }

    /// Test seam: drives the periodic scheduler with a fixed clock instead of
    /// `Date()`, so fallback/backoff timing can be asserted deterministically.
    func periodicCheckForTesting(now: Date) {
        testingNow = now
        periodicCheck()
        testingNow = nil
    }

    /// Test seam: replaces the active catalog providers while a refresh may be
    /// in flight, matching an external-plugin generation change.
    func replaceModelCatalogProvidersForTesting(_ providers: [any ModelCatalogPluginProvider]) {
        invalidateModelCatalogRefreshTask()
        modelCatalogProviders = providers
        modelCatalogProviderGeneration += 1
        refreshModelCatalogIfDue(force: true)
    }

    var lastFallbackCheckAtForTesting: Date? { lastFallbackCheckAt }
    var fallbackCheckFailuresForTesting: Int { fallbackCheckFailures }
    var refreshInFlightForTesting: Bool { refreshInFlight }
    var monthlyBudgetRefreshInFlightForTesting: Bool { monthlyBudgetRefreshInFlight }
    func setRunnerForTesting(_ runner: CCUsageRunnerProtocol) {
        self.runner = runner
    }
    var pricingRefreshInFlightForTesting: Bool { pricingRefreshInFlight }
    var lastFallbackFingerprintsForTesting: [SourceFingerprint] { lastFallbackFingerprints }
    var hasFallbackFingerprintBaselineForTesting: Bool { hasFallbackFingerprintBaseline }
    var fallbackCheckInFlightForTesting: Bool { fallbackCheckInFlight }
    var fallbackScanCountForTesting: Int { fallbackScanCount }
    var fingerprintCheckRequestedForTesting: Bool { fingerprintCheckRequested }
    var fingerprintCheckOutcomeForTesting: String? { fingerprintCheckOutcome }
    var lastFingerprintDetectionAtForTesting: Date? { lastFingerprintDetectionAt }
    var dirtyGenerationForTesting: Int { dirtyGeneration }
    var lastSourceChangeCauseForTesting: String? { lastSourceChangeCause?.rawValue }
    var watcherEventCountForTesting: Int { watcherEventCount }
    var lastRefreshStartedAtForTesting: Date? { lastRefreshStartedAt }

    private var currentDate: Date { testingNow ?? nowProvider() }

    private var pricingRefreshInterval: TimeInterval {
        MonitorSettings.validatedPricingRefreshHours(settings.pricingRefreshHours) * 3600
    }

    private func reloadExternalPlugins(
        replacingIDs: Set<String> = [],
        pluginIDsToRefresh: Set<String> = [],
        forceModelCatalogRefresh: Bool = true
    ) {
        guard let externalPluginRegistry else { return }

        let discovery = externalPluginRegistry.discoverResult()
        externalPlugins = discovery.plugins
        externalPluginIssues = discovery.issues
        if let pluginHost {
            let providers = DashboardPluginProviderSelection.merging(
                base: basePluginProviders,
                external: externalPluginRegistry.enabledProviders(for: discovery.plugins)
            )
            pluginHost.replaceProviders(providers, replacingIDs: replacingIDs)
            pluginStates = pluginHost.snapshots
        }
        invalidateModelCatalogRefreshTask()
        modelCatalogProviders = ModelCatalogProviderSelection.merging(
            base: baseModelCatalogProviders,
            external: externalPluginRegistry.enabledModelCatalogProviders(for: discovery.plugins)
        )
        modelCatalogProviderGeneration += 1
        publishActiveModelCatalogProjection()
        refreshPluginSettingsWindow()
        refreshPluginConfigurationWindow()
        refreshDashboardLayoutSettingsWindow()
        refreshDashboardPreviewWindow()
        refreshPluginIDs(pluginIDsToRefresh)
        refreshModelCatalogIfDue(force: forceModelCatalogRefresh)
    }

    private func refreshPluginIDs(_ pluginIDs: Set<String>) {
        guard !pluginIDs.isEmpty else { return }
        let now = currentDate
        lastPluginRefreshStartedAt = now
        for pluginID in pluginIDs.sorted() {
            pluginHost?.refresh(pluginID: pluginID, now: now)
        }
    }

    private func refreshPluginsIfDue(force: Bool = false) {
        guard pluginHost != nil else { return }
        guard force || RefreshSchedule.isUsageRefreshDue(
            lastStartedAt: lastPluginRefreshStartedAt,
            now: currentDate,
            interval: settings.refreshInterval
        ) else {
            return
        }
        lastPluginRefreshStartedAt = currentDate
        pluginHost?.refreshAll(now: currentDate)
    }

    private func refreshModelCatalogIfDue(force: Bool = false) {
        guard !modelCatalogProviders.isEmpty,
              modelCatalogRefreshTask == nil else { return }
        guard force || settings.automaticPricingRefresh else { return }
        let interval = pricingRefreshInterval
        let activeProviderIDs = activeModelCatalogProviderIDs
        let hasUninitializedProvider = modelCatalogStore.hasUninitializedProvider(for: activeProviderIDs)
        guard force || hasUninitializedProvider || RefreshSchedule.isPricingRefreshDue(
            lastSuccessfulAt: modelCatalogStore.lastSuccessAt(for: activeProviderIDs),
            lastAttemptAt: modelCatalogStore.lastAttemptAt(for: activeProviderIDs),
            now: currentDate,
            interval: interval
        ) else {
            return
        }

        let startedAt = currentDate
        lastModelCatalogRefreshStartedAt = startedAt
        let providers = modelCatalogProviders
        let providerGeneration = modelCatalogProviderGeneration
        modelCatalogRefreshRequestID += 1
        let requestID = modelCatalogRefreshRequestID
        let providerTimeout = modelCatalogProviderTimeout
        // `modelCatalogStatus` is the already-published projection. Reusing
        // it here keeps the refresh coordinator from re-projecting and
        // sorting the entire catalog on the main actor just to show loading.
        let previousStatus = modelCatalogStatus
        modelCatalogStatus = ModelCatalogStatus(
            phase: .loading,
            providerCount: providers.count,
            recordCount: previousStatus.recordCount,
            lastSuccessAt: previousStatus.lastSuccessAt,
            lastError: previousStatus.lastError,
            revision: previousStatus.revision
        )
        modelCatalogRefreshTask = Task { @MainActor [weak self] in
            // Do not retain the whole MonitorStore while an out-of-contract
            // provider ignores cancellation. The store is only retained for
            // the short main-actor commit windows below.
            let outcomes = await ModelCatalogFetchBatch.fetch(
                providers: providers,
                providerTimeout: providerTimeout
            )
            guard let self else { return }
            guard self.modelCatalogRefreshRequestID == requestID else {
                self.discardInvalidatedModelCatalogRefresh(
                    requestID: requestID,
                    providerGeneration: providerGeneration
                )
                return
            }

            // A cancellation or provider-generation change invalidates the
            // entire batch. No provider result, notification, or attempt
            // timestamp is allowed to leak into the next catalog generation.
            guard !Task.isCancelled,
                  self.modelCatalogProviderGeneration == providerGeneration else {
                self.modelCatalogRefreshTask = nil
                self.publishActiveModelCatalogProjection()
                if self.modelCatalogProviderGeneration != providerGeneration {
                    self.refreshModelCatalogIfDue(force: true)
                }
                self.periodicCheck()
                return
            }

            let baseStore = self.modelCatalogStore
            let providerIDs = providers.map { $0.manifest.id }
            let activeProviderIDs = self.activeModelCatalogProviderIDs
            let completedAt = self.currentDate
            let preparationTask = Task.detached(priority: .utility) {
                try ModelCatalogStore.prepareBatch(
                    from: baseStore,
                    providerIDs: providerIDs,
                    activeProviderIDs: activeProviderIDs,
                    outcomes: outcomes,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            }

            let prepared: ModelCatalogPreparedBatch
            do {
                prepared = try await withTaskCancellationHandler {
                    try await preparationTask.value
                } onCancel: {
                    preparationTask.cancel()
                }
            } catch {
                guard self.modelCatalogRefreshRequestID == requestID else {
                    self.discardInvalidatedModelCatalogRefresh(
                        requestID: requestID,
                        providerGeneration: providerGeneration
                    )
                    return
                }
                let message = String(error.localizedDescription.prefix(240))
                self.recordModelCatalogBatchFailure(
                    providerIDs: providerIDs,
                    message: message,
                    at: completedAt
                )
                self.modelCatalogRefreshTask = nil
                self.modelCatalogStatus = ModelCatalogStatus(
                    phase: .failed,
                    providerCount: previousStatus.providerCount,
                    recordCount: previousStatus.recordCount,
                    lastSuccessAt: previousStatus.lastSuccessAt,
                    lastError: message,
                    revision: previousStatus.revision
                )
                self.logger.error("Could not prepare model catalog refresh batch; error=\(error.localizedDescription, privacy: .public)")
                self.periodicCheck()
                return
            }

            guard self.modelCatalogRefreshRequestID == requestID,
                  !Task.isCancelled,
                  self.modelCatalogProviderGeneration == providerGeneration else {
                self.discardInvalidatedModelCatalogRefresh(
                    requestID: requestID,
                    providerGeneration: providerGeneration
                )
                return
            }

            do {
                try await self.modelCatalogPersistence.save(
                    prepared.encodedData,
                    to: baseStore.persistenceURL,
                    generation: requestID
                )
            } catch {
                guard self.modelCatalogRefreshRequestID == requestID else {
                    self.discardInvalidatedModelCatalogRefresh(
                        requestID: requestID,
                        providerGeneration: providerGeneration
                    )
                    return
                }
                let message = String(error.localizedDescription.prefix(240))
                self.recordModelCatalogBatchFailure(
                    providerIDs: providerIDs,
                    message: message,
                    at: completedAt
                )
                self.modelCatalogRefreshTask = nil
                self.modelCatalogStatus = ModelCatalogStatus(
                    phase: .failed,
                    providerCount: previousStatus.providerCount,
                    recordCount: previousStatus.recordCount,
                    lastSuccessAt: previousStatus.lastSuccessAt,
                    lastError: message,
                    revision: previousStatus.revision
                )
                self.logger.error("Could not save model catalog refresh batch; error=\(error.localizedDescription, privacy: .public)")
                self.periodicCheck()
                return
            }

            guard self.modelCatalogRefreshRequestID == requestID,
                  !Task.isCancelled,
                  self.modelCatalogProviderGeneration == providerGeneration else {
                self.discardInvalidatedModelCatalogRefresh(
                    requestID: requestID,
                    providerGeneration: providerGeneration
                )
                return
            }

            self.modelCatalogRefreshTask = nil
            let oldRevision = self.activeModelCatalogRevision
            self.modelCatalogStore = prepared.store
            let catalogChanged = oldRevision != self.activeModelCatalogRevision
            self.modelCatalogEntries = prepared.entries
            self.activePricingBasisCacheKey = nil
            self.activePricingBasisCache = nil
            self.modelCatalogStatus = prepared.status
            // Publish notifications only after the persistent batch commit.
            self.notificationFeedCoordinator.publish(prepared.events)
            self.notificationEvents = self.notificationFeedCoordinator.visibleEvents
            self.refreshModelCatalogWindow()
            self.refreshDashboardLayoutSettingsWindow()
            self.refreshDashboardPreviewWindow()
            if self.drainPendingRefresh() {
                // A manual pricing/usage request may have been queued while
                // this catalog fetch was in flight. Drain it first, now that
                // the captured catalog revision is guaranteed to be current.
                return
            } else if (catalogChanged || self.pricingIsDue), !self.pricingRefreshInFlight {
                self.beginRefresh(
                    intent: .pricing(fallbackToOffline: false, allowEmptyCandidate: false),
                    bypassInterval: true,
                    generation: self.dirtyGeneration
                )
            } else {
                self.periodicCheck()
            }
        }
    }

    /// Catalog pricing normally changes on an hours/days cadence. Schedule a
    /// one-shot wakeup for that deadline instead of relying on the 30-second
    /// watchdog to repeatedly inspect the catalog projection.
    private func scheduleModelCatalogCheck() {
        guard !modelCatalogProviders.isEmpty,
              settings.automaticPricingRefresh,
              modelCatalogRefreshTask == nil else { return }
        let interval = pricingRefreshInterval
        guard interval.isFinite, interval > 0 else { return }
        let lastSuccessAt = modelCatalogStore.lastSuccessAt(for: activeModelCatalogProviderIDs)
        let lastAttemptAt = modelCatalogStore.lastAttemptAt(for: activeModelCatalogProviderIDs)
        let latest = [lastSuccessAt, lastAttemptAt].compactMap { $0 }.max()
        let dueAt = latest?.addingTimeInterval(interval) ?? currentDate
        schedulePeriodicCheck(after: max(dueAt.timeIntervalSince(currentDate), 0.05))
    }

    /// Invalidate a fetch before replacing the provider configuration. Keep the
    /// task reference until its cooperative cancellation unwinds; this prevents
    /// a replacement from starting a second request against the same endpoint.
    private func invalidateModelCatalogRefreshTask() {
        let invalidatedRequestID = modelCatalogRefreshRequestID
        modelCatalogRefreshRequestID += 1
        modelCatalogGenerationFence.invalidate(upTo: invalidatedRequestID)
        modelCatalogRefreshTask?.cancel()
    }

    private func discardInvalidatedModelCatalogRefresh(
        requestID: Int,
        providerGeneration: Int
    ) {
        guard modelCatalogRefreshRequestID != requestID
                || modelCatalogProviderGeneration != providerGeneration
                || modelCatalogRefreshTask != nil else { return }
        modelCatalogRefreshTask = nil
        publishActiveModelCatalogProjection()
        if modelCatalogProviderGeneration != providerGeneration {
            refreshModelCatalogIfDue(force: true)
        }
        periodicCheck()
    }

    private func recordModelCatalogBatchFailure(
        providerIDs: [String],
        message: String,
        at date: Date
    ) {
        for providerID in providerIDs {
            modelCatalogStore.applyFailure(providerID: providerID, message: message, at: date)
        }
    }

    private var activeModelCatalogProviderIDs: Set<String> {
        Set(modelCatalogProviders.map { $0.manifest.id })
    }

    private var activeModelCatalogEntries: [ModelCatalogEntry] {
        // This is the projection prepared by the detached catalog worker and
        // published on the main actor. Do not rebuild, de-duplicate, and sort
        // the full catalog again when pricing starts.
        modelCatalogEntries
    }

    private var activePricingBasis: PricingExecutionBasis {
        let providerIDs = activeModelCatalogProviderIDs.sorted()
        let catalogRevision = modelCatalogStore.revision(for: Set(providerIDs))
        let key = ActivePricingBasisCacheKey(
            customPricingRevision: customPricingTable.revision,
            modelCatalogRevision: catalogRevision,
            providerIDs: providerIDs
        )
        if let cachedKey = activePricingBasisCacheKey,
           cachedKey == key,
           let cachedBasis = activePricingBasisCache {
            return cachedBasis
        }

        let entries = modelCatalogEntries
        let basis = PricingExecutionBasis(
            customTable: customPricingTable,
            remoteCatalogEntries: entries,
            modelCatalogRevision: catalogRevision,
            composition: PricingCatalogComposition.make(
                customTable: customPricingTable,
                remoteEntries: entries
            )
        )
        activePricingBasisCacheKey = key
        activePricingBasisCache = basis
        return basis
    }

    private var activePricingComposition: PricingCatalogComposition {
        activePricingBasis.composition
    }

    /// The UI and status diagnosis consume the exact immutable composition
    /// captured by the pricing engine. The cached basis avoids rebuilding the
    /// catalog on every SwiftUI body evaluation.
    var pricingCatalogComposition: PricingCatalogComposition {
        activePricingComposition
    }

    private var activeModelCatalogRevision: String? {
        modelCatalogStore.revision(for: activeModelCatalogProviderIDs)
    }

    private var modelCatalogProjectionRevision: ModelCatalogProjectionRevision {
        ModelCatalogProjectionRevision(
            customPricingRevision: activeCustomPricingRevision,
            modelCatalogRevision: activeModelCatalogRevision,
            modelCatalogEntryProjectionRevision: modelCatalogStore.entryProjectionRevision(
                for: activeModelCatalogProviderIDs
            )
        )
    }

    private var activeModelCatalogStatus: ModelCatalogStatus {
        modelCatalogStore.status(for: activeModelCatalogProviderIDs)
    }

    private func publishActiveModelCatalogProjection() {
        modelCatalogEntries = modelCatalogStore.entries(for: activeModelCatalogProviderIDs)
        activePricingBasisCacheKey = nil
        activePricingBasisCache = nil
        modelCatalogStatus = activeModelCatalogStatus
    }

    private var currentQueryScope: UsageQueryScope {
        CCUsageRunner.queryScope(for: settings.lookbackDays, now: currentDate)
    }

    private var pricingIsDue: Bool {
        let basisMismatch = snapshot.hasData && (
            snapshot.customPricingRevision != activeCustomPricingRevision
                || snapshot.modelCatalogRevision != activeModelCatalogRevision
        )
        let requiresAttempt = basisMismatch
            || customPricingFileChanged
            || snapshotScopeMismatch
            || !settingsStore.pricingEngineRevisionMatches(Self.pricingEngineRevision)
        if requiresAttempt {
            // A rejected/unknown candidate must not trigger a tight loop, but
            // it also must not permanently disable automatic recovery. Keep
            // one matching attempt behind the normal low-frequency interval;
            // manual Update pricing still bypasses this gate.
            let attemptMatches = settingsStore.pricingAttemptMatches(
                revision: activeCustomPricingRevision,
                modelCatalogRevision: activeModelCatalogRevision,
                engineRevision: Self.pricingEngineRevision
            )
            guard attemptMatches else { return true }
            return RefreshSchedule.isPricingRefreshDue(
                lastSuccessfulAt: nil,
                lastAttemptAt: settingsStore.lastPricingAttemptAt(),
                now: currentDate,
                interval: pricingRefreshInterval
            )
        }
        return RefreshSchedule.isPricingRefreshDue(
            lastSuccessfulAt: snapshot.pricingUpdatedAt,
            lastAttemptAt: settingsStore.lastPricingAttemptAt(),
            now: currentDate,
            interval: pricingRefreshInterval
        )
    }

    private var activeFingerprintCheckInterval: TimeInterval {
        settings.sourceVerificationMode == .periodicFingerprint
            ? settings.fingerprintCheckInterval
            : settings.refreshInterval
    }

    private var fingerprintCheckSchedulingEnabled: Bool {
        settings.sourceVerificationMode == .periodicFingerprint
            || watcher?.isRunning != true
            || pendingWatcherRoots != nil
    }

    private var nextFingerprintCheckAt: Date? {
        guard fingerprintCheckSchedulingEnabled else { return nil }
        if fingerprintCheckRequested || lastFallbackCheckAt == nil {
            return currentDate
        }
        let interval = fallbackCheckFailures > 0
            ? RefreshSchedule.fallbackRetryDelay(refreshInterval: activeFingerprintCheckInterval)
            : activeFingerprintCheckInterval
        guard interval.isFinite, interval >= 0,
              let lastFallbackCheckAt else {
            return nil
        }
        return lastFallbackCheckAt.addingTimeInterval(interval)
    }

    private var fingerprintCheckPending: Bool {
        guard fingerprintCheckSchedulingEnabled else { return false }
        return fingerprintCheckRequested || fallbackCheckIsDue
    }

    private var fallbackCheckIsDue: Bool {
        guard let lastFallbackCheckAt else { return true }
        let interval: TimeInterval
        if fallbackCheckFailures > 0 {
            interval = RefreshSchedule.fallbackRetryDelay(refreshInterval: activeFingerprintCheckInterval)
        } else {
            interval = activeFingerprintCheckInterval
        }
        if fingerprintCheckRequested { return true }
        return RefreshSchedule.isFallbackCheckDue(
            lastCheckAt: lastFallbackCheckAt,
            now: currentDate,
            refreshInterval: interval
        )
    }

    private func runFallbackFingerprintCheck() {
        // Fingerprinting is read-only work and may overlap usage/pricing
        // refreshes. Monthly budget uses the same ccusage-backed runner, so
        // the monthly guard below is the only intentional exclusion here.
        guard !fallbackCheckInFlight,
              !monthlyBudgetRefreshInFlight else {
            return
        }
        fallbackCheckInFlight = true
        fingerprintCheckRequested = false
        fallbackScanCount += 1
        let scanStartedAt = Date()
        let scanStartedEventCount = watcherEventCount
        let scanStartedRootGeneration = sourceRootGeneration
        let dirtyGenerationAtStart = dirtyGeneration
        let scanMode = settings.sourceVerificationMode
        publishDeveloperDiagnostics()
        let reader = fingerprintReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result: Result<[SourceFingerprint], Error>
            do {
                result = .success(try reader())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fallbackCheckInFlight = false
                self.lastFallbackCheckAt = self.currentDate
                self.lastFallbackScanDuration = max(0, Date().timeIntervalSince(scanStartedAt))
                let eventOrRootChangedDuringScan = self.watcherEventCount != scanStartedEventCount
                    || self.sourceRootGeneration != scanStartedRootGeneration
                switch result {
                case let .success(fingerprints):
                    self.fallbackCheckFailures = 0
                    let hadBaseline = self.hasFallbackFingerprintBaseline
                    let sourceChanged = hadBaseline
                        && fingerprints != self.lastFallbackFingerprints
                    let sourceActivitySinceBaseline = hadBaseline && (
                        self.watcherEventCount != self.fingerprintBaselineEventCount
                            || self.sourceRootGeneration != self.fingerprintBaselineRootGeneration
                    )
                    self.lastFallbackFingerprints = fingerprints
                    self.hasFallbackFingerprintBaseline = true
                    self.fingerprintBaselineEventCount = self.watcherEventCount
                    self.fingerprintBaselineRootGeneration = self.sourceRootGeneration
                    if !hadBaseline {
                        self.fingerprintCheckOutcome = "baseline seeded"
                        // Event-driven mode has no baseline while a healthy
                        // watcher is running. If that watcher later goes
                        // down, conservatively reconcile a non-empty source
                        // once so a missed change from the gap cannot remain
                        // invisible. Periodic mode intentionally seeds its
                        // first baseline without manufacturing a change.
                        if scanMode == .eventDriven,
                           !fingerprints.isEmpty,
                           !self.isDirty,
                           self.dirtyGeneration == dirtyGenerationAtStart {
                            self.markDirty(cause: .watcherDownFallback)
                        }
                    } else if !sourceChanged {
                        self.fingerprintCheckOutcome = "unchanged"
                    } else {
                        self.fingerprintCheckOutcome = "changed"
                        self.lastFingerprintDetectionAt = self.currentDate
                        // A prior watcher event can explain an already-dirty
                        // state, but it cannot make a usage scan that is
                        // already in flight observe a later silent change.
                        // Force a new generation in that case so the in-flight
                        // result is discarded instead of clearing the pending
                        // change.
                        let dirtyStateAlreadyCoversChange = self.isDirty
                            && sourceActivitySinceBaseline
                            && !self.refreshInFlight
                        if !dirtyStateAlreadyCoversChange {
                            self.markDirty(
                                cause: scanMode == .periodicFingerprint
                                    ? .periodicFingerprint
                                    : .watcherDownFallback
                            )
                        }
                    }
                    if eventOrRootChangedDuringScan {
                        self.fingerprintCheckRequested = true
                    }
                case let .failure(error):
                    self.fallbackCheckFailures += 1
                    self.fingerprintCheckOutcome = "failed"
                    self.logger.warning("Fallback fingerprint scan failed; retrying with backoff, error=\(error.localizedDescription, privacy: .public)")
                }
                if self.watcher?.isRunning != true {
                    self.reinstallWatcher()
                }
                self.publishDeveloperDiagnostics()
                self.periodicCheck()
            }
        }
    }

    private func beginRefresh(intent: RefreshIntent, bypassInterval: Bool, generation: Int? = nil) {
        if intent.isPricing {
            reloadCustomPricingFromDiskIfNeeded()
        }
        if refreshInFlight || pricingRefreshInFlight || monthlyBudgetRefreshInFlight {
            if bypassInterval || intent.isPricing {
                queueRefresh(intent: intent, generation: generation ?? dirtyGeneration)
            }
            return
        }
        // Do not price against a catalog that is about to be replaced. The
        // catalog completion path will drain this queued intent after it has
        // published the new revision.
        if intent.isPricing, modelCatalogRefreshTask != nil {
            queueRefresh(intent: intent, generation: generation ?? dirtyGeneration)
            return
        }
        let started = currentDate
        if intent.isPricing {
            guard !pricingRefreshInFlight, !refreshInFlight else { return }
            pricingRefreshInFlight = true
            if intent.usesOnlinePricing {
                settingsStore.recordPricingAttempt(
                    revision: activeCustomPricingRevision,
                    modelCatalogRevision: activeModelCatalogRevision,
                    engineRevision: Self.pricingEngineRevision,
                    at: started
                )
            }
        } else {
            guard !refreshInFlight, !pricingRefreshInFlight, bypassInterval || canRefreshNow else { return }
            refreshInFlight = true
        }

        if intent.isPricing { phase = .updatingPricing } else { phase = .refreshing }
        logger.info("Starting refresh; intent=\(String(describing: intent), privacy: .public)")
        lastRefreshStartedAt = started
        lastRefreshIntent = intent.diagnosticLabel
        lastRefreshError = nil
        if !intent.isPricing {
            lastUsageRefreshStartedAt = started
        }
        publishDeveloperDiagnostics()
        let currentSettings = settings
        let oldPricingDate = pricingReferenceSnapshot.pricingUpdatedAt
        let currentRunner = runner
        let previousSnapshot = pricingReferenceSnapshot
        let pricingBasis = PricingExecutionBasis(
            customTable: customPricingTable,
            remoteCatalogEntries: activeModelCatalogEntries,
            modelCatalogRevision: activeModelCatalogRevision
        )
        let currentCustomPricing = pricingBasis.customTable
        let currentModelCatalogRevision = pricingBasis.modelCatalogRevision
        let pricingRevisionChanged = intent.isPricing
            && previousSnapshot.customPricingRevision != currentCustomPricing.revision
        let generationAtStart = generation ?? dirtyGeneration
        let pricingGenerationAtStart = pricingGeneration
        let pricingConfigURL = Self.managedCcusagePricingURL(
            for: pricingGenerationAtStart,
            directory: generatedPricingDirectory
        )
        let pricingIdentity = PricingExecutionIdentity(
            generation: pricingGenerationAtStart,
            revision: currentCustomPricing.revision,
            modelCatalogRevision: currentModelCatalogRevision,
            artifactURL: pricingConfigURL
        )
        let refreshLogger = logger

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let pricingPreparation: CcusagePricingPreparation?
                let configURL: URL?
                if intent.runnerMode.includesCost {
                    let preparation = try CcusagePricingAdapter.bundledV20.prepare(
                        composition: pricingBasis.composition,
                        writeTo: pricingConfigURL
                    )
                    pricingPreparation = preparation
                    configURL = preparation.hasOverrides ? pricingConfigURL : nil
                    if !preparation.diagnostics.isEmpty {
                        refreshLogger.warning(
                            "Applied approximate custom tier mapping; models=\(preparation.approximateModelNames.count, privacy: .public), diagnostics=\(preparation.diagnostics.count, privacy: .public)"
                        )
                    }
                } else {
                    pricingPreparation = nil
                    configURL = nil
                }

                let rawRun = try currentRunner.runWithPricingContext(
                    settings: currentSettings,
                    mode: intent.runnerMode,
                    previousPricingDate: oldPricingDate,
                    pricingConfigURL: configURL,
                    pricingContext: PricingResolutionContext(
                        basis: pricingBasis,
                        preparation: pricingPreparation ?? .empty
                    )
                )
                let rawSnapshot = rawRun.snapshot
                let pricingAssessment = rawRun.pricingAssessment
                let baseSnapshot: UsageSnapshot
                let accepted: Bool
                if intent.isPricing {
                    let appliedModelNames = pricingPreparation?.appliedModelNames ?? []
                    baseSnapshot = PricingSnapshotAnnotation.apply(
                        to: rawSnapshot,
                        customPricingRevision: currentCustomPricing.revision,
                        appliedModelNames: appliedModelNames,
                        approximateModelNames: pricingPreparation?.approximateModelNames ?? [],
                        selectedTierThresholds: pricingPreparation?.selectedTierThresholds ?? [:],
                        selectedBackendThresholds: pricingPreparation?.selectedBackendThresholds ?? [:],
                        pricingComposition: pricingBasis.composition
                    )
                    let candidateWithPricing = baseSnapshot
                    if pricingRevisionChanged {
                        accepted = PricingRefreshPolicy.acceptsAfterPricingRevisionChange(
                            candidate: candidateWithPricing,
                            previous: previousSnapshot,
                            pricingAssessment: pricingAssessment,
                            allowEmptyCandidate: intent.allowEmptyCandidate
                        )
                    } else {
                        accepted = PricingRefreshPolicy.accepts(
                            candidate: candidateWithPricing,
                            previous: previousSnapshot,
                            pricingAssessment: pricingAssessment,
                            allowEmptyCandidate: intent.allowEmptyCandidate
                        )
                    }
                } else {
                    let usageWithPricing = PricingSnapshotAnnotation.apply(
                        to: rawSnapshot,
                        customPricingRevision: currentCustomPricing.revision,
                        appliedModelNames: pricingPreparation?.appliedModelNames ?? [],
                        approximateModelNames: pricingPreparation?.approximateModelNames ?? [],
                        selectedTierThresholds: pricingPreparation?.selectedTierThresholds ?? [:],
                        selectedBackendThresholds: pricingPreparation?.selectedBackendThresholds ?? [:],
                        pricingComposition: pricingBasis.composition
                    )
                    baseSnapshot = UsageSnapshot.mergingUsage(
                        usageWithPricing,
                        preservingPricingFrom: previousSnapshot,
                        pricingAssessment: pricingAssessment
                    )
                    accepted = true
                }
                let newSnapshot = baseSnapshot
                Task { @MainActor [weak self] in
                    self?.finishRefresh(
                        snapshot: newSnapshot,
                        started: started,
                        intent: intent,
                        generationAtStart: generationAtStart,
                        pricingIdentity: pricingIdentity,
                        accepted: accepted
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.failRefresh(
                        error,
                        intent: intent,
                        started: started,
                        generationAtStart: generationAtStart,
                        pricingIdentity: pricingIdentity
                    )
                }
            }
        }
    }

    private func queueRefresh(intent: RefreshIntent, generation: Int) {
        if intent.isPricing {
            pendingRefreshIntent = intent
            pendingRefreshGeneration = generation
        } else {
            queueForcedUsageRefresh(generation: generation)
        }
    }

    private func queueForcedUsageRefresh(generation: Int) {
        pendingForcedUsageRefresh = true
        pendingForcedUsageGeneration = generation
        // A forced usage request covers the source change that may have set
        // this flag while pricing was in flight.
        pendingUsageRefresh = false
    }

    @discardableResult
    private func drainPendingRefresh() -> Bool {
        promotePendingUsageRefresh()
        if let intent = pendingRefreshIntent {
            let generation = pendingRefreshGeneration ?? dirtyGeneration
            pendingRefreshIntent = nil
            pendingRefreshGeneration = nil
            beginRefresh(intent: intent, bypassInterval: true, generation: generation)
            return true
        }
        guard pendingForcedUsageRefresh else { return false }
        let generation = pendingForcedUsageGeneration ?? dirtyGeneration
        pendingForcedUsageRefresh = false
        pendingForcedUsageGeneration = nil
        beginRefresh(intent: .usage, bypassInterval: true, generation: generation)
        return true
    }

    private func promotePendingUsageRefresh() {
        guard pendingRefreshIntent == nil,
              !pendingForcedUsageRefresh,
              pendingUsageRefresh else { return }
        pendingUsageRefresh = false
        queueForcedUsageRefresh(generation: dirtyGeneration)
    }

    private func queueReplacement(for intent: RefreshIntent, generation: Int) {
        if intent.isPricing {
            queueRefresh(intent: intent, generation: generation)
        } else if pendingRefreshIntent == nil, !pendingForcedUsageRefresh {
            queueForcedUsageRefresh(generation: generation)
        }
        if pendingUsageRefresh {
            pendingUsageRefresh = false
            queueForcedUsageRefresh(generation: generation)
        }
    }

    private func clearInFlight(for intent: RefreshIntent) {
        if intent.isPricing {
            pricingRefreshInFlight = false
            refreshInFlight = false
        } else {
            refreshInFlight = false
        }
    }

    private func finishRefresh(
        snapshot: UsageSnapshot,
        started: Date,
        intent: RefreshIntent,
        generationAtStart: Int,
        pricingIdentity: PricingExecutionIdentity,
        accepted: Bool
    ) {
        if !isPricingExecutionCurrent(pricingIdentity) {
            Self.removeManagedCcusagePricingArtifact(
                at: pricingIdentity.artifactURL,
                directory: generatedPricingDirectory
            )
            clearInFlight(for: intent)
            phase = .waiting
            queueReplacement(
                for: .pricing(fallbackToOffline: true, allowEmptyCandidate: false),
                generation: dirtyGeneration
            )
            _ = drainPendingRefresh()
            return
        }
        if let candidateScope = snapshot.queryScope,
           candidateScope != currentQueryScope {
            // The calendar scope can roll over while either usage or pricing
            // is still running. Do not briefly publish yesterday's report
            // after midnight; invalidate it and force a current-scope run.
            clearInFlight(for: intent)
            markScopeRollover()
            phase = .waiting
            recordRefreshCompletion(intent: intent, started: started, failed: false)
            if pendingRefreshIntent == nil, !pendingForcedUsageRefresh {
                queueRefresh(intent: intent, generation: dirtyGeneration)
            }
            _ = drainPendingRefresh()
            return
        }
        if dirtyGeneration != generationAtStart {
            clearInFlight(for: intent)
            phase = .waiting
            recordRefreshCompletion(intent: intent, started: started, failed: false)
            if pendingRefreshIntent != nil || pendingForcedUsageRefresh {
                // Manual refreshes, scope rollovers, and configuration changes
                // are explicit requests and must retain their immediate
                // semantics. A plain source change has no queued intent.
                _ = drainPendingRefresh()
            } else {
                // The result is stale, but do not turn a source event during a
                // scan into an immediate replacement scan. The normal path
                // enforces both the source settle window and user throttle.
                pendingUsageRefresh = false
                periodicCheck()
            }
            return
        }
        guard accepted else {
            logger.warning("Pricing candidate rejected; intent=\(String(describing: intent), privacy: .public), candidateCost=\(snapshot.estimatedCost, privacy: .public), previousCost=\(self.pricingReferenceSnapshot.estimatedCost, privacy: .public), unknownModels=\(snapshot.unknownPricingModels.count, privacy: .public)")
            clearInFlight(for: intent)
            phase = isDirty ? .waiting : .idle
            recordRefreshCompletion(
                intent: intent,
                started: started,
                failed: true,
                error: "Pricing candidate rejected"
            )
            if intent.fallbackToOffline {
                beginRefresh(
                    intent: .offlinePricing(allowEmptyCandidate: intent.allowEmptyCandidate),
                    bypassInterval: true,
                    generation: generationAtStart
                )
            }
            promotePendingUsageRefresh()
            if !drainPendingRefresh() {
                periodicCheck()
            }
            return
        }

        do {
            try snapshotStore.save(snapshot)
        } catch {
            logger.error("Could not save usage snapshot; error=\(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            clearInFlight(for: intent)
            recordRefreshCompletion(
                intent: intent,
                started: started,
                failed: true,
                error: error.localizedDescription
            )
            promotePendingUsageRefresh()
            if !drainPendingRefresh() {
                periodicCheck()
            }
            return
        }

        let previousDisplayedSnapshot = self.snapshot
        let addedModels = snapshot.addedModelIdentities(comparedTo: previousDisplayedSnapshot)
        let newlyUnknownModels = snapshot.newlyUnknownModelIdentities(comparedTo: previousDisplayedSnapshot)
        logger.info("Refresh succeeded; intent=\(String(describing: intent), privacy: .public), onlinePricing=\(intent.usesOnlinePricing, privacy: .public), candidateCost=\(snapshot.estimatedCost, privacy: .public), previousCost=\(previousDisplayedSnapshot.estimatedCost, privacy: .public), tokens=\(snapshot.totalTokens.totalTokens, privacy: .public), addedModels=\(addedModels.count, privacy: .public), newlyUnknownModels=\(newlyUnknownModels.count, privacy: .public), duration=\(self.lastRefreshDuration ?? 0, privacy: .public)")
        self.snapshot = snapshot
        self.pricingReferenceSnapshot = snapshot
        if intent.isPricing {
            settingsStore.recordPricingEngineRevision(Self.pricingEngineRevision)
        }
        if dirtyGeneration == generationAtStart {
            self.isDirty = false
            self.dirtySince = nil
            self.lastSourceEventAt = nil
        }
        clearInFlight(for: intent)
        phase = isDirty ? .waiting : .idle
        recordRefreshCompletion(intent: intent, started: started, failed: false)

        promotePendingUsageRefresh()
        if drainPendingRefresh() { return }
        if !intent.isPricing,
           settings.automaticPricingRefresh,
           pricingIsDue,
           !pricingRefreshInFlight,
           modelCatalogRefreshTask == nil {
            beginRefresh(intent: .pricing(fallbackToOffline: false, allowEmptyCandidate: false), bypassInterval: true, generation: dirtyGeneration)
        }
        // A monthly budget has its own low-frequency schedule. Re-check now
        // so a completed usage/pricing refresh does not wait for the next
        // watchdog tick to start a due budget reconciliation.
        periodicCheck()
    }

    private func reloadCustomPricingFromDiskIfNeeded() {
        let path = settings.customPricingPath
        guard !path.isEmpty else {
            if !customPricingTable.isEmpty {
                pricingGeneration += 1
                customPricingTable = .empty
                activeCustomPricingRevision = nil
                activeCustomPricingFileFingerprint = nil
                customPricingModelCount = 0
                refreshModelCatalogWindow()
            }
            return
        }

        do {
            let table = try CustomPricingTable(contentsOf: URL(fileURLWithPath: path))
            activeCustomPricingFileFingerprint = Self.customPricingFileFingerprint(path: path)
            guard table != customPricingTable else {
                customPricingError = nil
                return
            }
            pricingGeneration += 1
            customPricingTable = table
            activeCustomPricingRevision = table.revision
            customPricingModelCount = table.modelCount
            customPricingError = nil
            refreshModelCatalogWindow()
            logger.info("Reloaded custom pricing before pricing refresh; models=\(table.modelCount, privacy: .public)")
        } catch {
            // Keep the last valid in-memory table. A transient external edit or
            // an atomic replacement must not turn every model into zero-cost.
            activeCustomPricingFileFingerprint = Self.customPricingFileFingerprint(path: path)
            customPricingError = error.localizedDescription
            logger.warning("Could not reload custom pricing; retaining last valid table, error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateCustomPricing(_ table: CustomPricingTable, path: String) {
        pricingGeneration += 1
        settings.customPricingPath = path
        customPricingTable = table
        activeCustomPricingRevision = table.revision
        activeCustomPricingFileFingerprint = Self.customPricingFileFingerprint(path: path)
        customPricingModelCount = table.modelCount
        customPricingError = nil
        refreshModelCatalogWindow()
    }

    private func refreshModelCatalogWindow() {
        guard let window = modelCatalogWindow else { return }
        let entries = allModelCatalogEntries
        guard !entries.isEmpty else {
            window.orderOut(nil)
            return
        }
        if let hostingView = window.contentView as? NSHostingView<ModelCatalogView> {
            hostingView.rootView = ModelCatalogView(
                entries: entries,
                language: settings.language,
                state: modelCatalogViewState,
                projectionRevision: modelCatalogProjectionRevision,
                interfaceTextSize: settings.interfaceTextSize,
                appearance: settings.appearance,
                surfaceStyle: settings.surfaceStyle
            )
        }
    }

    private func refreshAboutWindow() {
        guard let window = aboutWindow,
              let hostingView = window.contentView as? NSHostingView<AboutView> else { return }
        hostingView.rootView = AboutView(
            language: settings.language,
            interfaceTextSize: settings.interfaceTextSize,
            appearance: settings.appearance,
            surfaceStyle: settings.surfaceStyle
        )
        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.aboutWindowWidth),
            height: CGFloat(settings.interfaceTextSize.aboutWindowHeight)
        ))
    }

    private func refreshBudgetSettingsWindow() {
        guard let window = budgetSettingsWindow else { return }
        window.title = L10n(language: settings.language).budgetSettingsTitle
        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.budgetSettingsWidth),
            height: CGFloat(settings.interfaceTextSize.budgetSettingsHeight)
        ))
    }

    private func refreshPluginSettingsWindow() {
        guard let window = pluginSettingsWindow else { return }
        let copy = L10n(language: settings.language)
        window.title = copy.pluginSettingsTitle
        if let hostingView = window.contentView as? NSHostingView<PluginSettingsView> {
            hostingView.rootView = PluginSettingsView(
                store: self,
                onClose: { [weak self] in self?.pluginSettingsWindow?.orderOut(nil) }
            )
        }
    }

    private func refreshPluginConfigurationWindow() {
        guard let window = pluginConfigurationWindow,
              let pluginID = pluginConfigurationPluginID,
              let record = externalPlugins.first(where: { $0.id == pluginID }),
              let schema = record.manifest.configuration,
              let externalPluginRegistry else {
            return
        }
        do {
            let draft = try externalPluginRegistry.loadConfigurationDraft(pluginID: pluginID)
            let copy = L10n(language: settings.language)
            window.title = copy.pluginConfigurationTitle(record.manifest.localizedDisplayName(for: settings.language))
            if let hostingView = window.contentView as? NSHostingView<PluginConfigurationView> {
                hostingView.rootView = PluginConfigurationView(
                    record: record,
                    schema: schema,
                    draft: draft,
                    language: settings.language,
                    appearance: settings.appearance,
                    surfaceStyle: settings.surfaceStyle,
                    interfaceTextSize: settings.interfaceTextSize,
                    onSave: { [weak self] submission in
                        try self?.saveExternalPluginConfiguration(submission, pluginID: pluginID)
                    },
                    onReset: { [weak self] in
                        try self?.resetExternalPluginConfiguration(pluginID: pluginID)
                    },
                    onClose: { [weak self] in self?.pluginConfigurationWindow?.orderOut(nil) }
                )
            }
        } catch {
            externalPluginError = error.localizedDescription
        }
    }

    private func refreshDashboardPreviewWindow() {
        guard let window = dashboardPreviewWindow else { return }
        window.title = L10n(language: settings.language).dashboardLayoutPreviewTitle
        let previewHeight = dashboardPreviewState?.popoverHeight ?? settings.popoverHeight
        window.setContentSize(NSSize(
            width: CGFloat(settings.interfaceTextSize.popoverWidth),
            height: CGFloat(effectivePopoverHeight(
                for: dashboardPreviewState?.layout,
                storedHeight: previewHeight
            ))
        ))
    }

    private func refreshDashboardLayoutSettingsWindow() {
        guard let window = dashboardLayoutSettingsWindow else { return }
        let copy = L10n(language: settings.language)
        window.title = copy.dashboardLayoutSettingsTitle
        if let hostingView = window.contentView as? NSHostingView<DashboardLayoutSettingsView> {
            let components = availableDashboardComponents
            let editingLayout = (dashboardLayoutEditingDraft ?? dashboardLayout)
                .normalized(for: components)
            let editingPopoverHeight = dashboardLayoutEditingPopoverHeight ?? settings.popoverHeight
            dashboardLayoutEditingDraft = editingLayout
            dashboardLayoutEditingPopoverHeight = editingPopoverHeight
            hostingView.rootView = makeDashboardLayoutSettingsView(
                components: components,
                layout: editingLayout,
                popoverHeight: editingPopoverHeight
            )
        }
    }

    private func isPricingExecutionCurrent(_ identity: PricingExecutionIdentity) -> Bool {
        pricingGeneration == identity.generation
            && activeCustomPricingRevision == identity.revision
            && activeModelCatalogRevision == identity.modelCatalogRevision
            && Self.managedCcusagePricingURL(
                for: identity.generation,
                directory: generatedPricingDirectory
            ) == identity.artifactURL
    }

    private func makeDashboardLayoutSettingsView(
        components: [DashboardLayoutComponent],
        layout: DashboardLayout,
        popoverHeight: Double
    ) -> DashboardLayoutSettingsView {
        DashboardLayoutSettingsView(
            components: components,
            layout: layout,
            language: settings.language,
            appearance: settings.appearance,
            surfaceStyle: settings.surfaceStyle,
            interfaceTextSize: settings.interfaceTextSize,
            popoverHeight: popoverHeight,
            initialCustomPopoverHeight: effectivePopoverHeight(
                for: layout,
                storedHeight: popoverHeight
            ),
            onSave: { [weak self] layout, popoverHeight in
                try self?.saveDashboardLayout(layout, popoverHeight: popoverHeight)
            },
            onReset: { [weak self] in
                try self?.resetDashboardLayout()
            },
            onDraftChange: { [weak self] layout, popoverHeight in
                self?.updateDashboardLayoutDraft(layout, popoverHeight: popoverHeight)
            },
            onClose: { [weak self] in self?.closeDashboardLayoutSession() }
        )
    }

    private func pluginLayoutBlocks(
        for snapshot: DashboardPluginRuntimeSnapshot
    ) -> [DashboardLayoutBlockDescriptor] {
        if let dashboard = snapshot.runtime.dashboard {
            return dashboard.blocks.map { block in
                DashboardLayoutBlockDescriptor(
                    id: block.id,
                    title: block.layoutTitle,
                    kind: block.layoutKind,
                    itemCount: block.layoutItemCount,
                    defaultColumns: block.layoutColumns
                )
            }
        }

        return snapshot.manifest.dashboard?.blocks.map { block in
            DashboardLayoutBlockDescriptor(
                id: block.id,
                title: block.id,
                kind: block.layoutKind,
                itemCount: block.layoutItemCount,
                defaultColumns: block.layoutColumns
            )
        } ?? []
    }

    private func refreshDeveloperDiagnosticsWindow() {
        guard let window = developerDiagnosticsWindow else { return }
        window.title = L10n(language: settings.language).developerDiagnosticsTitle
        if let hostingView = window.contentView as? NSHostingView<DeveloperDiagnosticsView> {
            hostingView.rootView = DeveloperDiagnosticsView(store: self)
        }
    }

    private func showPricingAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n(language: settings.language).ok)
        alert.runModal()
    }

    private func confirmMergeFallback(copy: L10n) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.customPricingMergeFallbackTitle
        alert.informativeText = copy.customPricingMergeFallbackMessage
        alert.addButton(withTitle: copy.replaceAnyway)
        alert.addButton(withTitle: copy.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func managedCustomPricingURL(fileManager: FileManager = .default) -> URL {
        managedPricingDirectory(fileManager: fileManager)
            .appendingPathComponent("custom-pricing.json")
    }

    private static func managedPricingDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
    }

    private static func removeManagedCustomPricingArtifact(
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: managedCustomPricingURL(fileManager: fileManager))
    }

    private static func managedCcusagePricingURL(
        for generation: Int,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) -> URL {
        (directory ?? managedPricingDirectory(fileManager: fileManager))
            .appendingPathComponent("ccusage-pricing-\(generation).json")
    }

    private static func removeManagedCcusagePricingArtifacts(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        let targetDirectory = directory ?? managedPricingDirectory(fileManager: fileManager)
        guard let names = try? fileManager.contentsOfDirectory(atPath: targetDirectory.path) else { return }
        for name in names where name == "ccusage-pricing.json" || name.hasPrefix("ccusage-pricing-") {
            removeManagedCcusagePricingArtifact(
                at: targetDirectory.appendingPathComponent(name),
                fileManager: fileManager,
                directory: targetDirectory
            )
        }
    }

    private static func removeManagedCcusagePricingArtifact(
        at url: URL?,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        guard let url else { return }
        let directory = directory ?? managedPricingDirectory(fileManager: fileManager)
        guard url.deletingLastPathComponent().path == directory.path else { return }
        let name = url.lastPathComponent
        guard name == "ccusage-pricing.json" || name.hasPrefix("ccusage-pricing-") else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func reconcileManagedCcusagePricingArtifacts(
        table: CustomPricingTable,
        remoteEntries: [ModelCatalogEntry] = [],
        generation: Int,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        let targetDirectory = directory ?? managedPricingDirectory(fileManager: fileManager)
        removeManagedCcusagePricingArtifacts(fileManager: fileManager, directory: targetDirectory)
        let catalog = PricingCatalogComposition.make(
            customTable: table,
            remoteEntries: remoteEntries
        )
        guard !catalog.catalog.models.isEmpty else { return }
        _ = try? CcusagePricingAdapter.bundledV20.prepare(
            composition: catalog,
            writeTo: managedCcusagePricingURL(
                for: generation,
                fileManager: fileManager,
                directory: targetDirectory
            ),
            fileManager: fileManager
        )
    }

    private static func customPricingFileFingerprint(path: String) -> CustomPricingFileFingerprint? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return CustomPricingFileFingerprint(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize.map(Int64.init)
        )
    }

    nonisolated private static func normalizeModelName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadCustomPricing(path: String) -> (table: CustomPricingTable, error: String?) {
        guard !path.isEmpty else { return (.empty, nil) }
        do {
            return (try CustomPricingTable(contentsOf: URL(fileURLWithPath: path)), nil)
        } catch {
            return (.empty, error.localizedDescription)
        }
    }

    private func failRefresh(
        _ error: Error,
        intent: RefreshIntent,
        started: Date,
        generationAtStart: Int,
        pricingIdentity: PricingExecutionIdentity
    ) {
        let message: String
        if let runnerError = error as? CCUsageRunnerError {
            message = runnerError.message(language: settings.language)
        } else {
            message = error.localizedDescription
        }
        if !isPricingExecutionCurrent(pricingIdentity) {
            Self.removeManagedCcusagePricingArtifact(
                at: pricingIdentity.artifactURL,
                directory: generatedPricingDirectory
            )
            clearInFlight(for: intent)
            phase = .waiting
            // This worker was superseded by a newer pricing generation. Its
            // error is expected during cancellation-by-generation and must
            // not appear in the current refresh diagnostics.
            queueReplacement(
                for: intent.isPricing
                    ? .pricing(fallbackToOffline: true, allowEmptyCandidate: false)
                    : .usage,
                generation: dirtyGeneration
            )
            _ = drainPendingRefresh()
            return
        }
        if dirtyGeneration != generationAtStart {
            clearInFlight(for: intent)
            phase = .waiting
            recordRefreshCompletion(intent: intent, started: started, failed: true, error: message)
            if pendingRefreshIntent != nil || pendingForcedUsageRefresh {
                _ = drainPendingRefresh()
            } else {
                pendingUsageRefresh = false
                periodicCheck()
            }
            return
        }
        logger.error("Refresh failed; pricing=\(intent.isPricing, privacy: .public), onlinePricing=\(intent.usesOnlinePricing, privacy: .public), error=\(message, privacy: .public)")
        phase = .failed(message)
        clearInFlight(for: intent)
        recordRefreshCompletion(intent: intent, started: started, failed: true, error: message)
        if intent.isPricing, intent.fallbackToOffline {
            beginRefresh(
                intent: .offlinePricing(allowEmptyCandidate: intent.allowEmptyCandidate),
                bypassInterval: true,
                generation: dirtyGeneration
            )
            _ = drainPendingRefresh()
            return
        }
        if !drainPendingRefresh() {
            periodicCheck()
        }
    }
}

enum RelativeTime {
    static func localizedString(for date: Date, relativeTo now: Date, language: AppLanguage) -> String {
        let copy = L10n(language: language)
        let offset = now.timeIntervalSince(date)
        if abs(offset) < 1 {
            return copy.justNow
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.resolved == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum Currency {
    static func numeric(_ value: Double, precision: Int? = nil) -> String {
        guard value.isFinite else { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        if let precision {
            formatter.minimumFractionDigits = precision
            formatter.maximumFractionDigits = precision
        } else {
            formatter.maximumFractionDigits = value < 10 ? 2 : 1
        }
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    static func format(_ value: Double) -> String {
        "$" + numeric(value)
    }

    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "$0" }
        return "$" + NumberFormat.compact(value)
    }
}

enum NumberFormat {
    static func threshold(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...:
            return value % 1_000_000_000 == 0
                ? "\(value / 1_000_000_000)B"
                : compact(value)
        case 1_000_000...:
            return value % 1_000_000 == 0
                ? "\(value / 1_000_000)M"
                : compact(value)
        case 1_000...:
            return value % 1_000 == 0
                ? "\(value / 1_000)K"
                : compact(value)
        default:
            return grouped(value)
        }
    }

    static func grouped(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compact(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let sign = value < 0 ? "-" : ""
        let absolute = abs(value)
        switch absolute {
        case 1_000_000_000...:
            return sign + String(format: "%.1fB", absolute / 1_000_000_000)
        case 1_000_000...:
            return sign + String(format: "%.1fM", absolute / 1_000_000)
        case 1_000...:
            return sign + String(format: "%.1fK", absolute / 1_000)
        default:
            return sign + String(format: "%.0f", absolute)
        }
    }
}
