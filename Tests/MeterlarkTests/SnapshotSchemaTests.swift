import XCTest
@testable import MeterlarkApp

final class SnapshotSchemaTests: XCTestCase {
    func testLegacySnapshotDefaultsToCcusagePricingSource() throws {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": "2026-08-14T12:00:00Z",
          "days": [],
          "dailyModels": [],
          "agents": [],
          "models": [],
          "totalTokens": {"inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0},
          "estimatedCost": 0,
          "unknownPricingModels": []
        }
        """

        let snapshot = try decode(json)

        XCTAssertEqual(snapshot.schemaVersion, UsageSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.pricingSource, .ccusage)
    }

    func testLegacySnapshotWithUnknownModelsKeepsUnknownPricingSource() throws {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": "2026-08-14T12:00:00Z",
          "days": [],
          "dailyModels": [],
          "agents": [],
          "models": [],
          "totalTokens": {"inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0},
          "estimatedCost": 0,
          "unknownPricingModels": ["internal-model"]
        }
        """

        XCTAssertEqual(try decode(json).pricingSource, .unknown)
    }

    func testCurrentSnapshotPreservesQueryScopeAndCustomPricingRevision() throws {
        let json = """
        {
          "schemaVersion": 4,
          "generatedAt": "2026-08-17T12:00:00Z",
          "queryScope": {
            "since": "2026-08-17",
            "until": "2026-08-17",
            "timeZone": "America/Toronto",
            "lookbackDays": 1
          },
          "customPricingRevision": "abc123",
          "days": [],
          "dailyModels": [],
          "agents": [],
          "models": [],
          "totalTokens": {},
          "estimatedCost": 0,
          "unknownPricingModels": [],
          "pricingSource": "custom"
        }
        """

        let snapshot = try decode(json)

        XCTAssertEqual(snapshot.queryScope, UsageQueryScope(since: "2026-08-17", until: "2026-08-17", timeZone: "America/Toronto", lookbackDays: 1))
        XCTAssertEqual(snapshot.customPricingRevision, "abc123")
    }

    func testFutureSnapshotSchemaIsRejected() {
        let json = """
        {
          "schemaVersion": 999,
          "generatedAt": "2026-08-14T12:00:00Z"
        }
        """

        XCTAssertThrowsError(try decode(json))
    }

    func testNegativeSchemaVersionIsRejected() {
        let json = """
        {"schemaVersion": -1, "generatedAt": "2026-08-14T12:00:00Z"}
        """

        XCTAssertThrowsError(try decode(json))
    }

    func testDuplicateIdentifiersAreRejectedByValidation() throws {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": "2026-08-14T12:00:00Z",
          "days": [
            {"period": "2026-08-14", "tokens": {}, "estimatedCost": 0},
            {"period": "2026-08-14", "tokens": {}, "estimatedCost": 0}
          ],
          "totalTokens": {}
        }
        """

        let snapshot = try decode(json)
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testEmptyCandidateIsRejectedUnlessLookbackExplicitlyAllowsIt() {
        let previous = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-14", tokens: TokenTotals(inputTokens: 1), estimatedCost: 1)],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 1),
            estimatedCost: 1,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )
        let candidate = UsageSnapshot.empty

        XCTAssertFalse(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous, allowEmptyCandidate: true))
    }

    func testUnreadableSnapshotIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.SnapshotSchemaTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(baseURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not-json}".utf8).write(to: store.snapshotURL)

        XCTAssertNil(store.load())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("snapshot.invalid-") })
    }

    func testTokenTotalOverflowIsRejected() {
        let tokens = TokenTotals(inputTokens: Int64.max, outputTokens: 1)
        XCTAssertFalse(tokens.hasRepresentableTotal)
    }

    private func decode(_ json: String) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    }
}
