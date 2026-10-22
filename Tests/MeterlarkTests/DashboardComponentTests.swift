import Foundation
import XCTest
@testable import MeterlarkApp

final class DashboardComponentTests: XCTestCase {
    func testMetricGridRejectsInvalidColumnsAndDuplicateIDs() {
        let tile = makeTile(id: "one")

        XCTAssertNil(MetricGridModel(columns: 0, tiles: [tile]))
        XCTAssertNil(MetricGridModel(columns: -1, tiles: [tile]))
        XCTAssertNil(MetricGridModel(
            columns: 2,
            tiles: [makeTile(id: "duplicate"), makeTile(id: "duplicate")]
        ))
    }

    func testMetricGridSupportsDifferentItemCountsWithoutPlaceholderTiles() {
        let one = tryUnwrap(MetricGridModel(columns: 1, tiles: [makeTile(id: "one")]))
        let two = tryUnwrap(MetricGridModel(
            columns: 2,
            tiles: [makeTile(id: "one"), makeTile(id: "two")]
        ))
        let four = tryUnwrap(MetricGridModel(
            columns: 2,
            tiles: (1...4).map { makeTile(id: "tile-\($0)") }
        ))
        let extraColumns = tryUnwrap(MetricGridModel(
            columns: 4,
            tiles: [makeTile(id: "one"), makeTile(id: "two")]
        ))
        let empty = tryUnwrap(MetricGridModel(columns: 2, tiles: []))

        XCTAssertEqual(one.tiles.count, 1)
        XCTAssertEqual(two.tiles.count, 2)
        XCTAssertEqual(four.tiles.count, 4)
        XCTAssertEqual(extraColumns.tiles.count, 2)
        XCTAssertTrue(empty.tiles.isEmpty)
    }

