import XCTest
@testable import MeterlarkApp

final class AgentFilterTests: XCTestCase {
    private func response(claudeCost: Double = 2.75) throws -> CCUsageResponse {
        try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {
          "daily": [
            {
              "agent": "all",
              "period": "2026-08-17",
              "agents": [
                {
                  "agent": "codex",
                  "inputTokens": 100,
                  "outputTokens": 20,
                  "totalTokens": 120,
                  "totalCost": 1.25,
                  "modelBreakdowns": [{"modelName": "model-a", "inputTokens": 100, "outputTokens": 20, "cost": 1.25}]
                },
                {
                  "agent": "claude",
                  "inputTokens": 40,
                  "outputTokens": 10,
                  "totalTokens": 50,
                  "totalCost": \(claudeCost),
                  "modelBreakdowns": [{"modelName": "model-b", "inputTokens": 40, "outputTokens": 10, "cost": \(claudeCost)}]
                }
              ],
              "inputTokens": 140,
              "outputTokens": 30,
              "cacheReadTokens": 99,
              "totalTokens": 170,
              "totalCost": \(1.25 + claudeCost)
            },
            {
              "agent": "all",
              "period": "2026-08-16",
              "agents": [
                {
                  "agent": "codex",
                  "inputTokens": 7,
                  "totalTokens": 7,
                  "totalCost": 0.5,
                  "modelBreakdowns": [{"modelName": "model-a", "inputTokens": 7, "cost": 0.5}]
                }
              ],
              "inputTokens": 7,
              "totalTokens": 7,
              "totalCost": 0.5
            }
          ],
          "monthly": [{
            "agent": "all",
            "period": "2026-08",
            "agents": [
              {
                "agent": "codex",
                "inputTokens": 107,
                "outputTokens": 20,
                "totalTokens": 127,
                "modelBreakdowns": [{"modelName": "model-a", "inputTokens": 107, "outputTokens": 20, "cost": 1.75}]
              },
              {
                "agent": "claude",
                "inputTokens": 40,
                "outputTokens": 10,
                "totalTokens": 50,
                "modelBreakdowns": [{"modelName": "model-b", "inputTokens": 40, "outputTokens": 10, "cost": \(claudeCost)}]
              }
            ],
            "totalTokens": 177,
            "totalCost": \(1.75 + claudeCost)
          }]
        }
        """.utf8))
    }

    private func scope(excluding agents: [String]) -> UsageQueryScope {
        UsageQueryScope(
            since: "2026-08-16",
            until: "2026-08-17",
            timeZone: "UTC",
            lookbackDays: 2,
            excludedAgents: agents
        )
    }

    func testExcludingAgentsRebuildsAggregateRowsAndDropsEmptyDays() throws {
        let filtered = try response().excludingAgents(["codex"])

        XCTAssertEqual(filtered.daily.map(\.period), ["2026-08-17"])
        let row = try XCTUnwrap(filtered.daily.first)
        XCTAssertEqual(row.agents?.map(\.agent), ["claude"])
        XCTAssertEqual(row.inputTokens, 40)
        XCTAssertEqual(row.outputTokens, 10)
        XCTAssertEqual(row.totalTokens, 50)
        XCTAssertEqual(try XCTUnwrap(row.totalCost), 2.75, accuracy: 0.0001)
        XCTAssertEqual(row.modelBreakdowns?.map(\.modelName), ["model-b"])
        // Fields no remaining agent reported are cleared, not left at the
        // unfiltered aggregate's value.
        XCTAssertNil(row.cacheReadTokens)
    }

    func testEmptyExclusionLeavesResponseUntouched() throws {
        let original = try response()
        let filtered = original.excludingAgents([])

        XCTAssertEqual(filtered.daily.count, 2)
        XCTAssertEqual(filtered.daily.first?.totalTokens, 170)
        XCTAssertEqual(filtered.daily.first?.agents?.count, 2)
        XCTAssertEqual(filtered.monthly.first?.agents?.count, 2)
    }

    func testSnapshotAndMonthlyBudgetOmitExcludedAgent() throws {
        let filtered = try response().excludingAgents(["codex"])

        let snapshot = UsageSnapshotBuilder.make(
            from: filtered,
            pricingUpdatedAt: nil,
            queryScope: scope(excluding: ["codex"])
        )
        XCTAssertEqual(snapshot.agents.map(\.name), ["claude"])
        XCTAssertEqual(snapshot.totalTokens.totalTokens, 50)
        XCTAssertEqual(snapshot.estimatedCost, 2.75, accuracy: 0.0001)
        XCTAssertFalse(snapshot.models.contains { $0.name == "model-a" })

        let budget = UsageSnapshotBuilder.makeMonthlyBudget(
            from: filtered,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil
        )
        XCTAssertEqual(budget.totalTokens, 50)
        XCTAssertEqual(budget.estimatedCost, 2.75, accuracy: 0.0001)
        XCTAssertEqual(budget.models.map(\.name), ["model-b"])
    }

    func testMergeDoesNotFallBackToCostsFromAnotherAgentFilter() throws {
        let previous = UsageSnapshotBuilder.make(
            from: try response(),
            pricingUpdatedAt: nil,
            queryScope: scope(excluding: [])
        )
        // model-b has no price in the candidate. Under the same filter the
        // merge would reuse the previous day cost, which includes codex.
        let candidate = UsageSnapshotBuilder.make(
            from: try response(claudeCost: 0).excludingAgents(["codex"]),
            pricingUpdatedAt: nil,
            queryScope: scope(excluding: ["codex"])
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertEqual(merged.days.map(\.estimatedCost), [0])
        XCTAssertEqual(merged.estimatedCost, 0, accuracy: 0.0001)
    }

    func testLegacyQueryScopeDecodesWithoutExcludedAgents() throws {
        let scope = try JSONDecoder().decode(UsageQueryScope.self, from: Data("""
        {"since":"2026-08-01","until":"2026-08-17","timeZone":"UTC","lookbackDays":30}
        """.utf8))

        XCTAssertEqual(scope.excludedAgents, [])
        XCTAssertEqual(
            scope,
            UsageQueryScope(since: "2026-08-01", until: "2026-08-17", timeZone: "UTC", lookbackDays: 30)
        )
        XCTAssertNotEqual(
            scope,
            UsageQueryScope(
                since: "2026-08-01",
                until: "2026-08-17",
                timeZone: "UTC",
                lookbackDays: 30,
                excludedAgents: ["codex"]
            )
        )
    }

    func testSettingsStorePersistsNormalizedExcludedAgents() {
        let suiteName = "Meterlark.AgentFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SettingsStore(defaults: defaults).load().excludedAgents, [])

        var settings = SettingsStore(defaults: defaults).load()
        settings.excludedAgents = ["codex", " claude ", "codex", ""]
        SettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(SettingsStore(defaults: defaults).load().excludedAgents, ["claude", "codex"])
    }
}
