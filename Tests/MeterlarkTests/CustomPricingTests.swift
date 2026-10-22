import XCTest
@testable import MeterlarkApp

final class CustomPricingTests: XCTestCase {
    func testPricingLookupMatchesDatePinnedUsageModel() {
        let table = CustomPricingTable(entries: [
            "gpt-5.6-luna": CustomModelPricing(
                inputCostPerToken: 0.0000002,
                outputCostPerToken: 0.0000012,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])

        XCTAssertNotNil(table.pricing(for: "gpt-5.6-luna-2026-08-17"))
    }

    func testPricingRevisionIsCanonicalAndChangesWhenRatesChange() {
        let first = CustomPricingTable(entries: [
            "z-model": CustomModelPricing(inputCostPerToken: 0.000001, outputCostPerToken: 0.000002, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil),
            "a-model": CustomModelPricing(inputCostPerToken: 0.000003, outputCostPerToken: 0.000004, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        let sameValuesDifferentInsertionOrder = CustomPricingTable(entries: [
            "a-model": CustomModelPricing(inputCostPerToken: 0.000003, outputCostPerToken: 0.000004, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil),
            "z-model": CustomModelPricing(inputCostPerToken: 0.000001, outputCostPerToken: 0.000002, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        let changed = CustomPricingTable(entries: [
            "z-model": CustomModelPricing(inputCostPerToken: 0.000009, outputCostPerToken: 0.000002, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil),
            "a-model": CustomModelPricing(inputCostPerToken: 0.000003, outputCostPerToken: 0.000004, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])

        XCTAssertEqual(first.revision, sameValuesDifferentInsertionOrder.revision)
        XCTAssertNotEqual(first.revision, changed.revision)
    }

    func testLiteLLMPriceListLoadsAndNonZeroRatesOverrideCcusage() throws {
        let table = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "custom-model",
                  "model_info": {
                    "input_cost_per_token": 0.000001,
                    "output_cost_per_token": 0.000002,
                    "cache_creation_input_token_cost": 0.000003,
                    "cache_read_input_token_cost": 0.0000004
                  }
                }
              ]
            }
            """
        )
        let snapshot = makeSnapshot(
            dailyModels: [
                DailyModelUsage(
                    period: "2026-08-07",
                    agent: "codex",
                    name: "custom-model",
                    tokens: TokenTotals(inputTokens: 1_000_000, outputTokens: 100_000, cacheCreationTokens: 10_000, cacheReadTokens: 20_000),
                    estimatedCost: 99,
                    hasKnownPricing: true
                ),
                DailyModelUsage(
                    period: "2026-08-07",
                    agent: "codex",
                    name: "unknown-model",
                    tokens: TokenTotals(inputTokens: 100_000),
                    estimatedCost: 77,
                    hasKnownPricing: true
                )
            ]
        )

        let result = CustomPricingOverlay.apply(to: snapshot, table: table)

        XCTAssertEqual(result.dailyModels.first(where: { $0.name == "custom-model" })?.estimatedCost ?? -1, 1.238, accuracy: 0.000001)
        XCTAssertEqual(result.dailyModels.first(where: { $0.name == "unknown-model" })?.estimatedCost, 77)
        XCTAssertEqual(result.days.first?.estimatedCost ?? -1, 78.238, accuracy: 0.000001)
    }

    func testZeroPriceIsUsableAndRepresentsKnownFreePricing() throws {
        let table = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "zero-model",
                  "model_info": {
                    "input_cost_per_token": 0,
                    "output_cost_per_token": 0
                  }
                }
              ]
            }
            """
        )
        XCTAssertTrue(table.modelNamesWithUsableRates.contains("zero-model"))
        let snapshot = makeSnapshot(
            dailyModels: [
                DailyModelUsage(
                    period: "2026-08-07",
                    agent: "codex",
                    name: "zero-model",
                    tokens: TokenTotals(inputTokens: 1_000),
                    estimatedCost: 12,
                    hasKnownPricing: true
                )
            ]
        )

        let result = CustomPricingOverlay.apply(to: snapshot, table: table)

        XCTAssertEqual(result.dailyModels.first?.estimatedCost, 0)
        XCTAssertTrue(result.dailyModels.first?.hasKnownPricing == true)
        XCTAssertEqual(result.estimatedCost, 0)
    }

    func testExplicitZeroMatchesTheFreePriceCatalogFilter() {
        XCTAssertTrue(ModelCatalogPriceRange.under1.matches(inputCostPerToken: 0))
        XCTAssertFalse(ModelCatalogPriceRange.oneTo5.matches(inputCostPerToken: 0))
    }

    func testPartialPriceDoesNotSilentlyTreatMissingTokenRatesAsFree() throws {
        let table = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "partial-model",
                  "model_info": {
                    "input_cost_per_token": 0.000001
                  }
                }
              ]
            }
            """
        )
        let snapshot = makeSnapshot(
            dailyModels: [
                DailyModelUsage(
                    period: "2026-08-07",
                    agent: "codex",
                    name: "partial-model",
                    tokens: TokenTotals(inputTokens: 1_000, cacheReadTokens: 2_000),
                    estimatedCost: 12,
                    hasKnownPricing: true
                )
            ]
        )

        let result = CustomPricingOverlay.apply(to: snapshot, table: table)

        XCTAssertEqual(result.dailyModels.first?.estimatedCost, 12)
        XCTAssertTrue(result.dailyModels.first?.hasKnownPricing == true)
    }

    func testMissingModelKeepsCcusageCost() throws {
        let table = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "different-model",
                  "model_info": {
                    "input_cost_per_token": 0
                  }
                }
              ]
            }
            """
        )
        let snapshot = makeSnapshot(
            dailyModels: [
                DailyModelUsage(
                    period: "2026-08-07",
                    agent: "codex",
                    name: "unknown-model",
                    tokens: TokenTotals(inputTokens: 1_000),
                    estimatedCost: 12,
                    hasKnownPricing: true
                )
            ]
        )

        let result = CustomPricingOverlay.apply(to: snapshot, table: table)

        XCTAssertEqual(result.dailyModels.first?.estimatedCost, 12)
        XCTAssertEqual(result.estimatedCost, 12)
    }

