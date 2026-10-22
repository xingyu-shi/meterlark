import Foundation
import XCTest
@testable import MeterlarkApp

final class BudgetTests: XCTestCase {
    func testDisabledLimitsNeverAlert() {
        let metric = BudgetMetric(
            cost: 100,
            limit: 0,
            updatedAt: Date(),
            unknownPricingModels: [],
            threshold: BudgetStatus.alertThreshold
        )

        XCTAssertEqual(metric.level, .disabled)
        XCTAssertFalse(metric.isAlerting)
        XCTAssertNil(metric.progress)
    }

    func testAlertStartsAtExactlyEightyPercent() {
        let normal = BudgetMetric(
            cost: 79.99,
            limit: 100,
            updatedAt: Date(),
            unknownPricingModels: [],
            threshold: BudgetStatus.alertThreshold
        )
        let alert = BudgetMetric(
            cost: 80,
            limit: 100,
            updatedAt: Date(),
            unknownPricingModels: [],
            threshold: BudgetStatus.alertThreshold
        )

        XCTAssertEqual(normal.level, .normal)
        XCTAssertEqual(alert.level, .alert)
        XCTAssertEqual(alert.progress ?? -1, 0.8, accuracy: 0.0001)
    }

    func testUnknownPricingMakesBelowThresholdBudgetExplicitlyUncertain() {
        let metric = BudgetMetric(
            cost: 10,
            limit: 100,
            updatedAt: Date(),
            unknownPricingModels: ["unpriced-model"],
            threshold: BudgetStatus.alertThreshold
        )

        XCTAssertEqual(metric.level, .uncertain)
        XCTAssertFalse(metric.isAlerting)
        XCTAssertTrue(metric.isUncertain)
    }

    func testUnknownPricingRemainsVisibleWhenBudgetAlsoReachesAlertThreshold() {
        let metric = BudgetMetric(
            cost: 90,
            limit: 100,
            updatedAt: Date(),
            unknownPricingModels: ["unpriced-model"],
            threshold: BudgetStatus.alertThreshold
        )

        XCTAssertEqual(metric.level, .alert)
        XCTAssertTrue(metric.isAlerting)
        XCTAssertTrue(metric.hasUnknownPricing)
        XCTAssertFalse(metric.isUncertain)

        let status = BudgetStatus(daily: metric, monthly: metric)
        XCTAssertTrue(status.isAlerting)
        XCTAssertTrue(status.hasUncertainPricing)
        XCTAssertTrue(status.needsAttention)
    }

