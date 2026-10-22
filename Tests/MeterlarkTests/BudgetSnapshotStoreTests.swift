import Foundation
import XCTest
@testable import MeterlarkApp

final class BudgetSnapshotStoreTests: XCTestCase {
    func testMonthlyBudgetSnapshotRoundTripsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.BudgetSnapshotStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BudgetSnapshotStore(baseURL: directory)
        let snapshot = MonthlyBudgetSnapshot(
            month: "2026-08",
            generatedAt: Date(timeIntervalSince1970: 100),
            pricingUpdatedAt: Date(timeIntervalSince1970: 90),
            customPricingRevision: "revision",
            modelCatalogRevision: "catalog-revision",
            pricingBasisPreserved: true,
            models: [MonthlyBudgetModel(
                agent: "codex",
                name: "model",
                tokens: TokenTotals(inputTokens: 10),
                estimatedCost: 2.5,
                hasKnownPricing: true,
                pricingSource: .mixed,
                pricingProviderIDs: ["provider-b", "provider-a"],
                pricingTierThreshold: 200_000,
                pricingBackendThreshold: 200_000
            )],
            totalTokens: 10,
            estimatedCost: 2.5,
            unknownPricingModels: [],
            realtimeAnchorDay: "2026-08-18",
            realtimeAnchorTodayCost: 1.5
        )

        try store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    func testInvalidMonthlyBudgetSnapshotIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.BudgetSnapshotStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BudgetSnapshotStore(baseURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"month\":\"not-a-month\"}".utf8).write(to: store.snapshotURL)

        XCTAssertNil(store.load())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("monthly-budget.invalid-") })
    }

    func testInvalidRealtimeAnchorDateIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.BudgetSnapshotStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BudgetSnapshotStore(baseURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = """
        {
          "schemaVersion": 2,
          "month": "2026-02",
          "generatedAt": "1970-01-01T00:01:40Z",
          "pricingUpdatedAt": null,
          "customPricingRevision": null,
          "models": [],
          "totalTokens": 10,
          "estimatedCost": 2.5,
          "unknownPricingModels": [],
          "realtimeAnchorDay": "2026-02-31",
          "realtimeAnchorTodayCost": 1.5
        }
        """
        try Data(invalid.utf8).write(to: store.snapshotURL)

        XCTAssertNil(store.load())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("monthly-budget.invalid-") })
    }

    func testVersionOneSnapshotMigratesWithoutInventingRealtimeAnchor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.BudgetSnapshotStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BudgetSnapshotStore(baseURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {
          "schemaVersion": 1,
          "month": "2026-08",
          "generatedAt": "1970-01-01T00:01:40Z",
          "pricingUpdatedAt": "1970-01-01T00:01:30Z",
          "customPricingRevision": null,
          "models": [],
          "totalTokens": 10,
          "estimatedCost": 2.5,
          "unknownPricingModels": []
        }
        """
        try Data(legacy.utf8).write(to: store.snapshotURL)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schemaVersion, MonthlyBudgetSnapshot.currentSchemaVersion)
        XCTAssertNil(loaded.realtimeAnchorDay)
        XCTAssertNil(loaded.realtimeAnchorTodayCost)
        XCTAssertEqual(loaded.estimatedCost, 2.5, accuracy: 0.0001)
    }

    func testLegacyMonthlySnapshotDefaultsNewPricingProvenanceFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.BudgetSnapshotStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BudgetSnapshotStore(baseURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {
          "schemaVersion": 3,
          "month": "2026-08",
          "generatedAt": "1970-01-01T00:01:40Z",
          "pricingUpdatedAt": "1970-01-01T00:01:30Z",
          "customPricingRevision": "legacy-pricing",
          "models": [{
            "agent": "codex",
            "name": "legacy-model",
            "tokens": {"inputTokens": 10},
            "estimatedCost": 2.5,
            "hasKnownPricing": true
          }],
          "totalTokens": 10,
          "estimatedCost": 2.5,
          "unknownPricingModels": [],
          "realtimeAnchorDay": "2026-08-01",
          "realtimeAnchorTodayCost": 1.5
        }
        """
        try Data(legacy.utf8).write(to: store.snapshotURL)

        let loaded = try XCTUnwrap(store.load())
        let model = try XCTUnwrap(loaded.models.first)
        XCTAssertEqual(loaded.schemaVersion, MonthlyBudgetSnapshot.currentSchemaVersion)
        XCTAssertNil(loaded.modelCatalogRevision)
        XCTAssertFalse(loaded.pricingBasisPreserved)
        XCTAssertEqual(model.pricingSource, .ccusage)
        XCTAssertTrue(model.pricingProviderIDs.isEmpty)
        XCTAssertNil(model.pricingTierThreshold)
        XCTAssertNil(model.pricingBackendThreshold)
    }
}
