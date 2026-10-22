import XCTest
@testable import MeterlarkApp

final class PricingSourceAggregationTests: XCTestCase {
    func testUnknownTakesPriorityOverApproximatePricing() {
        let approximate = model(source: .approximate)

        XCTAssertEqual(
            PricingSourceAggregation.aggregate(for: [approximate, model(source: .unknown)]),
            .unknown,
            "unknown usage must not be hidden behind an approximate estimate"
        )
    }

    func testApproximateRemainsVisibleWhenThereIsNoUnknownUsage() {
        let approximate = model(source: .approximate)

        for source in [ModelPricingSource.remote, .custom] {
            XCTAssertEqual(
                PricingSourceAggregation.aggregate(for: [approximate, model(source: source)]),
                .approximate,
                "approximate must remain visible when mixed with \(source)"
            )
        }
    }

    func testAggregatePreservesExistingSourcePriorityRules() {
        XCTAssertEqual(PricingSourceAggregation.aggregate(for: [model(source: .custom)]), .custom)
        XCTAssertEqual(PricingSourceAggregation.aggregate(for: [model(source: .remote)]), .remote)
        XCTAssertEqual(PricingSourceAggregation.aggregate(for: [model(source: .unknown)]), .unknown)
        XCTAssertEqual(
            PricingSourceAggregation.aggregate(for: [model(source: .custom), model(source: .ccusage)]),
            .mixed
        )
        XCTAssertEqual(
            PricingSourceAggregation.aggregate(for: [model(source: .remote), model(source: .unknown)]),
            .mixed
        )
    }

    func testEmptyAggregateUsesExplicitFallback() {
        XCTAssertEqual(
            PricingSourceAggregation.aggregate(for: [], emptyFallback: .unknown),
            .unknown
        )
        XCTAssertEqual(
            PricingSourceAggregation.aggregate(for: [model(source: .custom, tokens: .zero)], emptyFallback: .mixed),
            .mixed
        )
    }

    func testUsageMergeRecomputesAggregateAfterPreviousApproximateSnapshot() {
        let previous = makeSnapshot(
            modelSource: .approximate,
            modelCost: 100,
            pricingSource: .approximate
        )
        let candidate = makeSnapshot(
            modelSource: .custom,
            modelCost: 0.25,
            pricingSource: .custom
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)
        XCTAssertEqual(merged.pricingSource, .custom)
        XCTAssertEqual(merged.models.first?.pricingSource, .custom)
        XCTAssertEqual(merged.estimatedCost, 0.25, accuracy: 0.0001)

        let refreshedAgain = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: merged)
        XCTAssertEqual(refreshedAgain.pricingSource, .custom)
    }

    func testUsageMergeKeepsPreviousApproximateSourceWhenBreakdownIsMissing() {
        let tokens = TokenTotals(inputTokens: 100)
        let previous = makeSnapshot(
            modelSource: .approximate,
            modelCost: 100,
            pricingSource: .approximate,
            tokens: tokens
        )
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: nil,
            days: [DailyUsage(period: "2026-08-26", tokens: tokens, estimatedCost: 0)],
            dailyModels: [],
            agents: [],
            models: [],
            totalTokens: tokens,
            estimatedCost: 0,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)
        XCTAssertEqual(merged.pricingSource, .approximate)
        XCTAssertEqual(merged.days.first?.estimatedCost ?? 0, 100, accuracy: 0.0001)
    }

    func testUsageMergeDoesNotInheritApproximateWarningForTrulyEmptyCandidate() {
        let previous = makeSnapshot(
            modelSource: .approximate,
            modelCost: 100,
            pricingSource: .approximate
        )

        let merged = UsageSnapshot.mergingUsage(.empty, preservingPricingFrom: previous)

        XCTAssertEqual(merged.pricingSource, .unknown)
        XCTAssertTrue(merged.models.isEmpty)
        XCTAssertEqual(merged.estimatedCost, 0, accuracy: 0.0001)
    }

    func testUsageMergeDropsPreviousPricingWhenPricingRevisionChanges() {
        let previous = makeSnapshot(
            modelSource: .custom,
            modelCost: 100,
            pricingSource: .custom,
            customPricingRevision: "table-a"
        )
        let candidate = makeSnapshot(
            modelSource: .unknown,
            modelCost: 0,
            pricingSource: .unknown,
            customPricingRevision: nil
        )

        let merged = UsageSnapshot.mergingUsage(candidate, preservingPricingFrom: previous)

        XCTAssertFalse(merged.models.first?.hasKnownPricing ?? true)
        XCTAssertEqual(merged.models.first?.pricingSource, .unknown)
        XCTAssertEqual(merged.models.first?.estimatedCost ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(merged.estimatedCost, 0, accuracy: 0.0001)
        XCTAssertEqual(merged.customPricingRevision, nil)
        XCTAssertEqual(merged.unknownPricingModels, ["gpt-5.6-luna"])
        XCTAssertEqual(merged.pricingSource, .unknown)
    }

    private func model(
        source: ModelPricingSource,
        tokens: TokenTotals = TokenTotals(inputTokens: 10)
    ) -> ModelUsage {
        ModelUsage(
            agent: "codex",
            name: source.rawValue + "-model",
            tokens: tokens,
            estimatedCost: 1,
            hasKnownPricing: source != .unknown,
            pricingSource: source
        )
    }

    private func makeSnapshot(
        modelSource: ModelPricingSource,
        modelCost: Double,
        pricingSource: PricingSource,
        tokens: TokenTotals = TokenTotals(inputTokens: 10),
        customPricingRevision: String? = nil,
        modelCatalogRevision: String? = nil
    ) -> UsageSnapshot {
        let name = "gpt-5.6-luna"
        let known = modelSource != .unknown
        let model = ModelUsage(
            agent: "codex",
            name: name,
            tokens: tokens,
            estimatedCost: modelCost,
            hasKnownPricing: known,
            pricingSource: modelSource
        )
        let dailyModel = DailyModelUsage(
            period: "2026-08-26",
            agent: model.agent,
            name: model.name,
            tokens: model.tokens,
            estimatedCost: model.estimatedCost,
            hasKnownPricing: model.hasKnownPricing,
            pricingSource: model.pricingSource
        )
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision,
            days: [DailyUsage(period: dailyModel.period, tokens: tokens, estimatedCost: modelCost)],
            dailyModels: [dailyModel],
            agents: [AgentUsage(name: model.agent, tokens: tokens, estimatedCost: modelCost)],
            models: [model],
            totalTokens: tokens,
            estimatedCost: modelCost,
            unknownPricingModels: known ? [] : [model.name],
            pricingSource: pricingSource
        )
    }
}
