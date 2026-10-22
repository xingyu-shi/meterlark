import Foundation
import XCTest
@testable import MeterlarkApp

final class CcusagePricingAdapterTests: XCTestCase {
    func testTargetCapabilitiesNormalizePinnedModelVersionsWithoutGuessingUnknowns() {
        let capabilities = CcusagePricingCapabilities.bundledV20
        XCTAssertTrue(capabilities.supportsExplicitZeroOverrides)

        XCTAssertEqual(
            capabilities.effectiveThreshold(for: "gpt-5.6-luna-2026-08-17"),
            272_000
        )
        XCTAssertEqual(
            capabilities.effectiveThreshold(for: "gpt-6-astra-2026-09-24"),
            272_000
        )
        XCTAssertEqual(capabilities.effectiveThreshold(for: "gpt-6.1-sol@eu"), 272_000)
        XCTAssertEqual(
            capabilities.effectiveThreshold(for: "provider/my-luna"),
            200_000
        )
    }

    func testCanonicalCatalogParsesArbitraryTierThresholdAndMetadata() throws {
        let table = try loadTable(
            """
            {
              "data": [{
                "model_name": "gpt-5.6-luna",
                "model_info": {
                  "input_cost_per_token": 0.0000002,
                  "output_cost_per_token": 0.0000012,
                  "cache_creation_input_token_cost": 0.00000025,
                  "cache_read_input_token_cost": 0.00000002,
                  "input_cost_per_token_above_128k_tokens": null,
                  "input_cost_per_token_above_200k_tokens": null,
                  "input_cost_per_token_above_272k_tokens": 0.0000004,
                  "output_cost_per_token_above_272k_tokens": 0.0000018,
                  "cache_creation_input_token_cost_above_272k_tokens": 0.0000005,
                  "cache_read_input_token_cost_above_272k_tokens": 0.00000004,
                  "input_cost_per_token_above_512k_tokens": null,
                  "output_cost_per_token_above_128k_tokens": null,
                  "output_cost_per_token_above_200k_tokens": null,
                  "output_cost_per_token_above_512k_tokens": null,
                  "cache_creation_input_token_cost_above_128k_tokens": null,
                  "cache_creation_input_token_cost_above_200k_tokens": null,
                  "cache_creation_input_token_cost_above_512k_tokens": null,
                  "cache_read_input_token_cost_above_128k_tokens": null,
                  "cache_read_input_token_cost_above_200k_tokens": null,
                  "cache_read_input_token_cost_above_512k_tokens": null,
                  "fast_multiplier": 3,
                  "max_input_tokens": 1050000,
                  "input_cost_per_token_above_272k_tokens_priority": 0.0000009
                }
              }]
            }
            """
        )

        let model = try XCTUnwrap(table.canonicalPricingCatalog.models.first)
        XCTAssertEqual(model.base.input, 0.0000002)
        XCTAssertEqual(model.tiers.map(\.threshold), [272_000])
        XCTAssertEqual(model.tiers.first?.rates.output, 0.0000018)
        XCTAssertEqual(model.fastMultiplier, 3)
        XCTAssertEqual(model.maxInputTokens, 1_050_000)

        let preparation = CcusagePricingAdapter.bundledV20.preparation(
            for: table.canonicalPricingCatalog
        )
        XCTAssertFalse(preparation.approximateModelNames.contains("gpt-5.6-luna"))
        XCTAssertEqual(preparation.selectedTierThresholds["gpt-5.6-luna"], 272_000)
        XCTAssertEqual(preparation.diagnostics, [])
    }

