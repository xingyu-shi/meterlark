import XCTest
@testable import MeterlarkApp

final class UsageDecodingTests: XCTestCase {
    func testMonthlyBudgetBuilderAggregatesNestedAgentsAndUnknownPricing() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {
          "monthly": [{
            "agent": "all",
            "agents": [
              {
                "agent": "codex",
                "inputTokens": 100,
                "outputTokens": 20,
                "modelBreakdowns": [{"modelName": "model-a", "inputTokens": 100, "outputTokens": 20, "cost": 1.25}]
              },
              {
                "agent": "claude",
                "inputTokens": 40,
                "outputTokens": 10,
                "modelBreakdowns": [
                  {"modelName": "model-b", "inputTokens": 40, "outputTokens": 10, "cost": 2.75},
                  {"modelName": "unknown-model", "inputTokens": 5, "cost": 0}
                ]
              }
            ],
            "period": "2026-08",
            "totalTokens": 175,
            "totalCost": 4.0
          }]
        }
        """.utf8))

        let snapshot = UsageSnapshotBuilder.makeMonthlyBudget(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil
        )

        XCTAssertEqual(snapshot.totalTokens, 175)
        XCTAssertEqual(snapshot.estimatedCost, 4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.models.count, 3)
        XCTAssertEqual(snapshot.unknownPricingModels, ["unknown-model"])
    }

    func testMonthlyBudgetBuilderUsesTopLevelCostWithoutBreakdown() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {"monthly":[{"agent":"all","period":"2026-08","totalTokens":100,"totalCost":3.5}]}
        """.utf8))

        let snapshot = UsageSnapshotBuilder.makeMonthlyBudget(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil
        )

        XCTAssertEqual(snapshot.totalTokens, 100)
        XCTAssertEqual(snapshot.estimatedCost, 3.5, accuracy: 0.0001)
        XCTAssertTrue(snapshot.models.isEmpty)
    }

    func testUsageBuilderKeepsTopLevelDailyCostWithoutBreakdown() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {"daily":[{"agent":"all","period":"2026-08-18","totalTokens":100,"totalCost":3.5}]}
        """.utf8))

        let snapshot = UsageSnapshotBuilder.make(
            from: response,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(
                since: "2026-08-01",
                until: "2026-08-18",
                timeZone: TimeZone.current.identifier,
                lookbackDays: MonitorSettings.calendarMonthLookback
            )
        )

        XCTAssertEqual(snapshot.days.first?.estimatedCost ?? -1, 3.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.estimatedCost, 3.5, accuracy: 0.0001)
    }

    func testMonthlyBudgetBuilderUsesDailySectionForRealtimeAnchor() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {
          "daily": [
            {"agent":"all","period":"2026-08-18","totalTokens":40,"totalCost":5.25}
          ],
          "monthly": [
            {"agent":"all","period":"2026-08","totalTokens":100,"totalCost":12.5}
          ]
        }
        """.utf8))

        let snapshot = UsageSnapshotBuilder.makeMonthlyBudget(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            realtimeAnchorDay: "2026-08-18"
        )

        XCTAssertEqual(snapshot.realtimeAnchorDay, "2026-08-18")
        XCTAssertEqual(snapshot.realtimeAnchorTodayCost ?? -1, 5.25, accuracy: 0.0001)
        XCTAssertTrue(snapshot.hasRealtimeProjection)
    }

    func testMonthlyBudgetBuilderDoesNotInventAnchorWithoutDailySection() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {"monthly":[{"agent":"all","period":"2026-08","totalTokens":100,"totalCost":12.5}]}
        """.utf8))

        let snapshot = UsageSnapshotBuilder.makeMonthlyBudget(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            realtimeAnchorDay: "2026-08-18"
        )

        XCTAssertFalse(snapshot.hasRealtimeProjection)
        XCTAssertNil(snapshot.realtimeAnchorDay)
        XCTAssertNil(snapshot.realtimeAnchorTodayCost)
    }

    func testMonthlyBudgetBuilderDoesNotTreatMissingTodayRowAsZeroAnchor() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {
          "daily": [
            {"agent":"all","period":"2026-08-17","totalTokens":40,"totalCost":5.25}
          ],
          "monthly": [
            {"agent":"all","period":"2026-08","totalTokens":100,"totalCost":12.5}
          ]
        }
        """.utf8))

        let snapshot = UsageSnapshotBuilder.makeMonthlyBudget(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            realtimeAnchorDay: "2026-08-18"
        )

        XCTAssertFalse(snapshot.hasRealtimeProjection)
        XCTAssertNil(snapshot.realtimeAnchorDay)
        XCTAssertNil(snapshot.realtimeAnchorTodayCost)
    }

    func testCurrentCalendarMonthStartsOnTheFirstDayOfTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 18, minute: 45))!

        let start = CCUsageRunner.startDate(
            for: MonitorSettings.calendarMonthLookback,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: start).year, 2026)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: start).month, 2)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: start).day, 1)
    }

    func testTodayLookbackStartsAtTodayAndEndsAtToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 0, minute: 5))!

        let scope = CCUsageRunner.queryScope(for: 1, now: now, calendar: calendar)

        XCTAssertEqual(scope.since, "2026-08-17")
        XCTAssertEqual(scope.until, "2026-08-17")
        XCTAssertEqual(scope.timeZone, "America/Toronto")
    }

    func testTodayScopeHandlesTheSpringForwardDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!

        let scope = CCUsageRunner.queryScope(for: 1, now: now, calendar: calendar)

        XCTAssertEqual(scope.since, "2026-03-08")
        XCTAssertEqual(scope.until, "2026-03-08")
        XCTAssertEqual(calendar.dateComponents([.hour], from: CCUsageRunner.startDate(for: 1, now: now, calendar: calendar)).hour, 0)
    }

    func testPricingPolicyAllowsKnownCostAlongsideUnknownModel() {
        let previous = makeSnapshot(cost: 100, periods: ["2026-08-01", "2026-08-06"])
        let candidate = makeSnapshot(
            cost: 0.26,
            periods: ["2026-08-01", "2026-08-06"],
            unknownPricingModels: ["new-model"]
        )

        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testPricingPolicyAllowsDifferentLookbackRange() {
        let previous = makeSnapshot(cost: 100, periods: ["2026-08-01", "2026-08-06"])
        let candidate = makeSnapshot(cost: 50.26, periods: ["2026-08-06", "2026-08-07"])

        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testPricingPolicyRejectsIncompleteLowerCostReport() {
        let previous = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [
                DailyUsage(period: "2026-08-01", tokens: TokenTotals(inputTokens: 10), estimatedCost: 100),
                DailyUsage(period: "2026-08-06", tokens: TokenTotals(inputTokens: 10), estimatedCost: 100)
            ],
            agents: [], models: [], totalTokens: TokenTotals(inputTokens: 20), estimatedCost: 200, unknownPricingModels: []
        )
        let candidate = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [
                DailyUsage(period: "2026-08-06", tokens: TokenTotals(inputTokens: 20), estimatedCost: 0.26),
                DailyUsage(period: "2026-08-07", tokens: TokenTotals(inputTokens: 10), estimatedCost: 0.10)
            ],
            agents: [], models: [], totalTokens: TokenTotals(inputTokens: 30), estimatedCost: 0.36, unknownPricingModels: ["new-model"]
        )

        XCTAssertFalse(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testPricingPolicyAllowsCompleteModelRename() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-06"],
            modelCost: 100,
            modelName: "gpt-5.6-luna"
        )
        let replacement = ModelUsage(
            agent: "codex",
            name: "gpt-5.6-terra",
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 100,
            hasKnownPricing: true
        )
        let candidate = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-06", tokens: TokenTotals(inputTokens: 10), estimatedCost: 100)],
            dailyModels: [DailyModelUsage(
                period: "2026-08-06",
                agent: replacement.agent,
                name: replacement.name,
                tokens: replacement.tokens,
                estimatedCost: replacement.estimatedCost,
                hasKnownPricing: true
            )],
            agents: [],
            models: [replacement],
            totalTokens: TokenTotals(inputTokens: 10),
            estimatedCost: 100,
            unknownPricingModels: []
        )

        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous), "a complete model rename is a valid pricing result")
    }

    func testPricingPolicyRejectsTokenRegressionForAutomaticRefresh() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-06"],
            modelCost: 100,
            modelName: "gpt-5.6-luna"
        )
        let candidateModel = DailyModelUsage(
            period: "2026-08-06",
            agent: "codex",
            name: "gpt-5.6-luna",
            tokens: TokenTotals(inputTokens: 5),
            estimatedCost: 1,
            hasKnownPricing: true
        )
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            queryScope: previous.queryScope,
            days: [DailyUsage(period: "2026-08-06", tokens: candidateModel.tokens, estimatedCost: 1)],
            dailyModels: [candidateModel],
            agents: [],
            models: [ModelUsage(agent: candidateModel.agent, name: candidateModel.name, tokens: candidateModel.tokens, estimatedCost: 1, hasKnownPricing: true)],
            totalTokens: candidateModel.tokens,
            estimatedCost: 1,
            unknownPricingModels: []
        )

        XCTAssertFalse(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testPricingPolicyAllowsACompleteLargePriceDrop() {
        let previous = makeSnapshot(cost: 100, periods: ["2026-08-01", "2026-08-06"])
        let candidate = makeSnapshot(cost: 1, periods: ["2026-08-01", "2026-08-06"])

        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testChangedPricingRevisionAcceptsCurrentBaselineWithoutOldCustomCost() {
        let tokens = TokenTotals(inputTokens: 10)
        let oldModel = ModelUsage(
            agent: "codex",
            name: "removed-model",
            tokens: tokens,
            estimatedCost: 100,
            hasKnownPricing: true
        )
        let previous = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            customPricingRevision: "old-pricing",
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 100)],
            dailyModels: [DailyModelUsage(
                period: "2026-08-17",
                agent: oldModel.agent,
                name: oldModel.name,
                tokens: tokens,
                estimatedCost: 100,
                hasKnownPricing: true
            )],
            agents: [AgentUsage(name: oldModel.agent, tokens: tokens, estimatedCost: 100)],
            models: [oldModel],
            totalTokens: tokens,
            estimatedCost: 100,
            unknownPricingModels: [],
            pricingSource: .custom
        )
        let currentBaseline = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 0)],
            dailyModels: [DailyModelUsage(
                period: "2026-08-17",
                agent: oldModel.agent,
                name: oldModel.name,
                tokens: tokens,
                estimatedCost: 0,
                hasKnownPricing: false
            )],
            agents: [AgentUsage(name: oldModel.agent, tokens: tokens, estimatedCost: 0)],
            models: [ModelUsage(
                agent: oldModel.agent,
                name: oldModel.name,
                tokens: tokens,
                estimatedCost: 0,
                hasKnownPricing: false
            )],
            totalTokens: tokens,
            estimatedCost: 0,
            unknownPricingModels: [oldModel.name],
            pricingSource: .unknown
        )

        XCTAssertFalse(PricingRefreshPolicy.accepts(candidate: currentBaseline, previous: previous))
        XCTAssertTrue(PricingRefreshPolicy.acceptsAfterPricingRevisionChange(candidate: currentBaseline))
        XCTAssertEqual(currentBaseline.estimatedCost, 0, accuracy: 0.0001)
        XCTAssertTrue(currentBaseline.unknownPricingModels.contains(oldModel.name))
    }

    func testSameScopeDetectsNewUnknownModelButDifferentScopeDoesNot() {
        let scope = UsageQueryScope(since: "2026-08-01", until: "2026-08-17", timeZone: "America/Toronto", lookbackDays: 30)
        let oldModel = ModelUsage(agent: "codex", name: "old-model", tokens: TokenTotals(inputTokens: 10), estimatedCost: 1, hasKnownPricing: true)
        let newModel = ModelUsage(agent: "codex", name: "new-model", tokens: TokenTotals(inputTokens: 10), estimatedCost: 0, hasKnownPricing: false)
        let previous = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            queryScope: scope,
            days: [],
            agents: [],
            models: [oldModel],
            totalTokens: oldModel.tokens,
            estimatedCost: 1,
            unknownPricingModels: []
        )
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            queryScope: scope,
            days: [],
            agents: [],
            models: [oldModel, newModel],
            totalTokens: previous.totalTokens + newModel.tokens,
            estimatedCost: 1,
            unknownPricingModels: [newModel.name]
        )

        XCTAssertEqual(candidate.addedModelIdentities(comparedTo: previous), ["codex::new-model"])
        XCTAssertEqual(candidate.newlyUnknownModelIdentities(comparedTo: previous), ["codex::new-model"])

        let differentScope = UsageSnapshot(
            schemaVersion: candidate.schemaVersion,
            generatedAt: candidate.generatedAt,
            pricingUpdatedAt: candidate.pricingUpdatedAt,
            queryScope: UsageQueryScope(since: "2026-08-17", until: "2026-08-17", timeZone: "America/Toronto", lookbackDays: 1),
            days: candidate.days,
            agents: candidate.agents,
            models: candidate.models,
            totalTokens: candidate.totalTokens,
            estimatedCost: candidate.estimatedCost,
            unknownPricingModels: candidate.unknownPricingModels
        )
        XCTAssertTrue(differentScope.addedModelIdentities(comparedTo: previous).isEmpty)
    }

    func testPricingPolicyAllowsShorterLookbackToOmitOlderModels() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-01", "2026-08-06"],
            modelCost: 100,
            modelName: "older-model"
        )
        let candidateModel = DailyModelUsage(
            period: "2026-08-06",
            agent: "codex",
            name: "current-model",
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 100,
            hasKnownPricing: true
        )
        let candidate = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-06", tokens: candidateModel.tokens, estimatedCost: 100)],
            dailyModels: [candidateModel],
            agents: [],
            models: [ModelUsage(
                agent: candidateModel.agent,
                name: candidateModel.name,
                tokens: candidateModel.tokens,
                estimatedCost: candidateModel.estimatedCost,
                hasKnownPricing: true
            )],
            totalTokens: candidateModel.tokens,
            estimatedCost: 100,
            unknownPricingModels: []
        )

        XCTAssertTrue(PricingRefreshPolicy.accepts(candidate: candidate, previous: previous))
    }

    func testOfflineUsageMergeUsesCurrentKnownCost() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-06"],
            modelCost: 100,
            modelName: "gpt-5.6-luna"
        )
        let candidate = makePricedSnapshot(
            periods: ["2026-08-06"],
            modelCost: 0.26,
            modelName: "gpt-5.6-luna"
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertEqual(merged.estimatedCost, 0.26, accuracy: 0.0001)
        XCTAssertEqual(merged.models.first?.estimatedCost ?? 0, 0.26, accuracy: 0.0001)
        XCTAssertEqual(merged.pricingUpdatedAt, previous.pricingUpdatedAt)
    }

    func testOfflineUsageMergeFallsBackPerDayWhenBreakdownIsMissing() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-01", "2026-08-06"],
            modelCost: 100,
            modelName: "gpt-5.6-luna"
        )
        let candidate = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: nil,
            days: [
                DailyUsage(period: "2026-08-01", tokens: TokenTotals(inputTokens: 20), estimatedCost: 0),
                DailyUsage(period: "2026-08-06", tokens: TokenTotals(inputTokens: 30), estimatedCost: 0)
            ],
            dailyModels: [],
            agents: [],
            models: [],
            totalTokens: TokenTotals(inputTokens: 50),
            estimatedCost: 0,
            unknownPricingModels: []
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertEqual(merged.days.map(\.estimatedCost), [100, 100])
    }

    func testOfflineUsageMergePreservesPriorDayWhenBreakdownIsPartial() {
        let previous = makePricedSnapshot(
            periods: ["2026-08-06"],
            modelCost: 100,
            modelName: "gpt-5.6-luna"
        )
        let candidateModel = DailyModelUsage(
            period: "2026-08-06",
            agent: "codex",
            name: "new-unknown-model",
            tokens: TokenTotals(inputTokens: 20),
            estimatedCost: 0,
            hasKnownPricing: false
        )
        let candidate = UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: nil,
            days: [DailyUsage(period: "2026-08-06", tokens: TokenTotals(inputTokens: 30), estimatedCost: 0)],
            dailyModels: [candidateModel],
            agents: [AgentUsage(name: "codex", tokens: candidateModel.tokens, estimatedCost: 0)],
            models: [ModelUsage(
                agent: candidateModel.agent,
                name: candidateModel.name,
                tokens: candidateModel.tokens,
                estimatedCost: 0,
                hasKnownPricing: false
            )],
            totalTokens: candidateModel.tokens,
            estimatedCost: 0,
            unknownPricingModels: [candidateModel.name]
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertEqual(merged.days.first?.estimatedCost ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(merged.estimatedCost, 100, accuracy: 0.0001)
    }

    func testOfflineUsageMergeDoesNotUseOlderRangeForCurrentAgentCost() {
        let oldTokens = TokenTotals(inputTokens: 10)
        let currentTokens = TokenTotals(inputTokens: 10)
        let oldModel = DailyModelUsage(period: "2026-08-01", agent: "codex", name: "old-model", tokens: oldTokens, estimatedCost: 100, hasKnownPricing: true)
        let currentModel = DailyModelUsage(period: "2026-08-06", agent: "codex", name: "current-model", tokens: currentTokens, estimatedCost: 50, hasKnownPricing: true)
        let previous = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            queryScope: UsageQueryScope(since: "2026-08-01", until: "2026-08-06", timeZone: "America/Toronto", lookbackDays: 6),
            days: [
                DailyUsage(period: oldModel.period, tokens: oldTokens, estimatedCost: 100),
                DailyUsage(period: currentModel.period, tokens: currentTokens, estimatedCost: 50)
            ],
            dailyModels: [oldModel, currentModel],
            agents: [AgentUsage(name: "codex", tokens: oldTokens + currentTokens, estimatedCost: 150)],
            models: [
                ModelUsage(agent: "codex", name: oldModel.name, tokens: oldTokens, estimatedCost: 100, hasKnownPricing: true),
                ModelUsage(agent: "codex", name: currentModel.name, tokens: currentTokens, estimatedCost: 50, hasKnownPricing: true)
            ],
            totalTokens: oldTokens + currentTokens,
            estimatedCost: 150,
            unknownPricingModels: []
        )
        let candidateModel = DailyModelUsage(period: currentModel.period, agent: "codex", name: currentModel.name, tokens: currentTokens, estimatedCost: 0, hasKnownPricing: false)
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(since: "2026-08-06", until: "2026-08-06", timeZone: "America/Toronto", lookbackDays: 1),
            days: [DailyUsage(period: currentModel.period, tokens: currentTokens, estimatedCost: 0)],
            dailyModels: [candidateModel],
            agents: [AgentUsage(name: "codex", tokens: currentTokens, estimatedCost: 0)],
            models: [ModelUsage(agent: "codex", name: currentModel.name, tokens: currentTokens, estimatedCost: 0, hasKnownPricing: false)],
            totalTokens: currentTokens,
            estimatedCost: 0,
            unknownPricingModels: [currentModel.name]
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertEqual(merged.agents.first?.estimatedCost ?? -1, 50, accuracy: 0.0001)
        XCTAssertEqual(merged.days.first?.estimatedCost ?? -1, 50, accuracy: 0.0001)
    }

    func testByAgentResponseAggregatesAgentsAndModels() throws {
        let today = DateFormatter.isoDate.string(from: Date())
        let data = """
        {
          "daily": [{
            "agent": "all",
            "agents": [{
              "agent": "codex",
              "inputTokens": 100,
              "outputTokens": 20,
              "cacheReadTokens": 80,
              "modelBreakdowns": [{
                "modelName": "gpt-5.6-luna",
                "inputTokens": 100,
                "outputTokens": 20,
                "cacheReadTokens": 80,
                "cost": 1.25
              }]
            }],
            "period": "\(today)",
            "inputTokens": 100,
            "outputTokens": 20,
            "cacheReadTokens": 80,
            "totalTokens": 200,
            "totalCost": 1.25
          }],
          "totals": {"totalTokens": 200, "totalCost": 1.25}
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CCUsageResponse.self, from: data)
        let snapshot = UsageSnapshotBuilder.make(from: response, pricingUpdatedAt: nil)

        XCTAssertEqual(snapshot.agents.map(\.name), ["codex"])
        XCTAssertEqual(snapshot.models.map(\.name), ["gpt-5.6-luna"])
        XCTAssertEqual(snapshot.totalTokens.totalTokens, 200)
        XCTAssertEqual(snapshot.estimatedCost, 1.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryTokens.totalTokens, 200)
        XCTAssertEqual(snapshot.primaryEstimatedCost, 1.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dailyModels.count, 1)
        XCTAssertEqual(snapshot.dailyModels.first?.period, today)
        XCTAssertEqual(snapshot.dailyModels.first?.name, "gpt-5.6-luna")
        XCTAssertTrue(snapshot.unknownPricingModels.isEmpty)
    }

    func testZeroCostWithTokensIsMarkedUnknown() throws {
        let data = """
        {
          "daily": [{
            "agent": "all",
            "agents": [{
              "agent": "custom",
              "modelBreakdowns": [{
                "modelName": "internal-model",
                "inputTokens": 10,
                "outputTokens": 5,
                "cost": 0
              }]
            }],
            "period": "2026-08-06"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CCUsageResponse.self, from: data)
        let snapshot = UsageSnapshotBuilder.make(from: response, pricingUpdatedAt: nil)

        XCTAssertEqual(snapshot.unknownPricingModels, ["internal-model"])
        XCTAssertEqual(snapshot.models.first?.estimatedCost, 0)
        XCTAssertEqual(snapshot.models.first?.hasKnownPricing, false)
    }

    func testPartiallyPricedModelRemainsUnknown() throws {
        let data = """
        {
          "daily": [{
            "agent": "all",
            "agents": [{
              "agent": "codex",
              "modelBreakdowns": [
                {"modelName": "partial-model", "inputTokens": 10, "cost": 1},
                {"modelName": "partial-model", "inputTokens": 20}
              ]
            }],
            "period": "2026-08-17"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CCUsageResponse.self, from: data)
        let snapshot = UsageSnapshotBuilder.make(from: response, pricingUpdatedAt: nil)

        XCTAssertEqual(snapshot.models.first?.name, "partial-model")
        XCTAssertFalse(snapshot.models.first?.hasKnownPricing ?? true)
        XCTAssertEqual(snapshot.unknownPricingModels, ["partial-model"])
    }

    func testIncompleteCustomPricingDoesNotHideUnknownCandidate() {
        let table = CustomPricingTable(entries: [
            "partial-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: nil,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let tokens = TokenTotals(inputTokens: 10, outputTokens: 20)
        let model = ModelUsage(agent: "codex", name: "partial-model", tokens: tokens, estimatedCost: 0, hasKnownPricing: false)
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 0)],
            dailyModels: [DailyModelUsage(period: "2026-08-17", agent: model.agent, name: model.name, tokens: tokens, estimatedCost: 0, hasKnownPricing: false)],
            agents: [],
            models: [model],
            totalTokens: tokens,
            estimatedCost: 0,
            unknownPricingModels: [model.name]
        )
        let previous = makePricedSnapshot(periods: ["2026-08-17"], modelCost: 100, modelName: model.name)

        XCTAssertTrue(table.modelNamesWithCompleteRates(in: candidate).isEmpty)
        XCTAssertFalse(PricingRefreshPolicy.accepts(
            candidate: candidate,
            previous: previous
        ))
    }

    private func makeSnapshot(cost: Double, periods: [String], unknownPricingModels: [String] = []) -> UsageSnapshot {
        let dailyCost = cost / Double(periods.count)
        let dailyTokens = TokenTotals(inputTokens: 10)
        let totalTokens = periods.reduce(TokenTotals.zero) { total, _ in total + dailyTokens }
        let dailyModels = periods.map { period in
            DailyModelUsage(
                period: period,
                agent: "codex",
                name: "test-model",
                tokens: dailyTokens,
                estimatedCost: dailyCost,
                hasKnownPricing: true
            )
        }
        return UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: periods.map { DailyUsage(period: $0, tokens: dailyTokens, estimatedCost: dailyCost) },
            dailyModels: dailyModels,
            agents: [AgentUsage(name: "codex", tokens: totalTokens, estimatedCost: cost)],
            models: [ModelUsage(agent: "codex", name: "test-model", tokens: totalTokens, estimatedCost: cost, hasKnownPricing: true)],
            totalTokens: totalTokens,
            estimatedCost: cost,
            unknownPricingModels: unknownPricingModels
        )
    }

    private func makePricedSnapshot(periods: [String], modelCost: Double, modelName: String) -> UsageSnapshot {
        let model = ModelUsage(
            agent: "codex",
            name: modelName,
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: modelCost,
            hasKnownPricing: true
        )
        let dailyModel = DailyModelUsage(
            period: periods[0],
            agent: "codex",
            name: modelName,
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: modelCost,
            hasKnownPricing: true
        )
        return UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(timeIntervalSince1970: 100),
            days: periods.map { DailyUsage(period: $0, tokens: TokenTotals(inputTokens: 10), estimatedCost: modelCost) },
            dailyModels: [dailyModel],
            agents: [],
            models: [model],
            totalTokens: TokenTotals(inputTokens: 10),
            estimatedCost: modelCost,
            unknownPricingModels: []
        )
    }
}

private extension DateFormatter {
    static let isoDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
