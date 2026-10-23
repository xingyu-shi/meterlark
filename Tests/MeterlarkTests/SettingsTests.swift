import XCTest
@testable import MeterlarkApp

final class SettingsTests: XCTestCase {
    func testUsageRefreshPresetsRemoveLegacyThirtySecondOption() {
        XCTAssertEqual(MonitorSettings.allowedIntervals, [60, 300, 900, 1_800, 3_600])
        XCTAssertFalse(MonitorSettings.allowedIntervals.contains(30))
        XCTAssertEqual(MonitorSettings.validatedRefreshInterval(30), MonitorSettings.defaultRefreshInterval)
    }

    func testPeriodicFingerprintIntervalValidationAndParsing() {
        XCTAssertTrue(MonitorSettings.isValidFingerprintCheckInterval(60))
        XCTAssertTrue(MonitorSettings.isValidFingerprintCheckInterval(420))
        XCTAssertTrue(MonitorSettings.isValidFingerprintCheckInterval(3_600))
        XCTAssertFalse(MonitorSettings.isValidFingerprintCheckInterval(30))
        XCTAssertFalse(MonitorSettings.isValidFingerprintCheckInterval(90))
        XCTAssertFalse(MonitorSettings.isValidFingerprintCheckInterval(3_601))
        XCTAssertFalse(MonitorSettings.isValidFingerprintCheckInterval(.nan))
        XCTAssertEqual(MonitorSettings.parseFingerprintCheckInterval(" 7 "), 420)
        XCTAssertNil(MonitorSettings.parseFingerprintCheckInterval("0"))
        XCTAssertNil(MonitorSettings.parseFingerprintCheckInterval("1.5"))
        XCTAssertNil(MonitorSettings.parseFingerprintCheckInterval("61"))
        XCTAssertNil(MonitorSettings.parseFingerprintCheckInterval("NaN"))
    }

    func testPricingRefreshHoursRejectsUnsafeCadences() {
        XCTAssertTrue(MonitorSettings.isValidPricingRefreshHours(1))
        XCTAssertTrue(MonitorSettings.isValidPricingRefreshHours(24 * 365))
        XCTAssertFalse(MonitorSettings.isValidPricingRefreshHours(0))
        XCTAssertFalse(MonitorSettings.isValidPricingRefreshHours(-1))
        XCTAssertFalse(MonitorSettings.isValidPricingRefreshHours(.nan))
        XCTAssertFalse(MonitorSettings.isValidPricingRefreshHours(.infinity))
        XCTAssertFalse(MonitorSettings.isValidPricingRefreshHours(24 * 366))
        XCTAssertEqual(
            MonitorSettings.validatedPricingRefreshHours(0),
            MonitorSettings.defaultPricingRefreshHours
        )
    }

