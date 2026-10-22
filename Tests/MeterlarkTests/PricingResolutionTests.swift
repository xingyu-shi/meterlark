import XCTest
@testable import MeterlarkApp

final class PricingResolutionTests: XCTestCase {
    func testExplicitAllZeroCustomPricingIsKnownFree() throws {
        let table = CustomPricingTable(entries: [
            "free-model": CustomModelPricing(
                inputCostPerToken: 0,
                outputCostPerToken: 0,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let result = try build(
            model: "free-model",
            inputTokens: 1_000,
            outputTokens: 100,
            rawCost: 99,
            table: table
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertEqual(model.estimatedCost, 0)
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(model.pricingSource, .custom)
        XCTAssertTrue(result.snapshot.unknownPricingModels.isEmpty)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.knownFree])
    }

    func testCcusageZeroWithoutCustomCoverageIsUnknown() throws {
        let result = try build(
            model: "unpriced-model",
            inputTokens: 1_000,
            rawCost: 0,
            table: .empty
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertFalse(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 0)
        XCTAssertEqual(result.snapshot.unknownPricingModels, ["unpriced-model"])
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.unpricedZero])
    }

    func testMissingOrInvalidCcusageCostIsUnknown() throws {
        for rawCost in [Double?(-1), nil] {
            let result = try build(
                model: "invalid-cost-model",
                inputTokens: 1_000,
                rawCost: rawCost,
                table: .empty
            )

            let model = try XCTUnwrap(result.snapshot.models.first)
            XCTAssertFalse(model.hasKnownPricing)
            XCTAssertEqual(model.estimatedCost, 0)
            XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.unpricedZero])
        }
    }

    func testNegativeAndNonFiniteCustomRatesRemainUnknown() throws {
        for rate in [-0.000001, Double.infinity, -Double.infinity, Double.nan] {
            let table = CustomPricingTable(entries: [
                "invalid-custom-model": CustomModelPricing(
                    inputCostPerToken: rate,
                    outputCostPerToken: 0.000002,
                    cacheCreationInputTokenCost: nil,
                    cacheReadInputTokenCost: nil
                )
            ])
            let result = try build(
                model: "invalid-custom-model",
                inputTokens: 1_000,
                outputTokens: 100,
                rawCost: 99,
                table: table
            )

            let model = try XCTUnwrap(result.snapshot.models.first)
            XCTAssertFalse(model.hasKnownPricing)
            XCTAssertEqual(model.estimatedCost, 0)
            XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.intentionalUnknown])
        }
    }

    func testPartialCustomPricingDoesNotFallThroughToBackendCost() throws {
        let table = CustomPricingTable(entries: [
            "partial-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: nil,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let result = try build(
            model: "partial-model",
            inputTokens: 1_000,
            outputTokens: 100,
            rawCost: 99,
            table: table
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertFalse(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 0)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.intentionalUnknown])
    }

    func testMixedNoTierPricingUsesExactZeroComponentFallback() throws {
        let table = CustomPricingTable(entries: [
            "mixed-model": CustomModelPricing(
                inputCostPerToken: 0,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let result = try build(
            model: "mixed-model",
            inputTokens: 1_000,
            outputTokens: 1_000,
            rawCost: 99,
            table: table
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertEqual(model.estimatedCost, 0.002, accuracy: 0.0000001)
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.knownPaid])
    }

    func testZeroBearingTierUsesBundledBackendWithExplicitZeroSupport() throws {
        let data = Data(#"{"data":[{"model_name":"tiered-model","model_info":{"input_cost_per_token":0,"output_cost_per_token":0.000002,"input_cost_per_token_above_200k_tokens":0,"output_cost_per_token_above_200k_tokens":0.000008}}]}"#.utf8)
        let table = try CustomPricingTable(data: data)
        let result = try build(
            model: "tiered-model",
            inputTokens: 250_000,
            outputTokens: 1_000,
            rawCost: 0.008,
            table: table
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 0.008, accuracy: 0.0000001)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.knownPaid])
    }

    func testInvalidTierRateDoesNotFallBackToBaseAboveThreshold() throws {
        for invalidValue in ["-0.000003", "\"not-a-rate\""] {
            let data = Data("""
            {"data":[{"model_name":"invalid-tier-model","model_info":{
              "input_cost_per_token":0.000001,
              "output_cost_per_token":0.000002,
              "input_cost_per_token_above_200k_tokens":\(invalidValue)
            }}]}
            """.utf8)
            let table = try CustomPricingTable(data: data)
            let result = try build(
                model: "invalid-tier-model",
                inputTokens: 250_000,
                outputTokens: 1_000,
                rawCost: 99,
                table: table
            )

            let model = try XCTUnwrap(result.snapshot.models.first)
            XCTAssertFalse(model.hasKnownPricing)
            XCTAssertEqual(model.estimatedCost, 0)
            XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.intentionalUnknown])
        }
    }

    func testNullOnlyTierFieldIsAbsentAndDoesNotCreateApproximatePricing() throws {
        let data = Data("""
        {"data":[{"model_name":"null-tier-model","model_info":{
          "input_cost_per_token":0.000001,
          "output_cost_per_token":0.000002,
          "input_cost_per_token_above_200k_tokens":null,
          "output_cost_per_token_above_200k_tokens":null
        }}]}
        """.utf8)
        let table = try CustomPricingTable(data: data)
        let catalog = table.canonicalPricingCatalog
        XCTAssertEqual(catalog.models.first?.tiers, [])

        let preparation = CcusagePricingAdapter.bundledV20.preparation(for: catalog)
        XCTAssertTrue(preparation.approximateModelNames.isEmpty)
        XCTAssertTrue(preparation.selectedTierThresholds.isEmpty)

        let result = try build(
            model: "null-tier-model",
            inputTokens: 250_000,
            outputTokens: 1_000,
            rawCost: 99,
            table: table
        )
        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 99)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.knownPaid])
    }

    func testPartialNullTierRetainsAvailableRateAndFailsClosedForMissingComponent() throws {
        let data = Data("""
        {"data":[{"model_name":"partial-null-tier-model","model_info":{
          "input_cost_per_token":0.000001,
          "output_cost_per_token":0.000002,
          "input_cost_per_token_above_200k_tokens":0.000004,
          "output_cost_per_token_above_200k_tokens":null
        }}]}
        """.utf8)
        let table = try CustomPricingTable(data: data)
        let catalog = table.canonicalPricingCatalog
        let tier = try XCTUnwrap(catalog.models.first?.tiers.first)
        XCTAssertEqual(tier.threshold, 200_000)
        XCTAssertEqual(tier.rates.input, 0.000004)
        XCTAssertNil(tier.rates.output)

        let inputOnly = try build(
            model: "partial-null-tier-model",
            inputTokens: 250_000,
            rawCost: 99,
            table: table
        )
        let knownModel = try XCTUnwrap(inputOnly.snapshot.models.first)
        XCTAssertTrue(knownModel.hasKnownPricing)
        XCTAssertEqual(inputOnly.pricingAssessment.outcomes(for: knownModel.name), [.knownPaid])

        let inputAndOutput = try build(
            model: "partial-null-tier-model",
            inputTokens: 250_000,
            outputTokens: 1_000,
            rawCost: 99,
            table: table
        )
        let unknownModel = try XCTUnwrap(inputAndOutput.snapshot.models.first)
        XCTAssertFalse(unknownModel.hasKnownPricing)
        XCTAssertEqual(inputAndOutput.pricingAssessment.outcomes(for: unknownModel.name), [.intentionalUnknown])
    }

    func testMonthlyBuilderUsesKnownFreeAndUnknownSeparately() throws {
        let table = CustomPricingTable(entries: [
            "free-model": CustomModelPricing(
                inputCostPerToken: 0,
                outputCostPerToken: 0,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let response = try decodeResponse("""
        {"monthly":[{"agent":"all","period":"2026-08","agents":[{"agent":"codex","modelBreakdowns":[
          {"modelName":"free-model","inputTokens":100,"cost":0},
          {"modelName":"missing-model","inputTokens":100,"cost":0}
        ]}],"totalTokens":200,"totalCost":0}]}
        """)

        let result = UsageSnapshotBuilder.makeMonthlyBudgetResult(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: table.revision,
            pricingContext: PricingResolutionContext(table: table)
        )
        let free = try XCTUnwrap(result.snapshot.models.first { $0.name == "free-model" })
        XCTAssertTrue(free.hasKnownPricing)
        XCTAssertEqual(free.estimatedCost, 0)
        XCTAssertEqual(result.snapshot.unknownPricingModels, ["missing-model"])
        XCTAssertEqual(result.snapshot.estimatedCost, 0)
    }

    func testBothPolicyEntryPointsRejectUnpricedZeroButAcceptKnownFree() throws {
        let previous = try build(
            model: "priced-model",
            inputTokens: 1_000,
            rawCost: 10,
            table: CustomPricingTable(entries: [
                "priced-model": CustomModelPricing(
                    inputCostPerToken: 0.000001,
                    outputCostPerToken: nil,
                    cacheCreationInputTokenCost: nil,
                    cacheReadInputTokenCost: nil
                )
            ])
        ).snapshot
        let freeTable = CustomPricingTable(entries: [
            "priced-model": CustomModelPricing(
                inputCostPerToken: 0,
                outputCostPerToken: nil,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let freeResult = try build(
            model: "priced-model",
            inputTokens: 1_000,
            rawCost: 10,
            table: freeTable
        )
        XCTAssertTrue(PricingRefreshPolicy.accepts(
            candidate: freeResult.snapshot,
            previous: previous,
            pricingAssessment: freeResult.pricingAssessment
        ))
        XCTAssertTrue(PricingRefreshPolicy.acceptsAfterPricingRevisionChange(
            candidate: freeResult.snapshot,
            previous: previous,
            pricingAssessment: freeResult.pricingAssessment
        ))

        let unknownResult = try build(
            model: "priced-model",
            inputTokens: 1_000,
            rawCost: 0,
            table: .empty
        )
        XCTAssertFalse(PricingRefreshPolicy.accepts(
            candidate: unknownResult.snapshot,
            previous: previous,
            pricingAssessment: unknownResult.pricingAssessment
        ))
        XCTAssertFalse(PricingRefreshPolicy.acceptsAfterPricingRevisionChange(
            candidate: unknownResult.snapshot,
            previous: previous,
            pricingAssessment: unknownResult.pricingAssessment
        ))
    }

    func testBothPolicyEntryPointsAcceptIntentionalUnknownFromPartialCustomPricing() throws {
        let previous = try build(
            model: "partial-policy-model",
            inputTokens: 1_000,
            outputTokens: 100,
            rawCost: 10,
            table: CustomPricingTable(entries: [
                "partial-policy-model": CustomModelPricing(
                    inputCostPerToken: 0.000001,
                    outputCostPerToken: 0.000002,
                    cacheCreationInputTokenCost: nil,
                    cacheReadInputTokenCost: nil
                )
            ])
        ).snapshot
        let candidateResult = try build(
            model: "partial-policy-model",
            inputTokens: 1_000,
            outputTokens: 100,
            rawCost: 99,
            table: CustomPricingTable(entries: [
                "partial-policy-model": CustomModelPricing(
                    inputCostPerToken: 0.000001,
                    outputCostPerToken: nil,
                    cacheCreationInputTokenCost: nil,
                    cacheReadInputTokenCost: nil
                )
            ])
        )

        XCTAssertEqual(
            candidateResult.pricingAssessment.outcomes(for: "partial-policy-model"),
            [.intentionalUnknown]
        )
        XCTAssertTrue(PricingRefreshPolicy.accepts(
            candidate: candidateResult.snapshot,
            previous: previous,
            pricingAssessment: candidateResult.pricingAssessment
        ))
        XCTAssertTrue(PricingRefreshPolicy.acceptsAfterPricingRevisionChange(
            candidate: candidateResult.snapshot,
            previous: previous,
            pricingAssessment: candidateResult.pricingAssessment
        ))
    }

    func testMissingRemoteCatalogModelFallsBackToCcusageWithoutErasingPreviouslyTrustedPricing() throws {
        let previous = try build(
            model: "catalog-model",
            inputTokens: 1_000,
            rawCost: 10,
            table: CustomPricingTable(entries: [
                "catalog-model": CustomModelPricing(
                    inputCostPerToken: 0.000001,
                    outputCostPerToken: nil,
                    cacheCreationInputTokenCost: nil,
                    cacheReadInputTokenCost: nil
                )
            ])
        ).snapshot
        let candidateResult = try build(
            model: "catalog-model",
            inputTokens: 1_000,
            rawCost: 99,
            table: .empty,
            pricingContext: PricingResolutionContext(
                table: .empty,
                remoteCatalogRevision: "catalog-revision"
            )
        )

        XCTAssertEqual(
            candidateResult.pricingAssessment.outcomes(for: "catalog-model"),
            [.knownPaid]
        )
        let candidateModel = try XCTUnwrap(candidateResult.snapshot.models.first)
        XCTAssertTrue(candidateModel.hasKnownPricing)
        XCTAssertEqual(candidateModel.pricingSource, .ccusage)
        XCTAssertEqual(candidateModel.estimatedCost, 99, accuracy: 0.0000001)
        XCTAssertTrue(PricingRefreshPolicy.accepts(
            candidate: candidateResult.snapshot,
            previous: previous,
            pricingAssessment: candidateResult.pricingAssessment
        ))
        XCTAssertTrue(PricingRefreshPolicy.acceptsAfterPricingRevisionChange(
            candidate: candidateResult.snapshot,
            previous: previous,
            pricingAssessment: candidateResult.pricingAssessment
        ))
    }

    func testMonthlyMissingRemoteCatalogModelFallsBackToCcusage() throws {
        let response = try decodeResponse("""
        {"monthly":[{"agent":"all","period":"2026-08","agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"catalog-model","inputTokens":1000,"cost":99}]}],"totalTokens":1000,"totalCost":99}]}
        """)
        let result = UsageSnapshotBuilder.makeMonthlyBudgetResult(
            from: response,
            month: "2026-08",
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            modelCatalogRevision: "catalog-revision",
            pricingContext: PricingResolutionContext(
                table: .empty,
                remoteCatalogRevision: "catalog-revision"
            )
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 99, accuracy: 0.0000001)
        XCTAssertEqual(result.snapshot.estimatedCost, 99, accuracy: 0.0000001)
        XCTAssertTrue(result.snapshot.unknownPricingModels.isEmpty)
        XCTAssertEqual(result.pricingAssessment.outcomes(for: model.name), [.knownPaid])
    }

    func testCatalogGapPreservesOnlyTheAffectedModelFromThePreviousPricingBasis() {
        let scope = UsageQueryScope(
            since: "2026-08-01",
            until: "2026-08-17",
            timeZone: "UTC",
            lookbackDays: 30
        )
        let previousCatalogModel = ModelUsage(
            agent: "codex",
            name: "catalog-model",
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 10,
            hasKnownPricing: true,
            pricingSource: .remote,
            pricingProviderIDs: ["remote-provider"]
        )
        let previousOnlyModel = ModelUsage(
            agent: "codex",
            name: "previous-only-model",
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 20,
            hasKnownPricing: true,
            pricingSource: .ccusage
        )
        let previous = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: 100),
            pricingUpdatedAt: Date(timeIntervalSince1970: 100),
            queryScope: scope,
            customPricingRevision: nil,
            modelCatalogRevision: "old-catalog",
            days: [DailyUsage(
                period: scope.until,
                tokens: TokenTotals(inputTokens: 20),
                estimatedCost: 30
            )],
            dailyModels: [DailyModelUsage(
                period: scope.until,
                agent: "codex",
                name: previousCatalogModel.name,
                tokens: previousCatalogModel.tokens,
                estimatedCost: previousCatalogModel.estimatedCost,
                hasKnownPricing: true,
                pricingSource: .remote,
                pricingProviderIDs: ["remote-provider"]
            ), DailyModelUsage(
                period: scope.until,
                agent: "codex",
                name: previousOnlyModel.name,
                tokens: previousOnlyModel.tokens,
                estimatedCost: previousOnlyModel.estimatedCost,
                hasKnownPricing: true,
                pricingSource: .ccusage
            )],
            agents: [AgentUsage(name: "codex", tokens: TokenTotals(inputTokens: 20), estimatedCost: 30)],
            models: [previousCatalogModel, previousOnlyModel],
            totalTokens: TokenTotals(inputTokens: 20),
            estimatedCost: 30,
            unknownPricingModels: [],
            pricingSource: .mixed
        )
        let candidateModel = ModelUsage(
            agent: "codex",
            name: "catalog-model",
            tokens: TokenTotals(inputTokens: 10),
            estimatedCost: 0,
            hasKnownPricing: false
        )
        let newModel = ModelUsage(
            agent: "codex",
            name: "new-model",
            tokens: TokenTotals(outputTokens: 10),
            estimatedCost: 4,
            hasKnownPricing: true,
            pricingSource: .ccusage
        )
        let candidate = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: 200),
            pricingUpdatedAt: Date(timeIntervalSince1970: 200),
            queryScope: scope,
            customPricingRevision: nil,
            modelCatalogRevision: "new-catalog",
            days: [DailyUsage(
                period: scope.until,
                tokens: TokenTotals(inputTokens: 10, outputTokens: 10),
                estimatedCost: 4
            )],
            dailyModels: [DailyModelUsage(
                period: scope.until,
                agent: "codex",
                name: candidateModel.name,
                tokens: candidateModel.tokens,
                estimatedCost: 0,
                hasKnownPricing: false
            ), DailyModelUsage(
                period: scope.until,
                agent: "codex",
                name: newModel.name,
                tokens: newModel.tokens,
                estimatedCost: newModel.estimatedCost,
                hasKnownPricing: true,
                pricingSource: .ccusage
            )],
            agents: [AgentUsage(name: "codex", tokens: TokenTotals(inputTokens: 10, outputTokens: 10), estimatedCost: 4)],
            models: [candidateModel, newModel],
            totalTokens: TokenTotals(inputTokens: 10, outputTokens: 10),
            estimatedCost: 4,
            unknownPricingModels: [candidateModel.name],
            pricingSource: .mixed
        )
        var assessment = PricingAssessmentContext.empty
        assessment.record(
            modelName: candidateModel.name,
            outcome: .intentionalUnknown,
            catalogGap: .ambiguous
        )

        let merged = UsageSnapshot.mergingUsage(
            candidate,
            preservingPricingFrom: previous,
            pricingAssessment: assessment
        )

        let preserved = merged.models.first { $0.name == candidateModel.name }
        XCTAssertEqual(preserved?.estimatedCost, previousCatalogModel.estimatedCost)
        XCTAssertTrue(preserved?.hasKnownPricing == true)
        XCTAssertEqual(preserved?.pricingSource, .remote)
        XCTAssertEqual(preserved?.pricingProviderIDs, ["remote-provider"])
        XCTAssertNil(merged.models.first { $0.name == previousOnlyModel.name })
        XCTAssertEqual(merged.models.first { $0.name == newModel.name }?.estimatedCost, newModel.estimatedCost)
        XCTAssertTrue(merged.unknownPricingModels.isEmpty)
    }

    func testPricingExecutionBasisOwnsCompositionAndRevisionIdentity() {
        let table = CustomPricingTable(entries: [
            "basis-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let basis = PricingExecutionBasis(
            customTable: table,
            modelCatalogRevision: "catalog-revision"
        )

        XCTAssertEqual(basis.composition, PricingCatalogComposition.make(customTable: table, remoteEntries: []))
        XCTAssertTrue(basis.matches(
            customPricingRevision: table.revision,
            modelCatalogRevision: "catalog-revision"
        ))
        XCTAssertFalse(basis.matches(
            customPricingRevision: nil,
            modelCatalogRevision: "catalog-revision"
        ))
    }

    private func build(
        model: String,
        inputTokens: Int64,
        outputTokens: Int64 = 0,
        rawCost: Double?,
        table: CustomPricingTable,
        pricingContext: PricingResolutionContext? = nil
    ) throws -> UsageSnapshotBuildResult {
        let rawCostField = rawCost.map { ",\"cost\":\($0)" } ?? ""
        let response = try decodeResponse("""
        {"daily":[{"agent":"all","period":"2026-08-17","inputTokens":\(inputTokens),"outputTokens":\(outputTokens),"agents":[{"agent":"codex","inputTokens":\(inputTokens),"outputTokens":\(outputTokens),"modelBreakdowns":[{"modelName":"\(model)","inputTokens":\(inputTokens),"outputTokens":\(outputTokens)\(rawCostField)}]}]}]}
        """)
        return UsageSnapshotBuilder.makeResult(
            from: response,
            pricingUpdatedAt: nil,
            queryScope: UsageQueryScope(since: "2026-08-01", until: "2026-08-17", timeZone: "UTC", lookbackDays: 30),
            pricingContext: pricingContext ?? PricingResolutionContext(table: table)
        )
    }

    private func decodeResponse(_ json: String) throws -> CCUsageResponse {
        try JSONDecoder().decode(CCUsageResponse.self, from: Data(json.utf8))
    }
}
