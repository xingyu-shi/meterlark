import XCTest
@testable import MeterlarkApp

final class PricingStatusPresentationTests: XCTestCase {
    func testApproximatePresentationIncludesRealTierDetails() throws {
        let snapshot = makeSnapshot(
            models: [model(
                name: "gpt-5.6-luna",
                source: .approximate,
                tier: 272_000,
                backendTier: 200_000
            )],
            pricingSource: .approximate
        )

        let presentation = try XCTUnwrap(PricingStatusPresentation.make(snapshot: snapshot))

        XCTAssertEqual(presentation.kind, .approximate)
        XCTAssertEqual(presentation.models.map(\.name), ["gpt-5.6-luna"])
        XCTAssertEqual(presentation.models.first?.pricingTierThreshold, 272_000)
        XCTAssertEqual(presentation.models.first?.pricingBackendThreshold, 200_000)
    }

    func testUnknownPresentationDoesNotTurnUnknownIntoApproximate() throws {
        let snapshot = makeSnapshot(
            models: [
                model(name: "known", source: .custom),
                model(name: "missing", source: .unknown, known: false)
            ],
            pricingSource: .mixed,
            unknownPricingModels: ["missing"]
        )

        let presentation = try XCTUnwrap(PricingStatusPresentation.make(snapshot: snapshot))

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertTrue(presentation.includesMixedSources)
        XCTAssertEqual(presentation.models.map(\.name), ["missing"])
    }