    func testBudgetStatusCanAlertDailyAndMonthlyIndependently() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now)
        var settings = MonitorSettings.default
        settings.dailyCostLimit = 10
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            queryScope: nil,
            days: [DailyUsage(period: todayPeriod(now), tokens: TokenTotals(inputTokens: 1), estimatedCost: 8)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 8,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: month,
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: []
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertTrue(status.daily.isAlerting)
        XCTAssertTrue(status.monthly.isAlerting)
        XCTAssertTrue(status.isAlerting)
    }

    func testMonthlyBudgetReplacesCalibratedTodayWithLiveToday() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            queryScope: nil,
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 12)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 12,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: month,
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: day,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now,
        )

        XCTAssertEqual(status.monthly.cost, 84, "the calibrated total must replace its old current-day portion")
        XCTAssertEqual(status.monthly.updatedAt, now)
    }

    func testMonthlyBudgetWaitsForUsageSnapshotCapturedAfterCalibration() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now,
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 5)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 5,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: day,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.monthly.cost, 80, "do not replace a newer calibration with an older live snapshot")
        XCTAssertEqual(status.monthly.updatedAt, now)
    }

    func testMonthlyBudgetDoesNotMixPricingRevisionsDuringRealtimeProjection() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: "new-pricing",
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 40)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 40,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now.addingTimeInterval(-60),
            customPricingRevision: "old-pricing",
            models: [],
            totalTokens: 1,
            estimatedCost: 100,
            unknownPricingModels: [],
            realtimeAnchorDay: day,
            realtimeAnchorTodayCost: 20
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.monthly.cost, 100, "old monthly pricing must not be combined with new daily pricing")
        XCTAssertEqual(status.monthly.updatedAt, monthly.generatedAt)
    }

    func testPreservedMonthlyBudgetKeepsTrustedCostAndUnknownsWithoutProjection() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            queryScope: CCUsageRunner.queryScope(for: 30, now: now),
            customPricingRevision: "pricing",
            modelCatalogRevision: "catalog",
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 40)],
            agents: [],
            models: [ModelUsage(
                agent: "codex",
                name: "live-unknown",
                tokens: TokenTotals(inputTokens: 1),
                estimatedCost: 0,
                hasKnownPricing: false
            )],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 40,
            unknownPricingModels: ["live-unknown"],
            pricingSource: .unknown
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now,
            customPricingRevision: "pricing",
            modelCatalogRevision: "catalog",
            pricingBasisPreserved: true,
            models: [MonthlyBudgetModel(
                agent: "codex",
                name: "catalog-model",
                tokens: TokenTotals(inputTokens: 10),
                estimatedCost: 80,
                hasKnownPricing: false
            )],
            totalTokens: 10,
            estimatedCost: 80,
            unknownPricingModels: ["catalog-model"],
            realtimeAnchorDay: day,
            realtimeAnchorTodayCost: 8
        )

        XCTAssertFalse(monthly.usesRealtimeProjection(using: snapshot, now: now))
        XCTAssertEqual(monthly.projectedCost(using: snapshot, now: now), 80)

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.monthly.cost, 80)
        XCTAssertEqual(status.monthly.updatedAt, monthly.generatedAt)
        XCTAssertEqual(status.monthly.unknownPricingModels, ["catalog-model"])
    }

    func testMonthlyBudgetWithoutRealtimeAnchorUsesLastKnownValue() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: []
        )
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            days: [DailyUsage(period: MonthlyBudgetSnapshot.dayPeriod(for: now), tokens: TokenTotals(inputTokens: 1), estimatedCost: 12)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 12,
            unknownPricingModels: []
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.monthly.cost, 80, "a legacy snapshot must not guess how much of its total belongs to today")
    }

    func testMonthlyBudgetUsesCompleteCurrentMonthUsageAsCanonicalValue() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100

        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: CCUsageRunner.queryScope(
                for: MonitorSettings.calendarMonthLookback,
                now: now
            ),
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 84)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 84,
            unknownPricingModels: []
        )
        let legacyMonthly = MonthlyBudgetSnapshot(
            month: month,
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: []
        )

        let resolution = MonthlyCostResolver.resolve(
            snapshot: snapshot,
            monthlySnapshot: legacyMonthly,
            now: now
        )
        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: legacyMonthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(resolution?.source, .liveUsage)
        XCTAssertEqual(resolution?.cost, 84)
        XCTAssertEqual(status.monthly.cost, 84, "the budget and current-month usage must use the same complete live scope")
    }

    func testMonthlyBudgetDoesNotTreatShortUsageScopeAsAFullMonth() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let day = MonthlyBudgetSnapshot.dayPeriod(for: now)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100

        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: CCUsageRunner.queryScope(for: 1, now: now),
            days: [DailyUsage(period: day, tokens: TokenTotals(inputTokens: 1), estimatedCost: 12)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 12,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: []
        )

        let resolution = MonthlyCostResolver.resolve(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            now: now
        )

        XCTAssertEqual(resolution?.source, .calibratedSnapshot)
        XCTAssertEqual(resolution?.cost, 80)
    }

    func testMonthlyBudgetDoesNotTreatEmptyCurrentMonthUsageAsZero() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: CCUsageRunner.queryScope(
                for: MonitorSettings.calendarMonthLookback,
                now: now
            ),
            days: [],
            agents: [],
            models: [],
            totalTokens: .zero,
            estimatedCost: 0,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 10,
            estimatedCost: 80,
            unknownPricingModels: []
        )

        let resolution = MonthlyCostResolver.resolve(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            now: now
        )

        XCTAssertEqual(resolution?.source, .calibratedSnapshot)
        XCTAssertEqual(resolution?.cost, 80)
    }

    func testMonthlyBudgetDoesNotProjectAcrossAChangedSnapshotTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 1))!
        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(
                since: "2026-08-01",
                until: currentDay,
                timeZone: "UTC",
                lookbackDays: 30
            ),
            days: [DailyUsage(period: currentDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 3)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 3,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: "2026-08",
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 10,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: "2026-08-20",
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 80)
    }

    func testMonthlyBudgetDoesNotProjectAcrossDaysMissingFromShortUsageScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 23))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 1))!
        let anchorDay = MonthlyBudgetSnapshot.dayPeriod(for: anchorDate, calendar: calendar)
        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100

        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(
                since: "2026-08-25",
                until: currentDay,
                timeZone: calendar.timeZone.identifier,
                lookbackDays: 7
            ),
            days: [DailyUsage(period: currentDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 3)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 3,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: "2026-08",
            generatedAt: anchorDate,
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: anchorDay,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 80, "a short scope must not skip unobserved days after the calibration anchor")
    }

    func testMonthlyBudgetCarriesTheCalibratedDayAcrossMidnight() {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 23))!
        let currentDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 1))!
        let anchorDay = MonthlyBudgetSnapshot.dayPeriod(for: anchorDate, calendar: calendar)
        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: currentDate, calendar: calendar)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: currentDate,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(
                since: anchorDay,
                until: currentDay,
                timeZone: calendar.timeZone.identifier,
                lookbackDays: 2
            ),
            days: [
                DailyUsage(period: anchorDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 8),
                DailyUsage(period: currentDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 3)
            ],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 2),
            estimatedCost: 11,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: anchorDate, calendar: calendar),
            generatedAt: anchorDate,
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: anchorDay,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: currentDate,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 83, "the calibrated day remains historical after midnight")
    }

    func testMonthlyBudgetAddsVisibleInterveningDaysAfterAQuietPeriod() {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 23))!
        let currentDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 1))!
        let anchorDay = MonthlyBudgetSnapshot.dayPeriod(for: anchorDate, calendar: calendar)
        let middleDay = "2026-08-18"
        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: currentDate, calendar: calendar)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: currentDate,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(
                since: anchorDay,
                until: currentDay,
                timeZone: calendar.timeZone.identifier,
                lookbackDays: 3
            ),
            days: [
                DailyUsage(period: middleDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 4),
                DailyUsage(period: currentDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 3)
            ],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 2),
            estimatedCost: 7,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: "2026-08",
            generatedAt: anchorDate,
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: anchorDay,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: currentDate,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 87)
    }

    func testMonthlyBudgetKeepsCalibratedValueUntilLiveScopeCoversToday() {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 23))!
        let staleDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 23))!
        let currentDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 1))!
        let anchorDay = MonthlyBudgetSnapshot.dayPeriod(for: anchorDate, calendar: calendar)
        let staleDay = MonthlyBudgetSnapshot.dayPeriod(for: staleDate, calendar: calendar)
        let staleScope = UsageQueryScope(
            since: "2026-08-20",
            until: staleDay,
            timeZone: calendar.timeZone.identifier,
            lookbackDays: 1
        )
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: staleDate,
            pricingUpdatedAt: staleDate,
            queryScope: staleScope,
            days: [DailyUsage(period: staleDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 4)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 4,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: "2026-08",
            generatedAt: anchorDate,
            pricingUpdatedAt: anchorDate,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: anchorDay,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: currentDate,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 80, "an older live scope must not partially project a new day")
    }

    func testMonthlyBudgetDoesNotProjectLegacySnapshotWithoutCurrentDayEvidence() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 1))!
        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar)
        let previousDay = MonthlyBudgetSnapshot.dayPeriod(
            for: calendar.date(byAdding: .day, value: -1, to: now)!,
            calendar: calendar
        )
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: nil,
            queryScope: nil,
            days: [DailyUsage(period: previousDay, tokens: TokenTotals(inputTokens: 1), estimatedCost: 5)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 5,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now, calendar: calendar),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: [],
            realtimeAnchorDay: currentDay,
            realtimeAnchorTodayCost: 8
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(status.monthly.cost, 80, "a legacy snapshot without today's coverage must not invent a zero current-day cost")
    }

    func testConfiguredThresholdControlsDailyAndMonthlyAlerting() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now)
        var settings = MonitorSettings.default
        settings.dailyCostLimit = 10
        settings.monthlyCostLimit = 100
        settings.budgetAlertThreshold = 0.9
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            queryScope: nil,
            days: [DailyUsage(period: todayPeriod(now), tokens: TokenTotals(inputTokens: 1), estimatedCost: 8.99)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 8.99,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: month,
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 89.99,
            unknownPricingModels: []
        )

        let belowThreshold = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertFalse(belowThreshold.daily.isAlerting)
        XCTAssertFalse(belowThreshold.monthly.isAlerting)

        settings.budgetAlertThreshold = 0.89
        let atThreshold = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertTrue(atThreshold.daily.isAlerting)
        XCTAssertTrue(atThreshold.monthly.isAlerting)
    }

    func testOldMonthDoesNotTriggerCurrentMonthAlert() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 1
        let oldMonth = MonthlyBudgetSnapshot(
            month: "2000-01",
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 100,
            unknownPricingModels: []
        )

        let status = BudgetStatus.evaluate(
            snapshot: .empty,
            monthlySnapshot: oldMonth,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.monthly.level, .noData)
        XCTAssertFalse(status.monthly.isAlerting)
    }

    func testUnknownPricingNamesArePreservedAcrossDailyAndMonthlyStatus() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        var settings = MonitorSettings.default
        settings.dailyCostLimit = 10
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            days: [DailyUsage(period: todayPeriod(now), tokens: TokenTotals(inputTokens: 1), estimatedCost: 1)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 1,
            unknownPricingModels: ["daily-unknown"]
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: 1,
            unknownPricingModels: ["monthly-unknown"]
        )

        let status = BudgetStatus.evaluate(snapshot: snapshot, monthlySnapshot: monthly, settings: settings, now: now)

        XCTAssertEqual(status.unknownPricingModels, ["daily-unknown", "monthly-unknown"])
    }

    func testDailyBudgetDoesNotCarryYesterdayUnknownPricingIntoToday() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        let today = todayPeriod(now)
        let yesterday = todayPeriod(now.addingTimeInterval(-86_400))
        var settings = MonitorSettings.default
        settings.dailyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            days: [
                DailyUsage(period: yesterday, tokens: TokenTotals(inputTokens: 20), estimatedCost: 4),
                DailyUsage(period: today, tokens: TokenTotals(inputTokens: 10), estimatedCost: 2)
            ],
            dailyModels: [
                DailyModelUsage(
                    period: yesterday,
                    agent: "codex",
                    name: "yesterday-unknown",
                    tokens: TokenTotals(inputTokens: 20),
                    estimatedCost: 0,
                    hasKnownPricing: false
                ),
                DailyModelUsage(
                    period: today,
                    agent: "codex",
                    name: "today-known",
                    tokens: TokenTotals(inputTokens: 10),
                    estimatedCost: 2,
                    hasKnownPricing: true
                )
            ],
            agents: [],
            models: [
                ModelUsage(
                    agent: "codex",
                    name: "today-known",
                    tokens: TokenTotals(inputTokens: 10),
                    estimatedCost: 2,
                    hasKnownPricing: true
                ),
                ModelUsage(
                    agent: "codex",
                    name: "yesterday-unknown",
                    tokens: TokenTotals(inputTokens: 20),
                    estimatedCost: 0,
                    hasKnownPricing: false
                )
            ],
            totalTokens: TokenTotals(inputTokens: 30),
            estimatedCost: 6,
            unknownPricingModels: ["yesterday-unknown"]
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.daily.unknownPricingModels, [])
        XCTAssertFalse(status.daily.hasUnknownPricing)
    }

    func testStaleMonthlyUnknownPricingDoesNotSurvivePricingRefresh() {
        let now = Date(timeIntervalSince1970: 1_755_456_000)
        var settings = MonitorSettings.default
        settings.monthlyCostLimit = 100
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            customPricingRevision: "new-pricing",
            days: [DailyUsage(
                period: todayPeriod(now),
                tokens: TokenTotals(inputTokens: 1),
                estimatedCost: 1
            )],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 1,
            unknownPricingModels: []
        )
        let monthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now.addingTimeInterval(-60),
            pricingUpdatedAt: now.addingTimeInterval(-60),
            customPricingRevision: "old-pricing",
            models: [],
            totalTokens: 1,
            estimatedCost: 80,
            unknownPricingModels: ["old-unknown"]
        )

        let status = BudgetStatus.evaluate(
            snapshot: snapshot,
            monthlySnapshot: monthly,
            settings: settings,
            now: now
        )

        XCTAssertEqual(status.unknownPricingModels, [])
    }

    private func todayPeriod(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
