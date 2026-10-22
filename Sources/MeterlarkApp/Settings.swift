import Foundation

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String { rawValue }
}

enum AppSurfaceStyle: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case solid
    case glass

    var id: String { rawValue }
}

enum SourceVerificationMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case eventDriven
    case periodicFingerprint

    var id: String { rawValue }
}

enum InterfaceTextSize: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case large
    case extraLarge
    case largest

    var id: String { rawValue }

    var scale: Double {
        switch self {
        case .standard: return 1.00
        case .large: return 1.10
        case .extraLarge: return 1.20
        case .largest: return 1.30
        }
    }

    var percentage: Int { Int(scale * 100) }

    var popoverWidth: Double {
        switch self {
        case .standard: return 390
        case .large: return 398
        case .extraLarge: return 406
        case .largest: return 414
        }
    }

    var compactPopoverHeight: Double {
        switch self {
        case .standard: return MonitorSettings.compactPopoverHeight
        case .large: return 810
        case .extraLarge: return 855
        case .largest: return 890
        }
    }

    var compactPopoverHeightWithBudget: Double {
        switch self {
        case .standard: return MonitorSettings.compactPopoverHeightWithBudget
        case .large: return 920
        case .extraLarge: return 985
        case .largest: return 1_030
        }
    }

    var compactPopoverHeightWithBothBudgets: Double {
        switch self {
        case .standard: return MonitorSettings.compactPopoverHeightWithBothBudgets
        case .large: return 930
        case .extraLarge: return 995
        case .largest: return 1_040
        }
    }

    var contentPadding: Double {
        switch self {
        case .standard: return 16
        case .large: return 16
        case .extraLarge: return 17
        case .largest: return 18
        }
    }

    var sectionSpacing: Double {
        switch self {
        case .standard: return 14
        case .large: return 14
        case .extraLarge: return 15
        case .largest: return 16
        }
    }

    var chartHeight: Double {
        switch self {
        case .standard: return 165
        case .large: return 170
        case .extraLarge: return 180
        case .largest: return 190
        }
    }

    var controlHeight: Double {
        switch self {
        case .standard: return 30
        case .large: return 31
        case .extraLarge: return 33
        case .largest: return 35
        }
    }

    var summaryTileHeight: Double {
        switch self {
        case .standard: return 40
        case .large: return 41
        case .extraLarge: return 44
        case .largest: return 48
        }
    }

    var detailPreviewHeight: Double {
        switch self {
        case .standard: return 44
        case .large: return 45
        case .extraLarge: return 48
        case .largest: return 52
        }
    }

    var aboutWindowWidth: Double {
        switch self {
        case .standard: return 430
        case .large: return 440
        case .extraLarge: return 450
        case .largest: return 465
        }
    }

    var aboutWindowHeight: Double {
        switch self {
        case .standard: return 285
        case .large: return 295
        case .extraLarge: return 310
        case .largest: return 330
        }
    }

    var budgetSettingsWidth: Double {
        switch self {
        case .standard: return 560
        case .large: return 580
        case .extraLarge: return 600
        case .largest: return 620
        }
    }

    var budgetSettingsHeight: Double {
        switch self {
        case .standard: return 560
        case .large: return 590
        case .extraLarge: return 620
        case .largest: return 650
        }
    }

    var modelCatalogWidth: Double {
        switch self {
        case .standard: return 780
        case .large: return 800
        case .extraLarge: return 820
        case .largest: return 850
        }
    }

    var modelCatalogHeight: Double {
        switch self {
        case .standard: return 520
        case .large: return 535
        case .extraLarge: return 560
        case .largest: return 600
        }
    }
}