    func testProgressDerivesAndClampsFractionFromTypedValues() {
        XCTAssertEqual(makeProgress(current: 25, maximum: 100)!.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(makeProgress(current: -25, maximum: 100)!.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(makeProgress(current: 125, maximum: 100)!.progress, 1, accuracy: 0.0001)

        XCTAssertNil(makeProgress(current: 25, maximum: 0))
        XCTAssertNil(makeProgress(current: 25, maximum: -1))
        XCTAssertNil(makeProgress(current: 25, maximum: .infinity))
        XCTAssertNil(makeProgress(current: 25, maximum: .nan))
        XCTAssertNil(makeProgress(current: .infinity, maximum: 100))
        XCTAssertNil(makeProgress(current: .nan, maximum: 100))
    }

    func testProgressUnavailableItemRequiresAUsableMaximumAndDoesNotInventCurrent() {
        let item = ProgressUnavailableItemModel(
            id: "daily",
            label: DashboardText("Daily"),
            maximum: 100,
            message: DashboardText("Waiting"),
            status: DashboardStatus(kind: .noData, text: DashboardText("No data"))
        )

        XCTAssertEqual(item?.maximum, 100)
        XCTAssertNil(ProgressUnavailableItemModel(
            id: "invalid",
            label: DashboardText("Invalid"),
            maximum: .infinity,
            message: DashboardText("Waiting"),
            status: DashboardStatus(kind: .noData, text: DashboardText("No data"))
        ))
        XCTAssertNil(ProgressUnavailableItemModel(
            id: "wrong-status",
            label: DashboardText("Wrong status"),
            maximum: 100,
            message: DashboardText("Waiting"),
            status: DashboardStatus(kind: .normal, text: DashboardText("Normal"))
        ))
    }

    func testSummaryAdapterPreservesFourTileOrderAndTypedPrimaryValues() {
        let tokens = TokenTotals(inputTokens: 1_234, outputTokens: 567, cacheReadTokens: 89)
        let snapshot = makeSnapshot(tokens: tokens)
        let model = DashboardAdapters.summaryGrid(
            snapshot: snapshot,
            copy: L10n(language: .english)
        )

        XCTAssertEqual(model.columns, 2)
        XCTAssertEqual(model.tiles.map(\.id), ["today", "input", "output", "cache-read"])
        XCTAssertEqual(model.tiles.count, 4)

        guard case let .integer(value, display) = model.tiles[0].primary else {
            return XCTFail("Today tile must retain its integer value semantics")
        }
        XCTAssertEqual(value, tokens.totalTokens)
        XCTAssertEqual(display.text, NumberFormat.compact(tokens.totalTokens))
        XCTAssertEqual(display.spokenText, NumberFormat.grouped(tokens.totalTokens))
        XCTAssertEqual(model.tiles[0].detail?.text, "\(NumberFormat.compact(tokens.cacheReadTokens)) cache")
    }

    func testBudgetAdapterMapsDisabledAndNoDataWithoutFabricatingProgress() {
        let status = BudgetStatus(
            daily: makeBudgetMetric(cost: 10, limit: 0),
            monthly: makeBudgetMetric(cost: nil, limit: 100)
        )
        let model = DashboardAdapters.budgetList(
            status: status,
            alertLabel: "Alert at 80%",
            copy: L10n(language: .english)
        )

        XCTAssertNil(model.header.trailingStatus)
        guard case let .value(disabled) = model.items[0] else {
            return XCTFail("A disabled limit must be rendered as a value item")
        }
        XCTAssertEqual(disabled.status.kind, .disabled)
        XCTAssertEqual(disabled.value.text, "—")

        guard case let .progressUnavailable(noData) = model.items[1] else {
            return XCTFail("A valid limit with missing data must retain an empty progress track")
        }
        XCTAssertEqual(noData.status.kind, .noData)
        XCTAssertEqual(noData.maximum, 100)
        XCTAssertEqual(noData.message.text, "Waiting for monthly data")
        XCTAssertEqual(noData.accessibilityText, "Monthly budget, Waiting for monthly data")
    }

    func testBudgetAdapterTreatsNonFiniteCostAsNoData() {
        let status = BudgetStatus(
            daily: makeBudgetMetric(cost: .infinity, limit: 100),
            monthly: makeBudgetMetric(cost: .nan, limit: 100)
        )
        let model = DashboardAdapters.budgetList(
            status: status,
            alertLabel: "Alert at 80%",
            copy: L10n(language: .english)
        )

        XCTAssertNil(model.header.trailingStatus)
        XCTAssertTrue(model.items.allSatisfy { item in
            if case .progressUnavailable = item { return true }
            return false
        })
    }

    func testBudgetAdapterMapsNormalAndAlertRowsAndHeaderStatus() {
        let status = BudgetStatus(
            daily: makeBudgetMetric(cost: 50, limit: 100),
            monthly: makeBudgetMetric(cost: 80, limit: 100)
        )
        let model = DashboardAdapters.budgetList(
            status: status,
            alertLabel: "Alert at 80%",
            copy: L10n(language: .english)
        )

        XCTAssertEqual(model.header.trailingStatus?.status.kind, .alert)
        XCTAssertEqual(model.header.trailingStatus?.status.text.text, "Alert at 80%")

        guard case let .progress(normal) = model.items[0] else {
            return XCTFail("A below-threshold budget must be a progress item")
        }
        XCTAssertEqual(normal.status.kind, .normal)
        XCTAssertEqual(normal.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(normal.current, 50)
        XCTAssertEqual(normal.maximum, 100)

        guard case let .progress(alert) = model.items[1] else {
            return XCTFail("A threshold budget must be a progress item")
        }
        XCTAssertEqual(alert.status.kind, .alert)
        XCTAssertEqual(alert.progress, 0.8, accuracy: 0.0001)
    }

    func testBudgetAdapterLabelsUnknownPricingInsteadOfShowingNormalStatus() {
        let status = BudgetStatus(
            daily: makeBudgetMetric(cost: 10, limit: 100, unknownPricingModels: ["unpriced"]),
            monthly: makeBudgetMetric(cost: nil, limit: 0)
        )
        let model = DashboardAdapters.budgetList(
            status: status,
            alertLabel: "Alert at 80%",
            copy: L10n(language: .english)
        )

        XCTAssertEqual(
            model.header.trailingStatus?.status.text.text,
            "Incomplete: unknown-priced usage is excluded; total may be understated"
        )
        guard case let .progress(daily) = model.items[0] else {
            return XCTFail("An uncertain budget should retain its progress value")
        }
        XCTAssertEqual(daily.status.kind, .alert)
        XCTAssertEqual(
            daily.status.text.text,
            "Incomplete: unknown-priced usage is excluded; total may be understated"
        )
    }

    func testBudgetAdapterKeepsUnknownWarningWhenAlertThresholdIsAlsoReached() {
        let status = BudgetStatus(
            daily: makeBudgetMetric(cost: 90, limit: 100, unknownPricingModels: ["unpriced"]),
            monthly: makeBudgetMetric(cost: nil, limit: 0)
        )
        let model = DashboardAdapters.budgetList(
            status: status,
            alertLabel: "Alert at 80%",
            copy: L10n(language: .english)
        )

        XCTAssertEqual(
            model.header.trailingStatus?.status.text.text,
            "Alert at 80%; unknown-priced usage is excluded; total may be understated"
        )
        guard case let .progress(daily) = model.items[0] else {
            return XCTFail("An alerting budget must retain its progress value")
        }
        XCTAssertEqual(
            daily.status.text.text,
            "At threshold; unknown-priced usage is excluded; total may be understated"
        )
    }

    func testDashboardAccessibilityTextUsesExplicitSemanticRoles() {
        let dashboardText = DashboardText("1.2K", accessibilityText: "1,200")
        XCTAssertEqual(dashboardText.spokenText, "1,200")
        XCTAssertEqual(DashboardText("Header").spokenText, "Header")

        let tile = MetricTileModel(
            id: "tile",
            header: DashboardText("Header", accessibilityText: "Accessible header"),
            primary: .integer(value: 1_200, display: dashboardText),
            detail: DashboardText("detail", accessibilityText: "Accessible detail")
        )
        XCTAssertEqual(tile.accessibilityText, "Accessible header, 1,200, Accessible detail")

        let progress = makeProgress(current: 25, maximum: 100)!
        XCTAssertEqual(progress.accessibilityText, "Budget, 25 / 100, Below threshold")
        XCTAssertEqual(ProgressListItemModel.progress(progress).accessibilityText, progress.accessibilityText)

        let header = ProgressListHeader(
            title: DashboardText("Budgets", accessibilityText: "Accessible budgets"),
            subtitle: DashboardText("Details", accessibilityText: "Accessible details"),
            trailingStatus: DashboardStatusBadge(
                status: DashboardStatus(
                    kind: .alert,
                    text: DashboardText("Alert", accessibilityText: "Accessible alert")
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
        )
        XCTAssertEqual(header.accessibilityText, "Accessible budgets, Accessible details, Accessible alert")
    }

    func testComponentSourcesDoNotDependOnDomainOrLocalizationTypes() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let componentPaths = [
            "Sources/MeterlarkApp/DashboardComponentModels.swift",
            "Sources/MeterlarkApp/DashboardComponents.swift"
        ]
        let forbiddenTypes = ["MonitorStore", "UsageSnapshot", "BudgetMetric", "L10n"]

        for relativePath in componentPaths {
            let path = sourceRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: path, encoding: .utf8)
            for forbiddenType in forbiddenTypes {
                XCTAssertFalse(
                    source.contains(forbiddenType),
                    "\(relativePath) must not reference \(forbiddenType)"
                )
            }
        }
    }

    private func makeTile(id: String) -> MetricTileModel {
        MetricTileModel(
            id: id,
            header: DashboardText("Header"),
            primary: .integer(value: 1, display: DashboardText("1")),
            detail: DashboardText("Detail")
        )
    }

    private func makeProgress(current: Double, maximum: Double) -> ProgressItemModel? {
        ProgressItemModel(
            id: "budget",
            label: DashboardText("Budget"),
            current: current,
            maximum: maximum,
            value: DashboardText("25 / 100"),
            status: DashboardStatus(kind: .normal, text: DashboardText("Below threshold"))
        )
    }

    private func makeBudgetMetric(
        cost: Double?,
        limit: Double,
        unknownPricingModels: [String] = []
    ) -> BudgetMetric {
        BudgetMetric(
            cost: cost,
            limit: limit,
            updatedAt: Date(),
            unknownPricingModels: unknownPricingModels,
            threshold: BudgetStatus.alertThreshold
        )
    }

    private func makeSnapshot(tokens: TokenTotals) -> UsageSnapshot {
        let now = Date()
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            pricingUpdatedAt: now,
            days: [DailyUsage(period: todayPeriod(now), tokens: tokens, estimatedCost: 1)],
            agents: [],
            models: [],
            totalTokens: tokens,
            estimatedCost: 1,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )
    }

    private func todayPeriod(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected a valid model", file: file, line: line)
            fatalError("Expected a valid model")
        }
        return value
    }
}
