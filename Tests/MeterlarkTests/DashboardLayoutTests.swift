import Foundation
import XCTest
@testable import MeterlarkApp

final class DashboardLayoutTests: XCTestCase {
    func testCatalogDashboardComponentRequiresAnActiveProvider() {
        XCTAssertFalse(
            DashboardComponentAvailability.includesModelCatalog(activeCatalogProviderCount: 0)
        )
        XCTAssertTrue(
            DashboardComponentAvailability.includesModelCatalog(activeCatalogProviderCount: 1)
        )
    }

    func testLegacyNotificationFeedComponentIsDroppedFromDashboardLayouts() {
        let layout = DashboardLayout(
            componentOrder: [
                "builtIn.summary",
                DashboardLegacyComponentID.notificationFeed,
                "builtIn.daily"
            ]
        )
        let normalized = layout.normalized(for: [
            DashboardLayoutComponent(builtIn: .summary, title: "Summary"),
            DashboardLayoutComponent(builtIn: .daily, title: "Daily")
        ])

        XCTAssertEqual(normalized.componentOrder, ["builtIn.summary", "builtIn.daily"])
    }

    func testNormalizedLayoutKeepsBuiltInsAndAppendsOnlyActivePluginComponents() {
        let components = [
            DashboardLayoutComponent(builtIn: .summary, title: "Summary"),
            DashboardLayoutComponent(
                pluginID: "com.example.active",
                blockID: "two-grid",
                title: "Active · two-grid",
                blockKind: .metricGrid,
                itemCount: 2,
                defaultColumns: 2
            ),
            DashboardLayoutComponent(builtIn: .daily, title: "Daily")
        ]
        let layout = DashboardLayout(
            componentOrder: [
                DashboardLayoutComponent.legacyPluginComponentID(
                    pluginID: "com.example.not-installed",
                    blockID: "summary"
                ),
                "builtIn.daily",
                DashboardLayoutComponent.legacyPluginComponentID(
                    pluginID: "com.example.active",
                    blockID: "two-grid"
                )
            ],
            hiddenComponentIDs: ["builtIn.summary"]
        )

        let normalized = layout.normalized(for: components)

        XCTAssertEqual(
            normalized.componentOrder,
            ["builtIn.daily", components[1].id, "builtIn.summary"]
        )
        XCTAssertEqual(normalized.hiddenComponentIDs, ["builtIn.summary"])
        XCTAssertFalse(normalized.componentOrder.contains(
            DashboardLayoutComponent.legacyPluginComponentID(
                pluginID: "com.example.not-installed",
                blockID: "summary"
            )
        ))
    }