    func testUnknownPresentationAlsoListsApproximateModels() throws {
        let snapshot = makeSnapshot(
            models: [
                model(name: "approximate", source: .approximate),
                model(name: "missing", source: .unknown, known: false)
            ],
            pricingSource: .unknown,
            unknownPricingModels: ["missing"]
        )

        let presentation = try XCTUnwrap(PricingStatusPresentation.make(snapshot: snapshot))

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.models.map(\.name), ["approximate", "missing"])
        XCTAssertEqual(presentation.models.first?.source, .approximate)
        XCTAssertEqual(presentation.models.last?.source, .unknown)
    }

    func testUnknownPresentationExplainsMissingRequiredRemoteInputRate() throws {
        let model = ModelUsage(
            agent: "codex",
            name: "deepseek-v4-flash-0731-gmi-ray",
            tokens: TokenTotals(inputTokens: 100, outputTokens: 20, cacheReadTokens: 1_000),
            estimatedCost: 0,
            hasKnownPricing: false,
            pricingSource: .unknown
        )
        let snapshot = makeSnapshot(
            models: [model],
            pricingSource: .unknown,
            unknownPricingModels: [model.name]
        )
        let entry = ModelCatalogEntry(
            id: "deepseek",
            modelName: model.name,
            pricing: CustomModelPricing(
                inputCostPerToken: nil,
                outputCostPerToken: 0,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            ),
            metadata: .empty,
            source: .remote,
            providerID: "example-gateway",
            recordIdentity: "deepseek",
            enabled: true,
            pricingSchedule: CanonicalModelPricing(
                modelName: model.name,
                base: PricingRates(input: nil, output: 0, cacheCreation: nil, cacheRead: nil),
                tiers: [],
                maxInputTokens: nil,
                fastMultiplier: nil
            )
        )

        let presentation = try XCTUnwrap(
            PricingStatusPresentation.make(
                snapshot: snapshot,
                modelCatalogEntries: [entry]
            )
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.models.first?.reason, .catalogRatesIncomplete)
        XCTAssertEqual(presentation.models.first?.missingRateComponents, [.input])
    }

    func testMixedPresentationListsAllUsedModelsWhenNoUnknownPricingExists() throws {
        let snapshot = makeSnapshot(
            models: [
                model(name: "custom-model", source: .custom),
                model(name: "remote-model", source: .remote)
            ],
            pricingSource: .mixed
        )

        let presentation = try XCTUnwrap(PricingStatusPresentation.make(snapshot: snapshot))

        XCTAssertEqual(presentation.kind, .mixed)
        XCTAssertEqual(presentation.models.map(\.name), ["custom-model", "remote-model"])
        XCTAssertTrue(presentation.includesMixedSources)
    }

    func testKnownSingleSourceHasNoStatusBadge() {
        for source in [PricingSource.ccusage, .custom, .remote] {
            let modelSource: ModelPricingSource = source == .custom ? .custom : (source == .remote ? .remote : .ccusage)
            let snapshot = makeSnapshot(
                models: [model(name: "model", source: modelSource)],
                pricingSource: source
            )

            XCTAssertNil(PricingStatusPresentation.make(snapshot: snapshot))
        }
    }

    func testRemoteProviderIDsAreRetainedForProviderSpecificLabels() throws {
        let snapshot = makeSnapshot(
            models: [model(
                name: "remote-model",
                source: .remote,
                providerIDs: ["provider-b", "provider-a"]
            )],
            pricingSource: .remote
        )

        let presentation = try XCTUnwrap(
            PricingStatusPresentation.make(snapshot: snapshot, pricingIsStale: true)
        )

        XCTAssertEqual(presentation.models.first?.pricingProviderIDs, ["provider-a", "provider-b"])
    }

    func testExternalUnknownNameStillProducesStatusWithHonestModelDetails() throws {
        let snapshot = makeSnapshot(
            models: [model(name: "known", source: .custom)],
            pricingSource: .custom
        )

        let presentation = try XCTUnwrap(
            PricingStatusPresentation.make(snapshot: snapshot, unknownPricingModels: ["monthly-only-model"])
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.models.map(\.name), ["monthly-only-model"])
        XCTAssertTrue(presentation.models.first?.agent.isEmpty == true)
    }

    func testPersistedUnknownListDoesNotOverrideKnownCurrentModelRows() {
        let snapshot = makeSnapshot(
            models: [model(name: "known", source: .custom)],
            pricingSource: .custom,
            unknownPricingModels: ["old-model"]
        )

        XCTAssertNil(PricingStatusPresentation.make(snapshot: snapshot))
    }

    func testUnknownPricingTakesPriorityOverStalePresentation() throws {
        let snapshot = makeSnapshot(
            models: [model(name: "old-model", source: .unknown, known: false)],
            pricingSource: .unknown,
            unknownPricingModels: ["old-model"]
        )

        let presentation = try XCTUnwrap(
            PricingStatusPresentation.make(
                snapshot: snapshot,
                pricingIsStale: true
            )
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.models.map(\.name), ["old-model"])
    }

    func testUnknownPricingTakesPriorityAndListsOnlyUnknownRowsWhenBasisIsStale() throws {
        let snapshot = makeSnapshot(
            models: [
                model(name: "gpt-5.6-luna", source: .remote, tier: 272_000),
                model(name: "missing-model", source: .unknown, known: false)
            ],
            pricingSource: .mixed,
            unknownPricingModels: ["missing-model"]
        )

        let presentation = try XCTUnwrap(
            PricingStatusPresentation.make(snapshot: snapshot, pricingIsStale: true)
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.models.map(\.name), ["missing-model"])
        XCTAssertNil(presentation.models.first?.pricingTierThreshold)
    }

    private func model(
        name: String,
        source: ModelPricingSource,
        known: Bool? = nil,
        tier: Int64? = nil,
        backendTier: Int64? = nil,
        providerIDs: [String] = []
    ) -> ModelUsage {
        ModelUsage(
            agent: "codex",
            name: name,
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 1,
            hasKnownPricing: known ?? (source != .unknown),
            pricingSource: source,
            pricingProviderIDs: providerIDs,
            pricingTierThreshold: tier,
            pricingBackendThreshold: backendTier
        )
    }

    private func makeSnapshot(
        models: [ModelUsage],
        pricingSource: PricingSource,
        unknownPricingModels: [String] = []
    ) -> UsageSnapshot {
        let totalTokens = models.reduce(TokenTotals.zero) { $0 + $1.tokens }
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [],
            agents: [],
            models: models,
            totalTokens: totalTokens,
            estimatedCost: models.reduce(0) { $0 + $1.estimatedCost },
            unknownPricingModels: unknownPricingModels,
            pricingSource: pricingSource
        )
    }
}