    func testImportMergePrefersIncomingFieldsAndKeepsExistingFieldsAndModels() throws {
        let existing = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "shared-model",
                  "model_info": {
                    "input_cost_per_token": 0.000001,
                    "output_cost_per_token": 0.000002,
                    "cache_read_input_token_cost": 0.000003
                  }
                },
                {
                  "model_name": "old-model",
                  "model_info": { "input_cost_per_token": 0.000004 }
                }
              ]
            }
            """
        )
        let incoming = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "shared-model",
                  "model_info": {
                    "input_cost_per_token": 0.000009,
                    "output_cost_per_token": 0
                  }
                },
                {
                  "model_name": "new-model",
                  "model_info": { "input_cost_per_token": 0.000005 }
                }
              ]
            }
            """
        )

        let merged = existing.merged(with: incoming)

        XCTAssertEqual(merged.modelCount, 3)
        XCTAssertEqual(merged.pricing(for: "SHARED-MODEL")?.inputCostPerToken, 0.000009)
        XCTAssertEqual(merged.pricing(for: "shared-model")?.outputCostPerToken, 0)
        XCTAssertEqual(merged.pricing(for: "shared-model")?.cacheReadInputTokenCost, 0.000003)
        XCTAssertEqual(merged.pricing(for: "old-model")?.inputCostPerToken, 0.000004)
        XCTAssertEqual(merged.pricing(for: "new-model")?.inputCostPerToken, 0.000005)
    }

    func testExportRoundTripsAsLiteLLMPriceList() throws {
        let table = try loadTable(
            """
            {
              "pricingOverrides": {
                "Shared-Model": {
                  "input_cost_per_token": 0.000001,
                  "output_cost_per_token": 0
                }
              }
            }
            """
        )

        let data = try table.encodedData()
        let exported = String(decoding: data, as: UTF8.self)
        let roundTripped = try CustomPricingTable(data: data)

        XCTAssertEqual(roundTripped.entries, table.entries)
        XCTAssertEqual(roundTripped.displayNames, table.displayNames)
        XCTAssertEqual(roundTripped.pricing(for: "shared-model")?.outputCostPerToken, 0)
        XCTAssertTrue(exported.contains("\"model_name\""))
        XCTAssertTrue(exported.contains("\"model_info\""))
        XCTAssertTrue(exported.contains("\"input_cost_per_token\""))
        XCTAssertTrue(exported.contains("\"output_cost_per_token\""))
        XCTAssertTrue(exported.contains("Shared-Model"))
        XCTAssertFalse(exported.contains("pricingOverrides"))
    }

    func testImportedMetadataRoundTripsIntoModelCatalogEntry() throws {
        let table = try loadTable(
            """
            {
              "data": [{
                "model_name": "gpt-5.6-terra",
                "litellm_params": {
                  "model": "azure/gpt-5.6-terra",
                  "custom_llm_provider": "azure"
                },
                "model_info": {
                  "input_cost_per_token": 0.000001,
                  "output_cost_per_token": 0.000006,
                  "cache_read_input_token_cost": 0.0000001,
                  "max_input_tokens": 272000,
                  "max_output_tokens": 64000,
                  "litellm_provider": "azure",
                  "mode": "chat",
                  "supports_vision": true,
                  "supports_reasoning": true,
                  "page_display_data": {
                    "provider": "Azure Foundry",
                    "version": "2026-07-09",
                    "description": "A reasoning model for coding.",
                    "modality": ["Text", "Vision"]
                  }
                }
              }]
            }
            """
        )

        let entry = try XCTUnwrap(table.modelCatalogEntries.first)

        XCTAssertEqual(entry.modelName, "gpt-5.6-terra")
        XCTAssertEqual(entry.provider, "azure")
        XCTAssertEqual(entry.route, "azure/gpt-5.6-terra")
        XCTAssertEqual(entry.maxInputTokens, 272_000)
        XCTAssertEqual(entry.maxOutputTokens, 64_000)
        XCTAssertEqual(entry.modalities, ["Text", "Vision"])
        XCTAssertEqual(entry.description, "A reasoning model for coding.")
        XCTAssertTrue(entry.capabilityKeys.contains("supports_vision"))
        XCTAssertTrue(entry.capabilityKeys.contains("supports_reasoning"))
        XCTAssertTrue(entry.searchableText.contains("azure"))
        XCTAssertTrue(entry.searchableText.contains("reasoning"))

        let exported = try table.encodedData()
        let roundTripped = try CustomPricingTable(data: exported)
        let roundTrippedEntry = try XCTUnwrap(roundTripped.modelCatalogEntries.first)

        XCTAssertEqual(roundTrippedEntry.metadata, entry.metadata)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("litellm_params"))
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("supports_vision"))
    }

    func testMetadataMergeRecursivelyKeepsOmittedNestedFields() throws {
        let existing = try loadTable(
            """
            {"data": [{"model_name":"shared-model","model_info":{
              "input_cost_per_token":0.000001,
              "page_display_data":{"provider":"Existing","version":"v1","modality":["Text"]}
            }}]}
            """
        )
        let incoming = try loadTable(
            """
            {"data": [{"model_name":"shared-model","model_info":{
              "output_cost_per_token":0.000002,
              "page_display_data":{"description":"Incoming description"}
            }}]}
            """
        )

        let entry = try XCTUnwrap(existing.merged(with: incoming).modelCatalogEntries.first)

        XCTAssertEqual(entry.provider, "Existing")
        XCTAssertEqual(entry.version, "v1")
        XCTAssertEqual(entry.description, "Incoming description")
        XCTAssertEqual(entry.modalities, ["Text"])
    }

    func testLegacyPricingOverrideWinsOverImportedMetadataInCatalog() throws {
        let table = try loadTable(
            """
            {
              "data": [{
                "model_name": "shared-model",
                "model_info": {"input_cost_per_token": 0.000001}
              }],
              "pricingOverrides": {
                "shared-model": {"input_cost_per_token": 0.000009}
              }
            }
            """
        )

        XCTAssertEqual(table.modelCatalogEntries.first?.pricing.inputCostPerToken, 0.000009)
        XCTAssertEqual(table.modelCatalogEntries.first?.rateValue(for: "input_cost_per_token"), 0.000009)

        let persisted = try CustomPricingTable(data: table.encodedData())
        XCTAssertEqual(persisted.pricing(for: "shared-model")?.inputCostPerToken, 0.000009)
        XCTAssertEqual(persisted.modelCatalogEntries.first?.rateValue(for: "input_cost_per_token"), 0.000009)
    }

    func testMetadataNumbersRoundTripWithoutDoublePrecisionLoss() throws {
        let table = try loadTable(
            """
            {"data": [{"model_name":"numeric-model","model_info":{
              "large_integer":9007199254740993,
              "precise_decimal":0.0000000000000000001234567890123456789,
              "input_cost_per_token":0.000001,
              "output_cost_per_token":0.000002
            }}]}
            """
        )

        let exported = String(decoding: try table.encodedData(), as: UTF8.self)

        XCTAssertTrue(exported.contains("9007199254740993"))
        XCTAssertTrue(exported.contains("0.0000000000000000001234567890123456789"))
    }

    func testModelCatalogFiltersCombineProviderCapabilityPriceAndContext() throws {
        let table = try loadTable(
            """
            {
              "data": [
                {
                  "model_name": "vision-fast",
                  "model_info": {
                    "input_cost_per_token": 0.0000005,
                    "max_input_tokens": 300000,
                    "supports_function_calling": true,
                    "page_display_data": {"provider": "Azure", "modality": ["Text", "Vision"]}
                  }
                },
                {
                  "model_name": "text-expensive",
                  "model_info": {
                    "input_cost_per_token": 0.00001,
                    "max_input_tokens": 128000,
                    "supports_function_calling": true,
                    "page_display_data": {"provider": "Azure", "modality": ["Text"]}
                  }
                },
                {
                  "model_name": "vision-other-provider",
                  "model_info": {
                    "input_cost_per_token": 0.0000005,
                    "max_input_tokens": 300000,
                    "supports_function_calling": true,
                    "page_display_data": {"provider": "Other", "modality": ["Text", "Vision"]}
                  }
                }
              ]
            }
            """
        )

        let matches = ModelCatalogFilter.filter(
            table.modelCatalogEntries,
            query: "vision",
            provider: "Azure",
            modality: "Vision",
            capability: .functionCalling,
            priceRange: .under1,
            contextRange: .over200
        )

        XCTAssertEqual(matches.map(\.modelName), ["vision-fast"])
    }

    func testModelCatalogPriceAndContextFiltersExcludeMissingValues() throws {
        let table = try loadTable(
            """
            {"data": [{"model_name":"partial-model","model_info":{"supports_vision":true}}]}
            """
        )

        XCTAssertTrue(ModelCatalogFilter.filter(
            table.modelCatalogEntries,
            query: "",
            provider: "",
            modality: "",
            capability: .vision,
            priceRange: .under1,
            contextRange: .over200
        ).isEmpty)
    }

    private func loadTable(_ json: String) throws -> CustomPricingTable {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-custom-pricing-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try CustomPricingTable(contentsOf: url)
    }

    private func makeSnapshot(dailyModels: [DailyModelUsage]) -> UsageSnapshot {
        let period = dailyModels[0].period
        let periodTokens = dailyModels.reduce(TokenTotals.zero) { $0 + $1.tokens }
        let agents = [AgentUsage(
            name: "codex",
            tokens: periodTokens,
            estimatedCost: dailyModels.reduce(0) { $0 + $1.estimatedCost }
        )]
        let models = dailyModels.map {
            ModelUsage(
                agent: $0.agent,
                name: $0.name,
                tokens: $0.tokens,
                estimatedCost: $0.estimatedCost,
                hasKnownPricing: $0.hasKnownPricing
            )
        }
        return UsageSnapshot(
            schemaVersion: 2,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: period, tokens: periodTokens, estimatedCost: dailyModels.reduce(0) { $0 + $1.estimatedCost })],
            dailyModels: dailyModels,
            agents: agents,
            models: models,
            totalTokens: periodTokens,
            estimatedCost: dailyModels.reduce(0) { $0 + $1.estimatedCost },
            unknownPricingModels: []
        )
    }
}