    func testInvalidPricingRefreshHoursMigrateToSafeDefault() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.0, forKey: "Meterlark.pricingRefreshHours")
        XCTAssertEqual(
            SettingsStore(defaults: defaults).load().pricingRefreshHours,
            MonitorSettings.defaultPricingRefreshHours
        )

        var settings = SettingsStore(defaults: defaults).load()
        settings.pricingRefreshHours = .infinity
        SettingsStore(defaults: defaults).save(settings)
        XCTAssertEqual(
            SettingsStore(defaults: defaults).load().pricingRefreshHours,
            MonitorSettings.defaultPricingRefreshHours
        )
    }

    func testVerificationModeAndCustomFingerprintIntervalPersist() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertEqual(settings.sourceVerificationMode, .eventDriven)
        XCTAssertEqual(settings.fingerprintCheckInterval, MonitorSettings.defaultFingerprintCheckInterval)

        settings.sourceVerificationMode = .periodicFingerprint
        settings.fingerprintCheckInterval = 420
        store.save(settings)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.sourceVerificationMode, .periodicFingerprint)
        XCTAssertEqual(reloaded.fingerprintCheckInterval, 420)
    }

    func testLegacyUsageIntervalAndInvalidFingerprintIntervalMigrateToSafeDefaults() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(30.0, forKey: "Meterlark.refreshInterval")
        defaults.set(30.0, forKey: "Meterlark.fingerprintCheckInterval")

        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.refreshInterval, MonitorSettings.defaultRefreshInterval)
        XCTAssertEqual(settings.fingerprintCheckInterval, MonitorSettings.defaultFingerprintCheckInterval)
    }

    func testDefaultPopoverHeightUsesCompactSize() {
        XCTAssertEqual(MonitorSettings.default.popoverHeight, MonitorSettings.compactPopoverHeight)
        XCTAssertEqual(MonitorSettings.compactPopoverHeight, 780)
        XCTAssertEqual(MonitorSettings.allowedPopoverHeights, [MonitorSettings.compactPopoverHeight])
    }

    func testCompactPopoverHeightKeeps780PointSetting() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(780.0, forKey: "Meterlark.popoverHeight")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().popoverHeight, MonitorSettings.compactPopoverHeight)
    }

    func testCustomPopoverHeightLoadsFromSettings() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(790.0, forKey: "Meterlark.popoverHeight")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().popoverHeight, 790)
    }

    func testPopoverHeightValidationAcceptsCustomValuesAndRejectsUnsafeValues() {
        XCTAssertTrue(MonitorSettings.isValidPopoverHeight(790))
        XCTAssertTrue(MonitorSettings.isValidPopoverHeight(MonitorSettings.minimumPopoverHeight))
        XCTAssertTrue(MonitorSettings.isValidPopoverHeight(MonitorSettings.maximumPopoverHeight))
        XCTAssertFalse(MonitorSettings.isValidPopoverHeight(399))
        XCTAssertFalse(MonitorSettings.isValidPopoverHeight(2_001))
        XCTAssertFalse(MonitorSettings.isValidPopoverHeight(.nan))
        XCTAssertFalse(MonitorSettings.isValidPopoverHeight(.infinity))
        XCTAssertEqual(MonitorSettings.parsePopoverHeight(" 920 "), 920)
        XCTAssertNil(MonitorSettings.parsePopoverHeight("not-a-height"))
    }

    func testPopoverHeightPersistsAcrossSettingsLoads() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.popoverHeight = 920
        store.save(settings)

        XCTAssertEqual(store.load().popoverHeight, 920)
    }

    func testCompactPopoverHeightAdaptsToConfiguredBudgets() {
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: MonitorSettings.compactPopoverHeight,
                dailyCostLimit: 0,
                monthlyCostLimit: 0
            ),
            780
        )
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: MonitorSettings.compactPopoverHeight,
                dailyCostLimit: 10,
                monthlyCostLimit: 0
            ),
            890
        )
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: MonitorSettings.compactPopoverHeight,
                dailyCostLimit: 0,
                monthlyCostLimit: 10
            ),
            890
        )
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: MonitorSettings.compactPopoverHeight,
                dailyCostLimit: 10,
                monthlyCostLimit: 10
            ),
            900
        )
    }

    func testCustomPopoverHeightIsNotChangedByBudgets() {
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: 920,
                dailyCostLimit: 10,
                monthlyCostLimit: 10
            ),
            920
        )
    }

    func testFitContentHeightUsesMeasuredContentAndCapsAtTheScreen() {
        for measuredHeight in [740.0, 1_080.0] {
            XCTAssertEqual(
                MonitorSettings.effectivePopoverHeight(
                    storedHeight: MonitorSettings.compactPopoverHeight,
                    dailyCostLimit: 0,
                    monthlyCostLimit: 0,
                    contentHeight: measuredHeight,
                    maximumVisibleHeight: 960
                ),
                min(measuredHeight, 960)
            )
        }
    }

    func testFixedHeightFitsSmallScreensWithoutUsingContentHeight() {
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: 940,
                dailyCostLimit: 0,
                monthlyCostLimit: 0,
                contentHeight: 1_200,
                maximumVisibleHeight: 700
            ),
            700
        )
    }

    func testCustomPricingPathPersistsAcrossSettingsLoads() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.customPricingPath = "/tmp/custom-pricing.json"
        store.save(settings)

        XCTAssertEqual(store.load().customPricingPath, "/tmp/custom-pricing.json")
    }

    func testBudgetLimitsDefaultToZeroAndPersist() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertEqual(settings.dailyCostLimit, 0)
        XCTAssertEqual(settings.monthlyCostLimit, 0)
        XCTAssertEqual(settings.budgetAlertThreshold, MonitorSettings.defaultBudgetAlertThreshold)
        XCTAssertEqual(settings.surfaceStyle, .solid)

        settings.dailyCostLimit = 25.5
        settings.monthlyCostLimit = 300
        settings.budgetAlertThreshold = 0.65
        settings.surfaceStyle = .glass
        store.save(settings)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.dailyCostLimit, 25.5)
        XCTAssertEqual(reloaded.monthlyCostLimit, 300)
        XCTAssertEqual(reloaded.budgetAlertThreshold, 0.65)
        XCTAssertEqual(reloaded.surfaceStyle, .glass)
    }

    func testInvalidBudgetLimitsFallBackToZero() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-1, forKey: "Meterlark.dailyCostLimit")
        defaults.set(Double.nan, forKey: "Meterlark.monthlyCostLimit")
        defaults.set(0, forKey: "Meterlark.budgetAlertThreshold")
        defaults.set("not-a-surface", forKey: "Meterlark.surfaceStyle")

        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.dailyCostLimit, 0)
        XCTAssertEqual(settings.monthlyCostLimit, 0)
        XCTAssertEqual(settings.budgetAlertThreshold, MonitorSettings.defaultBudgetAlertThreshold)
        XCTAssertEqual(settings.surfaceStyle, .solid)
    }

    func testCostLimitParserSupportsEmptyAndRejectsUnsafeValues() {
        XCTAssertEqual(MonitorSettings.parseCostLimit(""), 0)
        XCTAssertEqual(MonitorSettings.parseCostLimit(" 25.50 "), 25.5)
        XCTAssertNil(MonitorSettings.parseCostLimit("-1"))
        XCTAssertNil(MonitorSettings.parseCostLimit("NaN"))
        XCTAssertNil(MonitorSettings.parseCostLimit("infinity"))
    }

    func testBudgetAlertThresholdParserUsesPercentages() {
        XCTAssertEqual(MonitorSettings.parseBudgetAlertThreshold("65"), 0.65)
        XCTAssertEqual(MonitorSettings.parseBudgetAlertThreshold(" 99.5 "), 0.995)
        XCTAssertNil(MonitorSettings.parseBudgetAlertThreshold("0"))
        XCTAssertNil(MonitorSettings.parseBudgetAlertThreshold("100.1"))
        XCTAssertNil(MonitorSettings.parseBudgetAlertThreshold("NaN"))
        XCTAssertEqual(MonitorSettings.budgetAlertThresholdPercentage(0.8), "80")
        XCTAssertEqual(MonitorSettings.budgetAlertThresholdPercentage(0.995), "99.5")
    }

    func testDeveloperModeDefaultsToOffAndPersists() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertFalse(settings.developerMode)

        settings.developerMode = true
        store.save(settings)

        XCTAssertTrue(store.load().developerMode)
    }

    func testAppearanceDefaultsToAutomaticAndPersists() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertEqual(settings.appearance, .automatic)

        settings.appearance = .dark
        store.save(settings)

        XCTAssertEqual(store.load().appearance, .dark)
    }

    func testInterfaceTextSizePresetsExposeStableScalesAndReadableLayoutMetrics() {
        XCTAssertEqual(InterfaceTextSize.standard.scale, 1.0)
        XCTAssertEqual(InterfaceTextSize.large.scale, 1.10)
        XCTAssertEqual(InterfaceTextSize.extraLarge.scale, 1.20)
        XCTAssertEqual(InterfaceTextSize.largest.scale, 1.30)
        XCTAssertEqual(InterfaceTextSize.standard.percentage, 100)
        XCTAssertEqual(InterfaceTextSize.largest.percentage, 130)
        XCTAssertLessThan(InterfaceTextSize.standard.popoverWidth, InterfaceTextSize.largest.popoverWidth)
        XCTAssertLessThan(InterfaceTextSize.standard.chartHeight, InterfaceTextSize.largest.chartHeight)
        XCTAssertGreaterThanOrEqual(InterfaceTextSize.standard.compactPopoverHeight, 780)
        XCTAssertEqual(InterfaceTextSize.extraLarge.compactPopoverHeight, 855)
        XCTAssertEqual(InterfaceTextSize.largest.compactPopoverHeight, 890)
        XCTAssertEqual(InterfaceTextSize.extraLarge.compactPopoverHeightWithBudget, 985)
        XCTAssertEqual(InterfaceTextSize.largest.compactPopoverHeightWithBudget, 1_030)
        XCTAssertEqual(InterfaceTextSize.extraLarge.compactPopoverHeightWithBothBudgets, 995)
        XCTAssertEqual(InterfaceTextSize.largest.compactPopoverHeightWithBothBudgets, 1_040)
        XCTAssertLessThan(InterfaceTextSize.standard.budgetSettingsWidth, InterfaceTextSize.largest.budgetSettingsWidth)
        XCTAssertLessThan(InterfaceTextSize.standard.budgetSettingsHeight, InterfaceTextSize.largest.budgetSettingsHeight)
    }

    func testInterfaceTextSizeDefaultsToStandardAndPersists() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertEqual(settings.interfaceTextSize, .standard)

        settings.interfaceTextSize = .largest
        store.save(settings)

        XCTAssertEqual(store.load().interfaceTextSize, .largest)
    }

    func testInvalidInterfaceTextSizeFallsBackToStandard() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-text-size", forKey: "Meterlark.interfaceTextSize")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().interfaceTextSize, .standard)
    }

    func testLargeTextUsesScaledCompactHeightButPreservesCustomHeight() {
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: MonitorSettings.compactPopoverHeight,
                dailyCostLimit: 0,
                monthlyCostLimit: 0,
                interfaceTextSize: .largest
            ),
            InterfaceTextSize.largest.compactPopoverHeight
        )
        XCTAssertEqual(
            MonitorSettings.effectivePopoverHeight(
                storedHeight: 920,
                dailyCostLimit: 10,
                monthlyCostLimit: 10,
                interfaceTextSize: .largest
            ),
            920
        )
    }

    func testMenuBarFormatDefaultsToLogoAndCostAndPersists() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertEqual(settings.menuBarFormat, "[logo]$[cost]")
        settings.menuBarFormat = "[logo] · $[cost:2]"
        store.save(settings)

        XCTAssertEqual(store.load().menuBarFormat, "[logo] · $[cost:2]")
    }

    func testLegacyLogoOnlyDefaultMigratesToLogoAndCost() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(MenuBarFormat.legacyDefaultValue, forKey: "Meterlark.menuBarFormat")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().menuBarFormat, MenuBarFormat.defaultValue)
    }

    func testInvalidStoredMenuBarFormatFallsBackToDefault() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("[unknown]", forKey: "Meterlark.menuBarFormat")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().menuBarFormat, MenuBarFormat.defaultValue)
    }

    func testCurrentCalendarMonthIsAnAvailableLookback() {
        XCTAssertTrue(MonitorSettings.allowedLookbackDays.contains(MonitorSettings.calendarMonthLookback))
    }

    func testUsageRefreshIntervalIsMeasuredFromRefreshStart() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(RefreshSchedule.isUsageRefreshDue(lastStartedAt: nil, now: start, interval: 60))
        XCTAssertFalse(RefreshSchedule.isUsageRefreshDue(lastStartedAt: start, now: start.addingTimeInterval(59.9), interval: 60))
        XCTAssertTrue(RefreshSchedule.isUsageRefreshDue(lastStartedAt: start, now: start.addingTimeInterval(60), interval: 60))
    }

    func testInvalidStoredRefreshIntervalFallsBackToDefault() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "Meterlark.refreshInterval")

        XCTAssertEqual(SettingsStore(defaults: defaults).load().refreshInterval, MonitorSettings.defaultRefreshInterval)
    }

    func testPricingAttemptRevisionPreventsRepeatedMismatchRetries() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.pricingAttemptMatches(revision: "new-revision"))

        store.recordPricingAttempt(revision: "new-revision", modelCatalogRevision: "catalog-revision")
        XCTAssertTrue(store.pricingAttemptMatches(revision: "new-revision"))
        XCTAssertTrue(store.pricingAttemptMatches(
            revision: "new-revision",
            modelCatalogRevision: "catalog-revision"
        ))
        XCTAssertFalse(store.pricingAttemptMatches(revision: "older-revision"))
        XCTAssertFalse(store.pricingAttemptMatches(
            revision: "new-revision",
            modelCatalogRevision: "older-catalog-revision"
        ))

        store.recordPricingAttempt()
        XCTAssertTrue(store.pricingAttemptMatches(revision: nil))
        XCTAssertTrue(store.pricingAttemptMatches(revision: nil, modelCatalogRevision: nil))
    }

    func testPricingEngineRevisionTracksAttemptsAndSuccessfulRefreshes() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.pricingEngineRevisionMatches("ccusage-config-v1"))
        XCTAssertFalse(store.pricingEngineAttemptMatches(
            engineRevision: "ccusage-config-v1",
            pricingRevision: "pricing-v1"
        ))

        store.recordPricingAttempt(
            revision: "pricing-v1",
            engineRevision: "ccusage-config-v1"
        )
        XCTAssertTrue(store.pricingEngineAttemptMatches(
            engineRevision: "ccusage-config-v1",
            pricingRevision: "pricing-v1"
        ))
        XCTAssertFalse(store.pricingEngineRevisionMatches("ccusage-config-v1"))

        store.recordPricingEngineRevision("ccusage-config-v1")
        XCTAssertTrue(store.pricingEngineRevisionMatches("ccusage-config-v1"))
    }

    func testLegacyPricingAttemptWithoutCatalogRevisionIsReopenedOnceByTheNewGate() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Date(timeIntervalSince1970: 100), forKey: "Meterlark.lastPricingAttemptAt")
        defaults.set("legacy-pricing", forKey: "Meterlark.lastPricingAttemptRevision")
        defaults.set("ccusage-config-v1", forKey: "Meterlark.pricingEngineRevision")

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(
            store.pricingAttemptMatches(
                revision: "legacy-pricing",
                modelCatalogRevision: nil,
                engineRevision: "ccusage-config-v2"
            ),
            "old defaults without the catalog-attempt field must not be treated as a completed v2 attempt"
        )

        store.recordPricingAttempt(
            revision: "legacy-pricing",
            modelCatalogRevision: nil,
            engineRevision: "ccusage-config-v2",
            at: Date(timeIntervalSince1970: 200)
        )
        XCTAssertTrue(
            store.pricingAttemptMatches(
                revision: "legacy-pricing",
                modelCatalogRevision: nil,
                engineRevision: "ccusage-config-v2"
            )
        )
        XCTAssertEqual(store.lastPricingAttemptAt(), Date(timeIntervalSince1970: 200))
    }

    func testNilCatalogRevisionHasAStablePersistedAttemptIdentity() {
        let suiteName = "Meterlark.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.recordPricingAttempt(
            revision: nil,
            modelCatalogRevision: nil,
            engineRevision: "ccusage-config-v2",
            at: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(
            store.pricingAttemptMatches(
                revision: nil,
                modelCatalogRevision: nil,
                engineRevision: "ccusage-config-v2"
            )
        )
        XCTAssertFalse(
            store.pricingAttemptMatches(
                revision: nil,
                modelCatalogRevision: "catalog-revision",
                engineRevision: "ccusage-config-v2"
            )
        )
    }
}
