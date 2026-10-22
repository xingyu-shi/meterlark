import XCTest
@testable import MeterlarkApp

final class PricingProvenanceTests: XCTestCase {
    func testCustomPricingOverlayMarksMixedWhenSomeModelsRemainOnCcusagePricing() {
        let custom = CustomPricingTable(entries: [
            "custom-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let snapshot = makeSnapshot(models: [
            dailyModel(name: "custom-model", cost: 1, known: true),
            dailyModel(name: "ccusage-model", cost: 2, known: true)
        ])

        XCTAssertEqual(CustomPricingOverlay.apply(to: snapshot, table: custom).pricingSource, .mixed)
    }

    func testCustomPricingOverlayMarksCustomWhenAllUsageModelsAreCovered() {
        let custom = CustomPricingTable(entries: [
            "custom-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let snapshot = makeSnapshot(models: [dailyModel(name: "custom-model", cost: 1, known: true)])

        XCTAssertEqual(CustomPricingOverlay.apply(to: snapshot, table: custom).pricingSource, .custom)
    }

    func testCustomPricingOverlayMarksMixedWhenTheSameModelChangesSourceAcrossDays() {
        let custom = CustomPricingTable(entries: [
            "custom-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let firstDay = dailyModel(name: "custom-model", cost: 1, known: true, period: "2026-08-13")
        let secondDay = dailyModel(name: "custom-model", cost: 2, known: true, period: "2026-08-14", tokens: TokenTotals(inputTokens: 1_000_000, cacheReadTokens: 1))
        let snapshot = makeSnapshot(models: [firstDay, secondDay])

        XCTAssertEqual(CustomPricingOverlay.apply(to: snapshot, table: custom).pricingSource, .mixed)
    }

    private func dailyModel(
        name: String,
        cost: Double,
        known: Bool,
        period: String = "2026-08-14",
        tokens: TokenTotals = TokenTotals(inputTokens: 1_000_000)
    ) -> DailyModelUsage {
        DailyModelUsage(
            period: period,
            agent: "codex",
            name: name,
            tokens: tokens,
            estimatedCost: cost,
            hasKnownPricing: known
        )
    }

    private func makeSnapshot(models: [DailyModelUsage]) -> UsageSnapshot {
        let tokens = models.reduce(TokenTotals.zero) { $0 + $1.tokens }
        let cost = models.reduce(0) { $0 + $1.estimatedCost }
        let days = Dictionary(grouping: models, by: \.period).map { period, items in
            DailyUsage(period: period, tokens: items.reduce(TokenTotals.zero) { $0 + $1.tokens }, estimatedCost: items.reduce(0) { $0 + $1.estimatedCost })
        }
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: days,
            dailyModels: models,
            agents: [AgentUsage(name: "codex", tokens: tokens, estimatedCost: cost)],
            models: models.map { ModelUsage(agent: $0.agent, name: $0.name, tokens: $0.tokens, estimatedCost: $0.estimatedCost, hasKnownPricing: $0.hasKnownPricing) },
            totalTokens: tokens,
            estimatedCost: cost,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )
    }
}