    func testPluginComponentIDsAreUnambiguousAndLegacyCollisionsAreIgnoredSafely() {
        let first = DashboardLayoutComponent(
            pluginID: "com.example",
            blockID: "foo.bar",
            title: "First",
            blockKind: .metricGrid,
            itemCount: 1,
            defaultColumns: 1
        )
        let second = DashboardLayoutComponent(
            pluginID: "com.example.foo",
            blockID: "bar",
            title: "Second",
            blockKind: .metricGrid,
            itemCount: 1,
            defaultColumns: 1
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(DashboardLayout.isValidIdentifier(first.id))
        XCTAssertTrue(DashboardLayout.isValidIdentifier(second.id))

        let maximumLengthComponent = DashboardLayoutComponent(
            pluginID: String(repeating: "p", count: 128),
            blockID: String(repeating: "b", count: 128),
            title: "Maximum length",
            blockKind: .progressList,
            itemCount: 1,
            defaultColumns: nil
        )
        XCTAssertTrue(DashboardLayout.isValidIdentifier(maximumLengthComponent.id))

        let legacyCollision = DashboardLayoutComponent.legacyPluginComponentID(
            pluginID: "com.example",
            blockID: "foo.bar"
        )
        XCTAssertEqual(
            legacyCollision,
            DashboardLayoutComponent.legacyPluginComponentID(
                pluginID: "com.example.foo",
                blockID: "bar"
            )
        )

        let normalized = DashboardLayout(
            componentOrder: [legacyCollision],
            hiddenComponentIDs: [legacyCollision],
            componentColumns: [legacyCollision: 1]
        ).normalized(for: [first, second])

        XCTAssertEqual(normalized.componentOrder, [first.id, second.id])
        XCTAssertTrue(normalized.hiddenComponentIDs.isEmpty)
        XCTAssertTrue(normalized.componentColumns.isEmpty)
    }

    func testCurrentPluginComponentColumnsWinOverLegacyColumnsDuringMigration() {
        let component = DashboardLayoutComponent(
            pluginID: "com.example.migration",
            blockID: "summary",
            title: "Summary",
            blockKind: .metricGrid,
            itemCount: 4,
            defaultColumns: 2
        )
        let legacyID = DashboardLayoutComponent.legacyPluginComponentID(
            pluginID: "com.example.migration",
            blockID: "summary"
        )
        let layout = DashboardLayout(
            componentColumns: [
                legacyID: 1,
                component.id: 4
            ]
        )

        XCTAssertEqual(layout.normalized(for: [component]).componentColumns[component.id], 4)
    }

    func testLayoutSupportsOneTwoAndFourColumnsWithoutChangingComponentIdentity() {
        let grid = DashboardLayoutComponent(
            pluginID: "com.example.plugin",
            blockID: "summary",
            title: "Summary",
            blockKind: .metricGrid,
            itemCount: 4,
            defaultColumns: 2
        )
        let components = [grid]

        for columns in [1, 2, 4] {
            let layout = DashboardLayout(
                componentOrder: [grid.id],
                componentColumns: [grid.id: columns]
            )
            let normalized = layout.normalized(for: components)
            XCTAssertEqual(normalized.componentColumns[grid.id], columns)
            XCTAssertEqual(normalized.componentOrder, [grid.id])
        }
    }

    func testColumnsAreClampedToTheNumberOfTiles() {
        let grid = DashboardLayoutComponent(
            pluginID: "com.example.plugin",
            blockID: "summary",
            title: "Summary",
            blockKind: .metricGrid,
            itemCount: 2,
            defaultColumns: 2
        )
        let layout = DashboardLayout(
            componentOrder: [grid.id],
            componentColumns: [grid.id: 4]
        )

        XCTAssertEqual(layout.normalized(for: [grid]).componentColumns[grid.id], 2)
    }

    func testLayoutStoreRoundTripsAndMalformedStateFallsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.DashboardLayoutTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DashboardLayoutStore(baseURL: root)
        let layout = DashboardLayout(
            componentOrder: ["builtIn.daily", "builtIn.summary"],
            hiddenComponentIDs: ["builtIn.budget"],
            componentColumns: ["builtIn.summary": 1]
        )
        try store.save(layout)
        XCTAssertEqual(try store.load(), layout)

        try Data("{\"layoutVersion\":999}".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.loadOrDefault(), .default)
    }

    func testEstimatedHeightChangesWithVisibleComponentsAndGridColumns() {
        let summary = DashboardLayoutComponent(builtIn: .summary, title: "Summary")
        let daily = DashboardLayoutComponent(builtIn: .daily, title: "Daily")
        let components = [summary, daily]
        let oneColumn = DashboardLayout(
            componentOrder: components.map(\.id),
            componentColumns: [summary.id: 1]
        )
        let twoColumns = DashboardLayout(
            componentOrder: components.map(\.id),
            componentColumns: [summary.id: 2]
        )

        let oneColumnHeight = DashboardLayoutMetrics.estimatedPopoverHeight(
            components: components,
            layout: oneColumn,
            interfaceTextSize: .standard
        )
        let twoColumnHeight = DashboardLayoutMetrics.estimatedPopoverHeight(
            components: components,
            layout: twoColumns,
            interfaceTextSize: .standard
        )

        XCTAssertGreaterThan(oneColumnHeight, twoColumnHeight)
        XCTAssertGreaterThan(
            DashboardLayoutMetrics.estimatedPopoverHeight(
                components: [daily],
                layout: DashboardLayout(componentOrder: [daily.id]),
                interfaceTextSize: .standard
            ),
            MonitorSettings.minimumPopoverHeight - 1
        )
    }
}