    func testKnown272kModelUsesCcusageCompatibilityFieldNames() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"gpt-5.6-luna","model_info":{
              "input_cost_per_token":0.0000002,
              "output_cost_per_token":0.0000012,
              "input_cost_per_token_above_272k_tokens":0.0000004,
              "output_cost_per_token_above_272k_tokens":0.0000018
            }}]}
            """
        )

        let data = try CcusagePricingAdapter.bundledV20.data(for: table.canonicalPricingCatalog)
        let output = String(decoding: data, as: UTF8.self)
        let override = try XCTUnwrap(override(in: data, model: "gpt-5.6-luna"))

        XCTAssertTrue(output.contains("inputCostPerTokenAbove200kTokens"))
        XCTAssertTrue(output.contains("outputCostPerTokenAbove200kTokens"))
        XCTAssertEqual(override["inputCostPerTokenAbove200kTokens"] as? Double, 0.0000004)
        XCTAssertEqual(override["outputCostPerTokenAbove200kTokens"] as? Double, 0.0000018)
    }

    func testAdapterEmitsNumericZeroOverrides() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"free-model","model_info":{
              "input_cost_per_token":0,
              "output_cost_per_token":0,
              "input_cost_per_token_above_200k_tokens":0
            }}]}
            """
        )

        let data = try CcusagePricingAdapter.bundledV20.data(for: table.canonicalPricingCatalog)
        let override = try XCTUnwrap(override(in: data, model: "free-model"))

        XCTAssertEqual(override["inputCostPerToken"] as? Double, 0)
        XCTAssertEqual(override["outputCostPerToken"] as? Double, 0)
        XCTAssertEqual(override["inputCostPerTokenAbove200kTokens"] as? Double, 0)
    }

    func testUnknown272kModelUsesApproximateAbove200kMapping() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"my-luna","model_info":{
              "input_cost_per_token":0.0000002,
              "output_cost_per_token":0.0000012,
              "input_cost_per_token_above_272k_tokens":0.0000004,
              "output_cost_per_token_above_272k_tokens":0.0000018
            }}]}
            """
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let preparation = try CcusagePricingAdapter.bundledV20.prepare(
            catalog: table.canonicalPricingCatalog,
            writeTo: url
        )

        XCTAssertTrue(preparation.hasOverrides)
        XCTAssertTrue(preparation.appliedModelNames.contains("my-luna"))
        XCTAssertTrue(preparation.approximateModelNames.contains("my-luna"))
        XCTAssertEqual(preparation.selectedTierThresholds["my-luna"], 272_000)
        XCTAssertEqual(preparation.selectedBackendThresholds["my-luna"], 200_000)
        XCTAssertEqual(preparation.diagnostics.first?.reason, .unsupportedThreshold)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTwoSourceTiersSelectClosestSupportedTierAndMarkApproximate() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"gpt-5.6-luna","model_info":{
              "input_cost_per_token":0.0000002,
              "output_cost_per_token":0.0000012,
              "input_cost_per_token_above_200k_tokens":0.0000003,
              "input_cost_per_token_above_272k_tokens":0.0000004
            }}]}
            """
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let preparation = try CcusagePricingAdapter.bundledV20.prepare(
            catalog: table.canonicalPricingCatalog,
            writeTo: url
        )

        XCTAssertTrue(preparation.hasOverrides)
        XCTAssertTrue(preparation.approximateModelNames.contains("gpt-5.6-luna"))
        XCTAssertEqual(preparation.selectedTierThresholds["gpt-5.6-luna"], 272_000)
        XCTAssertEqual(preparation.selectedBackendThresholds["gpt-5.6-luna"], 272_000)
        XCTAssertEqual(preparation.diagnostics.first?.reason, .multipleTiers)
        let override = try XCTUnwrap(override(in: try Data(contentsOf: url), model: "gpt-5.6-luna"))
        XCTAssertEqual(override["inputCostPerTokenAbove200kTokens"] as? Double, 0.0000004)
    }

    func testStandard200kTierWorksForModelWithout272kProfile() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"generic-model","model_info":{
              "input_cost_per_token":0.000001,
              "output_cost_per_token":0.000002,
              "input_cost_per_token_above_200k_tokens":0.000003
            }}]}
            """
        )

        let data = try CcusagePricingAdapter.bundledV20.data(for: table.canonicalPricingCatalog)
        let output = String(decoding: data, as: UTF8.self)
        let override = try XCTUnwrap(override(in: data, model: "generic-model"))

        XCTAssertTrue(output.contains("generic-model"))
        XCTAssertTrue(output.contains("inputCostPerTokenAbove200kTokens"))
        XCTAssertEqual(override["inputCostPerTokenAbove200kTokens"] as? Double, 0.000003)
    }

    func testOrdinary128kTierUsesApproximateAbove200kMapping() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"ordinary-model","model_info":{
              "input_cost_per_token":0.000001,
              "input_cost_per_token_above_128k_tokens":0.000003
            }}]}
            """
        )

        let data = try CcusagePricingAdapter.bundledV20.data(for: table.canonicalPricingCatalog)
        let override = try XCTUnwrap(override(in: data, model: "ordinary-model"))
        XCTAssertEqual(override["inputCostPerTokenAbove200kTokens"] as? Double, 0.000003)
    }

    func testEquidistantTiersChooseTheLowerThreshold() throws {
        let table = try loadTable(
            """
            {"data":[{"model_name":"ordinary-model","model_info":{
              "input_cost_per_token":0.000001,
              "input_cost_per_token_above_128k_tokens":0.000003,
              "input_cost_per_token_above_272k_tokens":0.000005
            }}]}
            """
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let preparation = try CcusagePricingAdapter.bundledV20.prepare(
            catalog: table.canonicalPricingCatalog,
            writeTo: url
        )

        XCTAssertEqual(preparation.selectedTierThresholds["ordinary-model"], 128_000)
        XCTAssertTrue(preparation.approximateModelNames.contains("ordinary-model"))
    }

    func testAnnotationPreservesBackendCostExactly() {
        let tokens = TokenTotals(inputTokens: 300_000, outputTokens: 1_000)
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 12.34)],
            dailyModels: [DailyModelUsage(
                period: "2026-08-17",
                agent: "codex",
                name: "gpt-5.6-luna-2026-08-17",
                tokens: tokens,
                estimatedCost: 12.34,
                hasKnownPricing: true
            )],
            agents: [AgentUsage(name: "codex", tokens: tokens, estimatedCost: 12.34)],
            models: [ModelUsage(
                agent: "codex",
                name: "gpt-5.6-luna-2026-08-17",
                tokens: tokens,
                estimatedCost: 12.34,
                hasKnownPricing: true
            )],
            totalTokens: tokens,
            estimatedCost: 12.34,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )

        let annotated = PricingSnapshotAnnotation.apply(
            to: snapshot,
            customPricingRevision: "revision",
            appliedModelNames: ["gpt-5.6-luna"],
            approximateModelNames: ["gpt-5.6-luna"],
            selectedTierThresholds: ["gpt-5.6-luna": 272_000],
            selectedBackendThresholds: ["gpt-5.6-luna": 272_000]
        )

        XCTAssertEqual(annotated.estimatedCost, 12.34)
        XCTAssertEqual(annotated.days.first?.estimatedCost, 12.34)
        XCTAssertEqual(annotated.models.first?.estimatedCost, 12.34)
        XCTAssertEqual(annotated.customPricingRevision, "revision")
        XCTAssertEqual(annotated.pricingSource, .approximate)
        XCTAssertEqual(annotated.models.first?.pricingSource, .approximate)
        XCTAssertEqual(annotated.models.first?.pricingTierThreshold, 272_000)
        XCTAssertEqual(annotated.models.first?.pricingBackendThreshold, 272_000)
        XCTAssertEqual(annotated.dailyModels.first?.pricingSource, .approximate)
    }

    func testAnnotationPreservesRemoteTierDetails() {
        let tokens = TokenTotals(inputTokens: 300_000, outputTokens: 1_000)
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 12.34)],
            dailyModels: [DailyModelUsage(
                period: "2026-08-17",
                agent: "codex",
                name: "remote-model",
                tokens: tokens,
                estimatedCost: 12.34,
                hasKnownPricing: true,
                pricingSource: .remote,
                pricingProviderIDs: ["example-gateway"]
            )],
            agents: [],
            models: [ModelUsage(
                agent: "codex",
                name: "remote-model",
                tokens: tokens,
                estimatedCost: 12.34,
                hasKnownPricing: true,
                pricingSource: .remote,
                pricingProviderIDs: ["example-gateway"]
            )],
            totalTokens: tokens,
            estimatedCost: 12.34,
            unknownPricingModels: [],
            pricingSource: .remote
        )

        let annotated = PricingSnapshotAnnotation.apply(
            to: snapshot,
            customPricingRevision: nil,
            appliedModelNames: ["remote-model"],
            approximateModelNames: [],
            selectedTierThresholds: ["remote-model": 272_000],
            selectedBackendThresholds: ["remote-model": 200_000]
        )

        XCTAssertEqual(annotated.models.first?.pricingSource, .remote)
        XCTAssertEqual(annotated.models.first?.pricingProviderIDs, ["example-gateway"])
        XCTAssertEqual(annotated.models.first?.pricingTierThreshold, 272_000)
        XCTAssertEqual(annotated.models.first?.pricingBackendThreshold, 200_000)
        XCTAssertEqual(annotated.dailyModels.first?.pricingTierThreshold, 272_000)
    }

    private func loadTable(_ json: String) throws -> CustomPricingTable {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-adapter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        return try CustomPricingTable(contentsOf: url)
    }

    private func override(in data: Data, model: String) throws -> [String: Any]? {
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let defaults = try XCTUnwrap(document["defaults"] as? [String: Any])
        let overrides = try XCTUnwrap(defaults["pricingOverrides"] as? [String: Any])
        return overrides[model] as? [String: Any]
    }
}