struct MonitorSettings: Equatable, Sendable {
    static let defaultRefreshInterval: TimeInterval = 60
    static let allowedIntervals: [TimeInterval] = [60, 300, 900, 1_800, 3_600]
    static let defaultFingerprintCheckInterval: TimeInterval = 300
    static let minimumFingerprintCheckInterval: TimeInterval = 60
    static let maximumFingerprintCheckInterval: TimeInterval = 3_600
    static let allowedFingerprintIntervals: [TimeInterval] = allowedIntervals
    /// Remote catalogs are intentionally low-frequency data. Keep corrupted
    /// or stale UserDefaults values from turning the scheduler into a tight
    /// network/CPU loop, while still allowing a long offline cadence.
    static let defaultPricingRefreshHours: Double = 24
    static let minimumPricingRefreshHours: Double = 1
    static let maximumPricingRefreshHours: Double = 24 * 365
    /// A zero-day lookback is reserved for the current calendar month.
    static let calendarMonthLookback = 0
    static let allowedLookbackDays: [Int] = [1, 7, 30, 90, calendarMonthLookback]
    static let compactPopoverHeight: Double = 780
    static let compactPopoverHeightWithBudget: Double = 890
    static let compactPopoverHeightWithBothBudgets: Double = 900
    static let minimumPopoverHeight: Double = 400
    static let maximumPopoverHeight: Double = 2_000
    static let allowedPopoverHeights: [Double] = [compactPopoverHeight]
    static let defaultBudgetAlertThreshold: Double = 0.8
    static let minimumBudgetAlertThreshold: Double = 0.01
    static let maximumBudgetAlertThreshold: Double = 1.0

    static func isValidPopoverHeight(_ value: Double) -> Bool {
        value.isFinite && (minimumPopoverHeight...maximumPopoverHeight).contains(value)
    }

    static func parsePopoverHeight(_ rawValue: String) -> Double? {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              isValidPopoverHeight(value) else {
            return nil
        }
        return value
    }

    static func validatedPopoverHeight(_ value: Double?) -> Double {
        guard let value, isValidPopoverHeight(value) else { return `default`.popoverHeight }
        return value
    }

    static func validatedRefreshInterval(_ value: Double?) -> TimeInterval {
        guard let value, value.isFinite, allowedIntervals.contains(value) else {
            return defaultRefreshInterval
        }
        return value
    }

    static func isValidFingerprintCheckInterval(_ value: TimeInterval) -> Bool {
        guard value.isFinite,
              value >= minimumFingerprintCheckInterval,
              value <= maximumFingerprintCheckInterval else {
            return false
        }
        let minutes = value / 60
        return minutes.rounded() == minutes
    }

    static func parseFingerprintCheckInterval(_ rawValue: String) -> TimeInterval? {
        guard let minutes = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              minutes.isFinite,
              minutes.rounded() == minutes,
              (1...60).contains(minutes) else {
            return nil
        }
        return minutes * 60
    }

    static func validatedFingerprintCheckInterval(_ value: Double?) -> TimeInterval {
        guard let value, isValidFingerprintCheckInterval(value) else {
            return defaultFingerprintCheckInterval
        }
        return value
    }

    static func isValidPricingRefreshHours(_ value: Double) -> Bool {
        value.isFinite && (minimumPricingRefreshHours...maximumPricingRefreshHours).contains(value)
    }

    static func validatedPricingRefreshHours(_ value: Double?) -> Double {
        guard let value, isValidPricingRefreshHours(value) else {
            return defaultPricingRefreshHours
        }
        return value
    }

    static func effectivePopoverHeight(
        storedHeight: Double,
        dailyCostLimit: Double,
        monthlyCostLimit: Double,
        interfaceTextSize: InterfaceTextSize = .standard,
        contentHeight: Double? = nil
    ) -> Double {
        guard storedHeight == compactPopoverHeight else { return storedHeight }
        if let contentHeight, contentHeight.isFinite {
            return min(maximumPopoverHeight, max(minimumPopoverHeight, contentHeight))
        }
        let hasDailyBudget = validCostLimit(dailyCostLimit) > 0
        let hasMonthlyBudget = validCostLimit(monthlyCostLimit) > 0
        if hasDailyBudget && hasMonthlyBudget {
            return interfaceTextSize.compactPopoverHeightWithBothBudgets
        }
        if hasDailyBudget || hasMonthlyBudget {
            return interfaceTextSize.compactPopoverHeightWithBudget
        }
        return interfaceTextSize.compactPopoverHeight
    }

    static func validCostLimit(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    static func validBudgetAlertThreshold(_ value: Double?) -> Double {
        guard let value,
              value.isFinite,
              (minimumBudgetAlertThreshold...maximumBudgetAlertThreshold).contains(value) else {
            return defaultBudgetAlertThreshold
        }
        return value
    }

    static func parseBudgetAlertThreshold(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percentage = Double(trimmed), percentage.isFinite else { return nil }
        let minimumPercentage = minimumBudgetAlertThreshold * 100
        let maximumPercentage = maximumBudgetAlertThreshold * 100
        guard (minimumPercentage...maximumPercentage).contains(percentage) else { return nil }
        return percentage / 100
    }

    static func budgetAlertThresholdPercentage(_ value: Double) -> String {
        let percentage = validBudgetAlertThreshold(value) * 100
        if abs(percentage.rounded() - percentage) < 0.0001 {
            return String(Int(percentage.rounded()))
        }
        return String(format: "%.1f", percentage)
    }

    static func parseCostLimit(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    var refreshInterval: TimeInterval
    var sourceVerificationMode: SourceVerificationMode
    var fingerprintCheckInterval: TimeInterval
    var lookbackDays: Int
    var pricingRefreshHours: Double
    var automaticPricingRefresh: Bool
    var notificationFeedEnabled: Bool
    var developerMode: Bool
    var launchAtLogin: Bool
    var language: AppLanguage
    var popoverHeight: Double
    var customPricingPath: String
    var menuBarFormat: String
    var appearance: AppAppearance
    var interfaceTextSize: InterfaceTextSize
    var dailyCostLimit: Double
    var monthlyCostLimit: Double
    var budgetAlertThreshold: Double
    var surfaceStyle: AppSurfaceStyle

    static let `default` = MonitorSettings(
        refreshInterval: defaultRefreshInterval,
        sourceVerificationMode: .eventDriven,
        fingerprintCheckInterval: defaultFingerprintCheckInterval,
        lookbackDays: 30,
        pricingRefreshHours: defaultPricingRefreshHours,
        automaticPricingRefresh: true,
        notificationFeedEnabled: true,
        developerMode: false,
        launchAtLogin: false,
        language: .system,
        popoverHeight: compactPopoverHeight,
        customPricingPath: "",
        menuBarFormat: MenuBarFormat.defaultValue,
        appearance: .automatic,
        interfaceTextSize: .standard,
        dailyCostLimit: 0,
        monthlyCostLimit: 0,
        budgetAlertThreshold: defaultBudgetAlertThreshold,
        surfaceStyle: .solid
    )
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let prefix = AppIdentity.preferencesPrefix
    private let noPricingRevision = "__none__"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MonitorSettings {
        let storedMenuBarFormat = defaults.string(forKey: prefix + "menuBarFormat") ?? MonitorSettings.default.menuBarFormat
        let migratedMenuBarFormat = storedMenuBarFormat == MenuBarFormat.legacyDefaultValue
            ? MenuBarFormat.defaultValue
            : storedMenuBarFormat
        let parsedMenuBarFormat = MenuBarFormat(rawValue: migratedMenuBarFormat)
        return MonitorSettings(
            refreshInterval: MonitorSettings.validatedRefreshInterval(defaults.object(forKey: prefix + "refreshInterval") as? Double),
            sourceVerificationMode: SourceVerificationMode(rawValue: defaults.string(forKey: prefix + "sourceVerificationMode") ?? "") ?? MonitorSettings.default.sourceVerificationMode,
            fingerprintCheckInterval: MonitorSettings.validatedFingerprintCheckInterval(defaults.object(forKey: prefix + "fingerprintCheckInterval") as? Double),
            lookbackDays: defaults.object(forKey: prefix + "lookbackDays") as? Int ?? MonitorSettings.default.lookbackDays,
            pricingRefreshHours: MonitorSettings.validatedPricingRefreshHours(
                defaults.object(forKey: prefix + "pricingRefreshHours") as? Double
            ),
            automaticPricingRefresh: defaults.object(forKey: prefix + "automaticPricingRefresh") as? Bool ?? true,
            notificationFeedEnabled: defaults.object(forKey: prefix + "notificationFeedEnabled") as? Bool ?? true,
            developerMode: defaults.object(forKey: prefix + "developerMode") as? Bool ?? MonitorSettings.default.developerMode,
            launchAtLogin: defaults.object(forKey: prefix + "launchAtLogin") as? Bool ?? MonitorSettings.default.launchAtLogin,
            language: AppLanguage(rawValue: defaults.string(forKey: prefix + "language") ?? "") ?? .system,
            popoverHeight: MonitorSettings.validatedPopoverHeight(defaults.object(forKey: prefix + "popoverHeight") as? Double),
            customPricingPath: defaults.string(forKey: prefix + "customPricingPath") ?? "",
            menuBarFormat: parsedMenuBarFormat.isValid ? parsedMenuBarFormat.rawValue : MonitorSettings.default.menuBarFormat,
            appearance: AppAppearance(rawValue: defaults.string(forKey: prefix + "appearance") ?? "") ?? MonitorSettings.default.appearance,
            interfaceTextSize: InterfaceTextSize(rawValue: defaults.string(forKey: prefix + "interfaceTextSize") ?? "") ?? MonitorSettings.default.interfaceTextSize,
            dailyCostLimit: MonitorSettings.validCostLimit(defaults.object(forKey: prefix + "dailyCostLimit") as? Double),
            monthlyCostLimit: MonitorSettings.validCostLimit(defaults.object(forKey: prefix + "monthlyCostLimit") as? Double),
            budgetAlertThreshold: MonitorSettings.validBudgetAlertThreshold(defaults.object(forKey: prefix + "budgetAlertThreshold") as? Double),
            surfaceStyle: AppSurfaceStyle(rawValue: defaults.string(forKey: prefix + "surfaceStyle") ?? "") ?? MonitorSettings.default.surfaceStyle
        )
    }

    func save(_ settings: MonitorSettings) {
        defaults.set(settings.refreshInterval, forKey: prefix + "refreshInterval")
        defaults.set(settings.sourceVerificationMode.rawValue, forKey: prefix + "sourceVerificationMode")
        defaults.set(
            MonitorSettings.validatedFingerprintCheckInterval(settings.fingerprintCheckInterval),
            forKey: prefix + "fingerprintCheckInterval"
        )
        defaults.set(settings.lookbackDays, forKey: prefix + "lookbackDays")
        defaults.set(
            MonitorSettings.validatedPricingRefreshHours(settings.pricingRefreshHours),
            forKey: prefix + "pricingRefreshHours"
        )
        defaults.set(settings.automaticPricingRefresh, forKey: prefix + "automaticPricingRefresh")
        defaults.set(settings.notificationFeedEnabled, forKey: prefix + "notificationFeedEnabled")
        defaults.set(settings.developerMode, forKey: prefix + "developerMode")
        defaults.set(settings.launchAtLogin, forKey: prefix + "launchAtLogin")
        defaults.set(settings.language.rawValue, forKey: prefix + "language")
        defaults.set(settings.popoverHeight, forKey: prefix + "popoverHeight")
        defaults.set(settings.customPricingPath, forKey: prefix + "customPricingPath")
        defaults.set(settings.menuBarFormat, forKey: prefix + "menuBarFormat")
        defaults.set(settings.appearance.rawValue, forKey: prefix + "appearance")
        defaults.set(settings.interfaceTextSize.rawValue, forKey: prefix + "interfaceTextSize")
        defaults.set(MonitorSettings.validCostLimit(settings.dailyCostLimit), forKey: prefix + "dailyCostLimit")
        defaults.set(MonitorSettings.validCostLimit(settings.monthlyCostLimit), forKey: prefix + "monthlyCostLimit")
        defaults.set(
            MonitorSettings.validBudgetAlertThreshold(settings.budgetAlertThreshold),
            forKey: prefix + "budgetAlertThreshold"
        )
        defaults.set(settings.surfaceStyle.rawValue, forKey: prefix + "surfaceStyle")
    }

    func lastPricingAttemptAt() -> Date? {
        defaults.object(forKey: prefix + "lastPricingAttemptAt") as? Date
    }

    func pricingAttemptMatches(revision: String?) -> Bool {
        let expected = revision ?? noPricingRevision
        return defaults.string(forKey: prefix + "lastPricingAttemptRevision") == expected
    }

    func pricingAttemptMatches(revision: String?, modelCatalogRevision: String?) -> Bool {
        let expectedCatalogRevision = modelCatalogRevision ?? noPricingRevision
        return pricingAttemptMatches(revision: revision)
            && defaults.string(forKey: prefix + "lastPricingAttemptModelCatalogRevision") == expectedCatalogRevision
    }

    func pricingAttemptMatches(
        revision: String?,
        modelCatalogRevision: String?,
        engineRevision: String?
    ) -> Bool {
        let expectedRevision = revision ?? noPricingRevision
        let expectedCatalogRevision = modelCatalogRevision ?? noPricingRevision
        let storedRevision = defaults.string(forKey: prefix + "lastPricingAttemptRevision")
        let storedCatalogRevision = defaults.string(forKey: prefix + "lastPricingAttemptModelCatalogRevision")
        guard storedRevision == expectedRevision,
              storedCatalogRevision == expectedCatalogRevision else {
            return false
        }
        guard let engineRevision else { return true }
        return pricingEngineAttemptMatches(
            engineRevision: engineRevision,
            pricingRevision: revision,
            modelCatalogRevision: modelCatalogRevision
        )
    }

    func pricingEngineRevisionMatches(_ revision: String) -> Bool {
        defaults.string(forKey: prefix + "pricingEngineRevision") == revision
    }

    func pricingEngineAttemptMatches(
        engineRevision: String,
        pricingRevision: String?,
        modelCatalogRevision: String? = nil
    ) -> Bool {
        let pricing = pricingRevision ?? noPricingRevision
        let catalog = modelCatalogRevision ?? noPricingRevision
        let expected = engineRevision + ":" + pricing + ":" + catalog
        return defaults.string(forKey: prefix + "lastPricingEngineAttempt") == expected
    }

    func recordPricingAttempt(
        revision: String? = nil,
        modelCatalogRevision: String? = nil,
        engineRevision: String? = nil,
        at date: Date = Date()
    ) {
        defaults.set(date, forKey: prefix + "lastPricingAttemptAt")
        defaults.set(revision ?? noPricingRevision, forKey: prefix + "lastPricingAttemptRevision")
        defaults.set(
            modelCatalogRevision ?? noPricingRevision,
            forKey: prefix + "lastPricingAttemptModelCatalogRevision"
        )
        if let engineRevision {
            let pricing = revision ?? noPricingRevision
            let catalog = modelCatalogRevision ?? noPricingRevision
            defaults.set(
                engineRevision + ":" + pricing + ":" + catalog,
                forKey: prefix + "lastPricingEngineAttempt"
            )
        }
    }

    func recordPricingEngineRevision(_ revision: String) {
        defaults.set(revision, forKey: prefix + "pricingEngineRevision")
    }
}
