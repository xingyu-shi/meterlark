import Foundation
import XCTest
@testable import MeterlarkApp

final class ModelCatalogTests: XCTestCase {
    func testJSONModelCatalogManifestIsIndependentAndUsesBearerAPIKey() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.id, "com.example.meterlark.model-catalog")
        XCTAssertEqual(manifest.capabilities, [.modelCatalog])
        XCTAssertFalse(manifest.supportsDashboard)
        XCTAssertTrue(manifest.supportsModelCatalog)
        XCTAssertEqual(manifest.transport, .httpJSON)
        XCTAssertEqual(manifest.http?.method, .get)
        XCTAssertEqual(manifest.http?.urlField, "endpoint")
        XCTAssertEqual(
            manifest.configuration?.fields.map(\.id),
            ["endpoint", "apiKey"]
        )
        XCTAssertEqual(manifest.http?.headers.map(\.name), ["Accept", "Authorization"])
        XCTAssertEqual(manifest.http?.headers.map(\.valueField), [nil, "apiKey"])
        XCTAssertEqual(manifest.http?.headers.map(\.valuePrefix), [nil, "Bearer "])
        if case let .string(endpoint)? = manifest.configuration?.fields.first(where: { $0.id == "endpoint" })?.defaultValue {
            XCTAssertEqual(endpoint, "https://gateway.example.test/v1/models")
        } else {
            XCTFail("Expected the catalog endpoint default")
        }
        XCTAssertNoThrow(try manifest.validate())

        let package = repoRoot().appendingPathComponent("Examples/Plugins/ModelCatalog", isDirectory: true)
        let validated = try PluginPackageValidator().validate(packageURL: package)
        XCTAssertEqual(validated.manifest, manifest)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: package,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent),
            ["plugin.json"]
        )
    }

    func testModelCatalogProviderBuildsRequestAndMapsSampleLikeResponse() async throws {
        let manifest = try loadManifest()
        let recorder = RequestRecorder()
        let sender: HTTPJSONPluginProvider.RequestSender = { request in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (self.sampleLikeCatalogData(), response)
        }
        let provider = try HTTPJSONModelCatalogPluginProvider(
            manifest: manifest,
            configurationData: configurationData(
                endpoint: "https://api.example.test/prod/aiendpoint/v1/model/info",
                apiKey: "unit-test-api-key"
            ),
            send: sender
        )

        let snapshot = try await provider.fetchModelCatalog()
        XCTAssertEqual(snapshot.providerID, manifest.id)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.entries.filter { $0.modelName == "same-display-name" }.count, 2)
        XCTAssertEqual(snapshot.entries.filter { $0.recordIdentity == "id-a" }.count, 2)
        XCTAssertEqual(snapshot.entries.filter { $0.recordIdentity == "id-b" }.count, 1)

        let first = try XCTUnwrap(snapshot.entries.first { $0.recordIdentity == "id-a" && $0.modelName == "same-display-name" })
        XCTAssertEqual(first.route, "bedrock/route-a")
        XCTAssertEqual(first.provider, "bedrock")
        XCTAssertEqual(first.description, "A sample catalog model")
        XCTAssertEqual(first.modalities, ["Text", "Vision"])
        XCTAssertEqual(first.enabled, true)
        XCTAssertEqual(first.maxInputTokens, 200_000)
        XCTAssertEqual(first.pricing.inputCostPerToken, 0.00000025)
        XCTAssertEqual(first.pricingSchedule?.base.output, 0.00000125)
        XCTAssertEqual(first.pricingSchedule?.tiers.first?.threshold, 200_000)

        let recordedRequest = await recorder.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/prod/aiendpoint/v1/model/info")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-api-key")
    }

    func testRemoteNullCacheRatesMeanNoChargeButNullInputOutputRemainUnknown() throws {
        let data = Data("""
        {
          "data": [
            {
              "model_name": "free-cache-model",
              "model_info": {
                "id": "free-cache",
                "input_cost_per_token": 0,
                "output_cost_per_token": 0,
                "cache_creation_input_token_cost": null,
                "cache_read_input_token_cost": null
              }
            },
            {
              "model_name": "missing-input-model",
              "model_info": {
                "id": "missing-input",
                "input_cost_per_token": null,
                "output_cost_per_token": 0,
                "cache_read_input_token_cost": null
              }
            }
          ]
        }
        """.utf8)

        let snapshot = try JSONModelCatalogDecoder.decode(data: data, providerID: "provider")
        let free = try XCTUnwrap(snapshot.entries.first { $0.modelName == "free-cache-model" })
        let missingInput = try XCTUnwrap(snapshot.entries.first { $0.modelName == "missing-input-model" })
        XCTAssertEqual(free.pricing.cacheCreationInputTokenCost, 0)
        XCTAssertEqual(free.pricing.cacheReadInputTokenCost, 0)
        XCTAssertEqual(free.pricingSchedule?.base.cacheCreation, 0)
        XCTAssertEqual(free.pricingSchedule?.base.cacheRead, 0)
        XCTAssertNil(missingInput.pricing.inputCostPerToken)

        let freeResult = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [free])
        ).resolve(
            modelName: "free-cache-model",
            tokens: TokenTotals(inputTokens: 100, outputTokens: 20, cacheReadTokens: 1_000),
            backendCost: nil
        )
        XCTAssertTrue(freeResult.hasKnownPricing)
        XCTAssertEqual(freeResult.outcome, .knownFree)
        XCTAssertEqual(freeResult.cost, 0)

        let missingInputResult = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [missingInput])
        ).resolve(
            modelName: "missing-input-model",
            tokens: TokenTotals(inputTokens: 100, outputTokens: 20),
            backendCost: nil
        )
        XCTAssertFalse(missingInputResult.hasKnownPricing)
        XCTAssertEqual(missingInputResult.source, .unknown)
        XCTAssertEqual(missingInputResult.outcome, .intentionalUnknown)
    }

    func testModelCatalogIdentityIncludesModeForSameRouteVariants() throws {
        let data = Data("""
        {
          "data": [
            {
              "model_name": "gemini-3-pro-image",
              "litellm_params": {"model": "gemini-3-pro-image"},
              "model_info": {"id": "shared-id", "mode": "image_edit"}
            },
            {
              "model_name": "gemini-3-pro-image",
              "litellm_params": {"model": "gemini-3-pro-image"},
              "model_info": {"id": "shared-id", "mode": "image_generation"}
            }
          ]
        }
        """.utf8)

        let snapshot = try JSONModelCatalogDecoder.decode(
            data: data,
            providerID: "provider"
        )

        XCTAssertEqual(snapshot.identitySchemaVersion, ModelCatalogSnapshot.currentIdentitySchemaVersion)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(Set(snapshot.entries.compactMap(\.mode)), ["image_edit", "image_generation"])
        XCTAssertEqual(Set(snapshot.entries.compactMap(\.recordIdentity)), ["shared-id"])
        XCTAssertEqual(snapshot.entries.map(\.id).count, Set(snapshot.entries.map(\.id)).count)
    }

    func testModelCatalogRevisionIsStableAcrossResponseOrdering() throws {
        let first = try JSONModelCatalogDecoder.decode(
            data: sampleLikeCatalogData(),
            providerID: "provider",
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let reordered = try JSONModelCatalogDecoder.decode(
            data: reorderedCatalogData(),
            providerID: "provider",
            fetchedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(first.entries, reordered.entries)
        let left = first.encodedRevisionData()
        let right = reordered.encodedRevisionData()
        if left != right {
            let mismatch = zip(left, right)
                .enumerated()
                .first(where: { $0.element.0 != $0.element.1 })?.offset
            let mismatchText = mismatch.map(String.init) ?? "length"
            XCTFail("encoded revision data differs at \(mismatchText)")
        }
        XCTAssertEqual(first.revision, reordered.revision)
        XCTAssertEqual(first.entries.map(\.id), reordered.entries.map(\.id))
    }

    func testEntryProjectionRevisionChangesWhenSemanticRevisionDoesNot() throws {
        let firstEntry = makeEntry(id: "record-a", modelName: "same-model")
        let replacementEntry = makeEntry(id: "record-b", modelName: "same-model")
        let first = makeSnapshot([firstEntry], date: Date(timeIntervalSince1970: 1))
        let replacement = makeSnapshot([replacementEntry], date: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(first.revision, replacement.revision)

        var store = ModelCatalogStore(fileURL: temporaryURL("ModelCatalog.json"))
        XCTAssertTrue(try store.applySuccess(first, at: first.fetchedAt).isEmpty)
        let firstProjectionRevision = store.entryProjectionRevision(for: ["provider"])

        XCTAssertTrue(try store.applySuccess(replacement, at: replacement.fetchedAt).isEmpty)
        let replacementProjectionRevision = store.entryProjectionRevision(for: ["provider"])
        XCTAssertNotEqual(firstProjectionRevision, replacementProjectionRevision)
    }

    func testEntryProjectionRevisionChangesForRawDisplayNameWithSameSemanticIdentity() throws {
        let firstEntry = makeEntry(id: "record", modelName: "Same Model")
        let replacementEntry = makeEntry(id: "record", modelName: "  same model  ")
        let first = makeSnapshot([firstEntry], date: Date(timeIntervalSince1970: 1))
        let replacement = makeSnapshot([replacementEntry], date: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(first.revision, replacement.revision)
        XCTAssertEqual(first.entries.map(\.id), replacement.entries.map(\.id))

        var store = ModelCatalogStore(fileURL: temporaryURL("ModelCatalog.json"))
        XCTAssertTrue(try store.applySuccess(first, at: first.fetchedAt).isEmpty)
        let firstProjectionRevision = store.entryProjectionRevision(for: ["provider"])

        XCTAssertTrue(try store.applySuccess(replacement, at: replacement.fetchedAt).isEmpty)
        let replacementProjectionRevision = store.entryProjectionRevision(for: ["provider"])
        XCTAssertNotEqual(firstProjectionRevision, replacementProjectionRevision)
    }

    func testModelCatalogDecoderRejectsMalformedEmptyOversizedAndInvalidPriceResponses() throws {
        assertDecodeError(Data("[]".utf8), .invalidEnvelope)
        assertDecodeError(Data(#"{"data":[]}"#.utf8), .emptyCatalog)
        assertDecodeError(
            Data(#"{"data":[{"model_name":"missing-id","model_info":{}}]}"#.utf8),
            .invalidRecord(0, "model_info.id is missing")
        )
        assertDecodeError(
            Data(#"{"data":[{"model_name":"bad-price","model_info":{"id":"bad","input_cost_per_token":-1}}]}"#.utf8),
            .invalidPrice(0, "input_cost_per_token")
        )

        let record = #"{"model_name":"model","model_info":{"id":"id"}}"#
        let oversizedText = "{\"data\":[" + Array(repeating: record, count: JSONModelCatalogDecoder.maximumRecords + 1).joined(separator: ",") + "]}"
        let oversized = Data(oversizedText.utf8)
        assertDecodeError(oversized, .tooManyRecords)
    }

    func testModelCatalogDecoderBoundsUntrustedDisplayTextAndRoutes() throws {
        let longDescription = String(
            repeating: "x",
            count: JSONModelCatalogDecoder.maximumMetadataStringUTF8Length + 1
        )
        let longDescriptionResponse = JSONValue.object([
            "data": .array([
                .object([
                    "model_name": .string("model"),
                    "model_info": .object([
                        "id": .string("id"),
                        "page_display_data": .object([
                            "description": .string(longDescription)
                        ])
                    ])
                ])
            ])
        ])
        assertDecodeError(
            try! JSONEncoder().encode(longDescriptionResponse),
            .invalidRecord(0, "model_info.page_display_data.description is too long")
        )

        let longRoute = String(
            repeating: "r",
            count: JSONModelCatalogDecoder.maximumRouteUTF8Length + 1
        )
        let longRouteResponse = JSONValue.object([
            "data": .array([
                .object([
                    "model_name": .string("model"),
                    "litellm_params": .object(["model": .string(longRoute)]),
                    "model_info": .object(["id": .string("id")])
                ])
            ])
        ])
        assertDecodeError(
            try! JSONEncoder().encode(longRouteResponse),
            .invalidRecord(0, "litellm_params.model is too long")
        )
    }

    func testModelCatalogProviderEnforcesResponseSizeBeforeDecoding() async throws {
        let manifest = try loadManifest()
        let provider = try HTTPJSONModelCatalogPluginProvider(
            manifest: manifest,
            configurationData: configurationData(
                endpoint: "https://api.example.test/model-info",
                apiKey: "unit-test-api-key"
            ),
            maximumResponseBytes: 16,
            send: { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (self.sampleLikeCatalogData(), response)
            }
        )

        do {
            _ = try await provider.fetchModelCatalog()
            XCTFail("Expected response size enforcement")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .responseTooLarge)
        }
    }

    func testModelCatalogSnapshotEstablishesBaselineAndPersistsTrustedState() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = makeSnapshot([makeEntry(id: "model-1", modelName: "model-1")], date: date)

        var store = ModelCatalogStore(fileURL: url)
        XCTAssertEqual(try store.applySuccess(snapshot, at: date), [])
        XCTAssertEqual(store.status.phase, .ready)
        XCTAssertEqual(store.status.recordCount, 1)
        XCTAssertEqual(store.providers["provider"]?.baselineRevision, snapshot.revision)
        try store.save()

        let reloaded = ModelCatalogStore(fileURL: url)
        XCTAssertEqual(reloaded.entries, snapshot.entries)
        XCTAssertEqual(reloaded.providers["provider"]?.trustedSnapshot?.revision, snapshot.revision)
        XCTAssertEqual(reloaded.status.lastSuccessAt, date)
    }

    func testModelCatalogIdentitySchemaMigrationResetsBaselineWithoutNotifications() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldDate = Date(timeIntervalSince1970: 150)
        let old = makeSnapshot(
            [makeEntry(id: "legacy-id", modelName: "model")],
            date: oldDate,
            identitySchemaVersion: ModelCatalogSnapshot.legacyIdentitySchemaVersion
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "identitySchemaVersion")
        let decodedLegacy = try JSONDecoder().decode(
            ModelCatalogSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertEqual(
            decodedLegacy.identitySchemaVersion,
            ModelCatalogSnapshot.legacyIdentitySchemaVersion
        )
        var store = ModelCatalogStore(fileURL: url)
        XCTAssertTrue(try store.applySuccess(old, at: oldDate).isEmpty)
        try store.save()

        var reloaded = ModelCatalogStore(fileURL: url)
        let migratedDate = Date(timeIntervalSince1970: 151)
        let migrated = makeSnapshot(
            [makeEntry(id: "new-id", modelName: "model")],
            date: migratedDate
        )

        XCTAssertTrue(try reloaded.applySuccess(migrated, at: migratedDate).isEmpty)
        XCTAssertEqual(
            reloaded.providers["provider"]?.trustedSnapshot?.identitySchemaVersion,
            ModelCatalogSnapshot.currentIdentitySchemaVersion
        )
        XCTAssertEqual(reloaded.providers["provider"]?.baselineRevision, migrated.revision)
        XCTAssertEqual(reloaded.entries, migrated.entries)
    }

    func testModelCatalogPricingSchemaMigrationResetsBaselineWithoutFalsePriceNotifications() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldDate = Date(timeIntervalSince1970: 160)
        let old = makeSnapshot(
            [makeEntry(id: "model", modelName: "model", input: 0.000001)],
            date: oldDate,
            pricingSchemaVersion: ModelCatalogSnapshot.legacyPricingSchemaVersion
        )
        var store = ModelCatalogStore(fileURL: url)
        XCTAssertTrue(try store.applySuccess(old, at: oldDate).isEmpty)
        try store.save()

        let migratedDate = Date(timeIntervalSince1970: 161)
        let migrated = makeSnapshot(
            [makeEntry(id: "model", modelName: "model", input: 0.000003)],
            date: migratedDate
        )
        let reloaded = ModelCatalogStore(fileURL: url)

        var updated = reloaded
        XCTAssertTrue(try updated.applySuccess(migrated, at: migratedDate).isEmpty)
        XCTAssertEqual(
            updated.providers["provider"]?.trustedSnapshot?.pricingSchemaVersion,
            ModelCatalogSnapshot.currentPricingSchemaVersion
        )
        XCTAssertEqual(updated.providers["provider"]?.baselineRevision, migrated.revision)
    }

    func testModelCatalogFailureKeepsTrustedSnapshotAndMarksItStale() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = ModelCatalogStore(fileURL: url)
        let date = Date(timeIntervalSince1970: 200)
        let snapshot = makeSnapshot([makeEntry(id: "model-1", modelName: "model-1")], date: date)
        _ = try store.applySuccess(snapshot, at: date)

        store.applyFailure(providerID: "provider", error: TestError.failed, at: date.addingTimeInterval(10))

        XCTAssertEqual(store.entries, snapshot.entries)
        XCTAssertEqual(store.status.phase, .stale)
        XCTAssertTrue(store.status.lastError?.contains("test failure") == true)
        XCTAssertEqual(store.providers["provider"]?.trustedSnapshot?.revision, snapshot.revision)
    }

    func testModelCatalogStoreProjectsOnlyActiveProviders() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var store = ModelCatalogStore(fileURL: url)
        let active = ModelCatalogSnapshot(
            providerID: "active-provider",
            fetchedAt: Date(timeIntervalSince1970: 250),
            entries: [makeEntry(id: "active-model", modelName: "active-model", providerID: "active-provider")]
        )
        let inactive = ModelCatalogSnapshot(
            providerID: "inactive-provider",
            fetchedAt: Date(timeIntervalSince1970: 250),
            entries: [makeEntry(id: "inactive-model", modelName: "inactive-model", providerID: "inactive-provider")]
        )
        _ = try store.applySuccess(active, at: active.fetchedAt)
        _ = try store.applySuccess(inactive, at: inactive.fetchedAt)

        let activeIDs = Set(["active-provider"])
        XCTAssertEqual(store.entries(for: activeIDs).map(\.modelName), ["active-model"])
        XCTAssertEqual(store.status(for: activeIDs).recordCount, 1)
        XCTAssertNotNil(store.revision(for: activeIDs))
        XCTAssertEqual(store.status(for: Set(["missing-provider"])), .empty)
    }

    func testModelCatalogStoreProjectsExactRemoteDuplicatesButRetainsRawSnapshot() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = makeEntry(
            id: "record-a",
            modelName: "gpt-5.6-sol-aws",
            input: 0.0000055,
            output: 0.000033,
            providerID: "example-gateway",
            route: "openai/openai.gpt-5.6-sol",
            version: "openai.gpt-5.6-sol"
        )
        let duplicate = makeEntry(
            id: "record-b",
            modelName: "gpt-5.6-sol-aws",
            input: 0.0000055,
            output: 0.000033,
            providerID: "example-gateway",
            route: "openai/openai.gpt-5.6-sol",
            version: "openai.gpt-5.6-sol"
        )
        let snapshot = makeSnapshot([first, duplicate], date: Date(timeIntervalSince1970: 225))

        var store = ModelCatalogStore(fileURL: url)
        _ = try store.applySuccess(snapshot, at: snapshot.fetchedAt)

        XCTAssertEqual(store.providers["provider"]?.trustedSnapshot?.entries.count, 2)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.status.recordCount, 1)
    }

    func testModelCatalogRejectsSuspiciousMassCollapseWithoutChangingTrustedState() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = ModelCatalogStore(fileURL: url)
        let original = makeSnapshot(
            (0..<20).map { makeEntry(id: "model-\($0)", modelName: "model-\($0)") },
            date: Date(timeIntervalSince1970: 300)
        )
        _ = try store.applySuccess(original, at: original.fetchedAt)
        let partial = makeSnapshot(
            (0..<9).map { makeEntry(id: "model-\($0)", modelName: "model-\($0)") },
            date: Date(timeIntervalSince1970: 301)
        )

        XCTAssertThrowsError(try store.applySuccess(partial, at: partial.fetchedAt)) { error in
            XCTAssertEqual(error as? ModelCatalogStoreError, .suspiciousResponse)
        }
        XCTAssertEqual(store.entries.count, 20)
        XCTAssertEqual(store.providers["provider"]?.trustedSnapshot?.revision, original.revision)
    }

    func testModelCatalogDiffReportsAddedRemovedEnabledDisabledAndPricingChanges() {
        let old = makeSnapshot([
            makeEntry(id: "same", modelName: "same", enabled: true, input: 0.000001),
            makeEntry(id: "removed", modelName: "removed")
        ], date: Date(timeIntervalSince1970: 400))
        let new = makeSnapshot([
            makeEntry(id: "same", modelName: "same", enabled: false, input: 0.000002),
            makeEntry(id: "added", modelName: "added")
        ], date: Date(timeIntervalSince1970: 401))

        let kinds = ModelCatalogDiff.events(from: old, to: new, at: new.fetchedAt)
            .map(\.kind.rawValue)
            .sorted()
        XCTAssertEqual(
            kinds,
            [
                "model-catalog.model-added",
                "model-catalog.model-disabled",
                "model-catalog.model-removed",
                "model-catalog.pricing-changed"
            ]
        )
    }

    func testModelCatalogDiffIgnoresRemoteFreeCacheNilToZeroRepresentationChanges() {
        let oldSchedule = CanonicalModelPricing(
            modelName: "same",
            base: PricingRates(input: 0.000001, output: 0.000002, cacheCreation: nil, cacheRead: nil),
            tiers: [],
            maxInputTokens: nil,
            fastMultiplier: nil
        )
        let newSchedule = CanonicalModelPricing(
            modelName: "same",
            base: PricingRates(input: 0.000001, output: 0.000002, cacheCreation: 0, cacheRead: 0),
            tiers: [],
            maxInputTokens: nil,
            fastMultiplier: nil
        )
        let old = makeSnapshot([
            makeEntry(id: "same", modelName: "same", schedule: oldSchedule)
        ], date: Date(timeIntervalSince1970: 450))
        let new = makeSnapshot([
            makeEntry(id: "same", modelName: "same", schedule: newSchedule)
        ], date: Date(timeIntervalSince1970: 451))

        XCTAssertTrue(ModelCatalogDiff.events(from: old, to: new, at: new.fetchedAt).isEmpty)
    }

    func testModelCatalogDiffDeduplicatesDuplicateEntryIDs() {
        let duplicate = makeEntry(id: "duplicate", modelName: "duplicate")
        let snapshot = makeSnapshot([duplicate, duplicate], date: Date(timeIntervalSince1970: 475))

        XCTAssertEqual(
            ModelCatalogDiff.events(from: nil, to: snapshot, at: snapshot.fetchedAt).map(\.kind.rawValue),
            ["model-catalog.model-added"]
        )
        XCTAssertEqual(
            ModelCatalogDiff.events(
                from: snapshot,
                to: makeSnapshot([], date: Date(timeIntervalSince1970: 476)),
                at: Date(timeIntervalSince1970: 476)
            ).map(\.kind.rawValue),
            ["model-catalog.model-removed"]
        )
    }

    func testModelCatalogDiffBoundsLargeProviderBatchWithSummaryEvent() {
        let snapshot = makeSnapshot(
            (0..<30).map { makeEntry(id: "model-\($0)", modelName: "model-\($0)") },
            date: Date(timeIntervalSince1970: 480)
        )
        let events = ModelCatalogDiff.events(from: nil, to: snapshot, at: snapshot.fetchedAt)

        let bounded = ModelCatalogDiff.boundedNotificationBatch(events, at: snapshot.fetchedAt)

        XCTAssertEqual(bounded.count, ModelCatalogDiff.maximumDetailedNotificationEvents + 1)
        XCTAssertEqual(
            bounded.dropLast().filter { $0.type == .modelAdded }.count,
            ModelCatalogDiff.maximumDetailedNotificationEvents
        )
        XCTAssertEqual(bounded.last?.type, .catalogUpdated)
        XCTAssertEqual(bounded.last?.sourceID, "provider")
        XCTAssertTrue(bounded.last?.body.contains("additional catalog changes") == true)
    }

    func testModelCatalogPrepareBatchComputesProjectionStatusAndEncodedData() throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let providerID = "provider"
        let startedAt = Date(timeIntervalSince1970: 490)
        let completedAt = Date(timeIntervalSince1970: 491)
        let snapshot = makeSnapshot(
            [makeEntry(id: "prepared", modelName: "prepared")],
            date: completedAt
        )
        let base = ModelCatalogStore(fileURL: url)

        let prepared = try ModelCatalogStore.prepareBatch(
            from: base,
            providerIDs: [providerID],
            activeProviderIDs: Set([providerID]),
            outcomes: [.success(snapshot)],
            startedAt: startedAt,
            completedAt: completedAt
        )

        XCTAssertEqual(prepared.entries.map(\.modelName), ["prepared"])
        XCTAssertEqual(prepared.status.phase, .ready)
        XCTAssertEqual(prepared.status.recordCount, 1)
        XCTAssertEqual(prepared.store.lastAttemptAt(for: Set([providerID])), completedAt)
        XCTAssertTrue(prepared.events.isEmpty, "the first trusted snapshot establishes the notification baseline")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: prepared.encodedData))
    }

    func testModelCatalogPersistenceRejectsLateGenerationWrite() async throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persistence = ModelCatalogPersistence()

        try await persistence.save(Data("new".utf8), to: url, generation: 2)
        try await persistence.save(Data("old".utf8), to: url, generation: 1)

        XCTAssertEqual(try String(contentsOf: url), "new")
    }

    func testModelCatalogPersistenceRejectsInvalidatedGenerationBeforeWrite() async throws {
        let url = temporaryURL("ModelCatalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fence = ModelCatalogGenerationFence()
        let persistence = ModelCatalogPersistence(fence: fence)

        fence.invalidate(upTo: 2)
        try await persistence.save(Data("old".utf8), to: url, generation: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testModelCatalogBaselineSuppressesInitialNotifications() throws {
        var store = ModelCatalogStore(fileURL: temporaryURL("ModelCatalog.json"))
        let first = makeSnapshot([makeEntry(id: "model", modelName: "model")], date: Date(timeIntervalSince1970: 500))
        let second = makeSnapshot([makeEntry(id: "model", modelName: "model"), makeEntry(id: "new", modelName: "new")], date: Date(timeIntervalSince1970: 501))

        XCTAssertTrue(try store.applySuccess(first, at: first.fetchedAt).isEmpty)
        XCTAssertEqual(try store.applySuccess(second, at: second.fetchedAt).count, 1)
    }

    func testNotificationFeedPersistsReadDismissedAndDeduplicatesEvents() throws {
        let url = temporaryURL("NotificationFeed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let event = NotificationFeedEvent(
            id: "event-1",
            source: "provider",
            kind: .modelAdded,
            title: "Model added",
            body: "new-model",
            createdAt: Date(timeIntervalSince1970: 600),
            isRead: false,
            isDismissed: false
        )

        var feed = NotificationFeedStore(fileURL: url)
        feed.append([event, event])
        XCTAssertEqual(feed.events.count, 1)
        XCTAssertEqual(feed.unreadCount, 1)
        feed.markRead(event.id)
        XCTAssertEqual(feed.unreadCount, 0)

        let read = NotificationFeedStore(fileURL: url)
        XCTAssertEqual(read.events, [NotificationFeedEvent(
            id: event.id,
            source: event.source,
            kind: event.kind,
            title: event.title,
            body: event.body,
            createdAt: event.createdAt,
            isRead: true,
            isDismissed: false
        )])

        var dismissed = read
        dismissed.dismiss(event.id)
        XCTAssertTrue(dismissed.visibleEvents.isEmpty)
        XCTAssertTrue(NotificationFeedStore(fileURL: url).visibleEvents.isEmpty)
    }

    func testNotificationFeedDropsUnboundedEventText() {
        let event = NotificationFeedEvent(
            id: "event-1",
            source: "provider",
            kind: .modelAdded,
            title: "Model added",
            body: String(repeating: "x", count: NotificationFeedStore.maximumBodyUTF8Length + 1),
            createdAt: Date(timeIntervalSince1970: 650),
            isRead: false,
            isDismissed: false
        )

        var feed = NotificationFeedStore(fileURL: temporaryURL("NotificationFeed.json"))
        feed.append([event])

        XCTAssertTrue(feed.events.isEmpty)
    }

    func testCustomRemoteAndDefaultRecordsRemainSearchableAsAUnion() {
        let custom = CustomPricingTable(entries: [
            "shared-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ]).modelCatalogEntries
        let remote = makeEntry(
            id: "remote-record",
            modelName: "shared-model",
            input: 0.000003,
            providerID: "remote-provider"
        )
        let union = custom + [remote]

        XCTAssertEqual(union.count, 2)
        XCTAssertEqual(union.map(\.source), [.custom, .remote])
        XCTAssertEqual(
            ModelCatalogFilter.filter(
                union,
                query: "remote-provider",
                provider: "",
                modality: "",
                capability: .any,
                priceRange: .any,
                contextRange: .any
            ).map(\.id),
            ["remote-record"]
        )
    }

    func testModelCatalogFilterCacheRecomputesForQueryAndProjectionRevision() {
        let cache = ModelCatalogFilterCache()
        let revision = ModelCatalogProjectionRevision(
            customPricingRevision: "custom-1",
            modelCatalogRevision: "remote-1",
            modelCatalogEntryProjectionRevision: "entries-1"
        )
        let entries = [
            makeEntry(id: "alpha", modelName: "alpha-model"),
            makeEntry(id: "beta", modelName: "beta-model")
        ]

        XCTAssertEqual(
            cache.filteredEntries(
                entries,
                projectionRevision: revision,
                query: "alpha",
                provider: "",
                modality: "",
                capability: .any,
                priceRange: .any,
                contextRange: .any
            ).map(\.id),
            ["alpha"]
        )
        XCTAssertEqual(
            cache.filteredEntries(
                entries,
                projectionRevision: revision,
                query: "beta",
                provider: "",
                modality: "",
                capability: .any,
                priceRange: .any,
                contextRange: .any
            ).map(\.id),
            ["beta"]
        )

        let replacement = [makeEntry(id: "alpha", modelName: "  alpha-model  ")]
        let replacementRevision = ModelCatalogProjectionRevision(
            customPricingRevision: "custom-1",
            modelCatalogRevision: "remote-1",
            modelCatalogEntryProjectionRevision: "entries-2"
        )
        XCTAssertEqual(
            cache.filteredEntries(
                replacement,
                projectionRevision: replacementRevision,
                query: "alpha",
                provider: "",
                modality: "",
                capability: .any,
                priceRange: .any,
                contextRange: .any
            ).map(\.modelName),
            ["  alpha-model  "]
        )
    }

    func testPricingUsesCustomThenRemoteThenCcusageWithoutFieldMixing() {
        let remote = makeEntry(
            id: "remote-model",
            modelName: "remote-model",
            input: 0.000001,
            output: 0.000002
        )
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        let custom = CustomPricingTable(entries: [
            "remote-model": CustomModelPricing(
                inputCostPerToken: 0.000003,
                outputCostPerToken: 0.000004,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let customResult = PricingResolver(
            context: PricingResolutionContext(table: custom, remoteCatalogEntries: [remote])
        ).resolve(modelName: "remote-model", tokens: tokens, backendCost: nil)
        XCTAssertEqual(customResult.source, .custom)
        XCTAssertEqual(customResult.cost, 0.007, accuracy: 0.0000001)

        let remoteResult = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [remote])
        ).resolve(modelName: "remote-model", tokens: tokens, backendCost: 99)
        XCTAssertEqual(remoteResult.source, .remote)
        XCTAssertEqual(remoteResult.cost, 99, accuracy: 0.0000001)

        let defaultResult = PricingResolver(context: .empty)
            .resolve(modelName: "unknown-model", tokens: tokens, backendCost: 7)
        XCTAssertEqual(defaultResult.source, .ccusage)
        XCTAssertEqual(defaultResult.cost, 7)
    }

    func testFreshRemoteCatalogFallsBackToCcusageForMissingOrDisabledModels() {
        let cases: [(String, PricingResolutionContext)] = [
            (
                "not-in-example-gateway-catalog",
                PricingResolutionContext(
                    table: .empty,
                    remoteCatalogRevision: "revision-1"
                )
            ),
            (
                "disabled-model",
                PricingResolutionContext(
                    table: .empty,
                    remoteCatalogEntries: [makeEntry(
                        id: "disabled-model",
                        modelName: "disabled-model",
                        enabled: false
                    )],
                    remoteCatalogRevision: "revision-1"
                )
            )
        ]

        for (modelName, context) in cases {
            let result = PricingResolver(context: context).resolve(
                modelName: modelName,
                tokens: TokenTotals(inputTokens: 1_000, outputTokens: 1_000),
                backendCost: 99
            )

            XCTAssertTrue(result.hasKnownPricing)
            XCTAssertEqual(result.source, .ccusage)
            XCTAssertEqual(result.outcome, .knownPaid)
            XCTAssertEqual(result.cost, 99)
        }
    }

    func testIncompleteCustomPricingDoesNotFallThroughToRemote() {
        let custom = CustomPricingTable(entries: [
            "shared-model": CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: nil,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let remote = makeEntry(
            id: "remote-shared",
            modelName: "shared-model",
            input: 0.000003,
            output: 0.000004
        )

        let result = PricingResolver(
            context: PricingResolutionContext(table: custom, remoteCatalogEntries: [remote])
        ).resolve(
            modelName: "shared-model",
            tokens: TokenTotals(inputTokens: 1_000, outputTokens: 1_000),
            backendCost: 99
        )

        XCTAssertFalse(result.hasKnownPricing)
        XCTAssertEqual(result.source, .unknown)
        XCTAssertEqual(result.outcome, .intentionalUnknown)
    }

    func testAmbiguousRemoteSchedulesAreUnknownButEquivalentSchedulesAreUsable() {
        let first = makeEntry(id: "remote-a", modelName: "ambiguous", input: 0.000001, output: 0.000002)
        let second = makeEntry(id: "remote-b", modelName: "ambiguous", input: 0.000003, output: 0.000004)
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        let ambiguous = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [first, second])
        ).resolve(modelName: "ambiguous", tokens: tokens, backendCost: 99)
        XCTAssertFalse(ambiguous.hasKnownPricing)
        XCTAssertEqual(ambiguous.source, .unknown)
        XCTAssertEqual(ambiguous.outcome, .intentionalUnknown)

        let equivalent = makeEntry(
            id: "remote-b",
            modelName: "alias-display-name",
            input: 0.000001,
            output: 0.000002,
            route: "ambiguous"
        )
        let usable = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [first, equivalent])
        ).resolve(modelName: "ambiguous", tokens: tokens, backendCost: 99)
        XCTAssertTrue(usable.hasKnownPricing)
        XCTAssertEqual(usable.source, .remote)
        XCTAssertEqual(usable.cost, 99, accuracy: 0.0000001)
    }

    func testRemotePricingUsesBackendCostAndRetainsFreeSchedules() {
        let free = makeEntry(
            id: "free",
            modelName: "free-remote",
            input: 0,
            output: 0
        )
        let tiered = makeEntry(
            id: "tiered",
            modelName: "tiered-remote",
            input: 0.000001,
            output: 0.000002,
            schedule: CanonicalModelPricing(
                modelName: "tiered-remote",
                base: PricingRates(input: 0.000001, output: 0.000002, cacheCreation: nil, cacheRead: nil),
                tiers: [PricingTier(
                    threshold: 100,
                    rates: PricingRates(input: 0.000003, output: 0.000004, cacheCreation: nil, cacheRead: nil)
                )],
                maxInputTokens: nil,
                fastMultiplier: nil
            )
        )

        let resolver = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [free, tiered])
        )
        let freeResult = resolver.resolve(
            modelName: "free-remote",
            tokens: TokenTotals(inputTokens: 1_000, outputTokens: 1_000),
            backendCost: 99
        )
        XCTAssertTrue(freeResult.hasKnownPricing)
        XCTAssertEqual(freeResult.source, .remote)
        XCTAssertEqual(freeResult.outcome, .knownFree)
        XCTAssertEqual(freeResult.cost, 0)

        let tieredResult = resolver.resolve(
            modelName: "tiered-remote",
            tokens: TokenTotals(inputTokens: 200, outputTokens: 10),
            backendCost: 0.123456
        )
        XCTAssertTrue(tieredResult.hasKnownPricing)
        XCTAssertEqual(tieredResult.source, .remote)
        XCTAssertEqual(tieredResult.tierThreshold, 100)
        XCTAssertEqual(tieredResult.cost, 0.123456, accuracy: 0.0000001)
    }

    func testRemoteZeroBackendCostIsUnknownForPaidSchedule() {
        let remote = makeEntry(
            id: "paid-remote",
            modelName: "paid-remote",
            input: 0.000001,
            output: 0.000002
        )

        let result = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [remote])
        ).resolve(
            modelName: "paid-remote",
            tokens: TokenTotals(inputTokens: 1_000, outputTokens: 1_000),
            backendCost: 0
        )

        XCTAssertFalse(result.hasKnownPricing)
        XCTAssertEqual(result.source, .unknown)
        XCTAssertEqual(result.outcome, .intentionalUnknown)
        XCTAssertEqual(result.cost, 0)
    }

    func testRemoteNullCacheBackendZeroIsKnownFreeWhenOtherRatesAreUnused() {
        let remote = makeEntry(
            id: "cache-free-remote",
            modelName: "cache-free-remote",
            input: 0.000001,
            output: 0.000002
        )

        let result = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [remote])
        ).resolve(
            modelName: "cache-free-remote",
            tokens: TokenTotals(cacheReadTokens: 10_000),
            backendCost: 0
        )

        XCTAssertTrue(result.hasKnownPricing)
        XCTAssertEqual(result.source, .remote)
        XCTAssertEqual(result.outcome, .knownFree)
        XCTAssertEqual(result.cost, 0)
    }

    func testRemoteNullCacheRateMeansNoCharge() {
        let freeBase = makeEntry(
            id: "deepseek-free-base",
            modelName: "deepseek-v4-flash-0731-gmi-ray",
            input: 0,
            output: 0
        )

        let result = PricingResolver(
            context: PricingResolutionContext(
                table: .empty,
                remoteCatalogEntries: [freeBase],
                remoteCatalogRevision: "example-gateway-revision"
            )
            ).resolve(
            modelName: "deepseek-v4-flash-0731-gmi-ray",
            tokens: TokenTotals(inputTokens: 100, outputTokens: 20, cacheReadTokens: 1_000),
            backendCost: nil
        )

        XCTAssertTrue(result.hasKnownPricing)
        XCTAssertEqual(result.source, .remote)
        XCTAssertEqual(result.outcome, .knownFree)
        XCTAssertEqual(result.cost, 0)
    }

    func testRemoteTierUsesBackendCostInsteadOfRecomputingOmittedComponents() {
        let remote = makeEntry(
            id: "tier-inheritance",
            modelName: "tier-inheritance",
            input: 0.000001,
            output: 0.000002,
            schedule: CanonicalModelPricing(
                modelName: "tier-inheritance",
                base: PricingRates(input: 0.000001, output: 0.000002, cacheCreation: nil, cacheRead: nil),
                tiers: [PricingTier(
                    threshold: 100,
                    rates: PricingRates(input: 0.000003, output: nil, cacheCreation: nil, cacheRead: nil)
                )],
                maxInputTokens: nil,
                fastMultiplier: nil
            )
        )

        let result = PricingResolver(
            context: PricingResolutionContext(table: .empty, remoteCatalogEntries: [remote])
        ).resolve(
            modelName: "tier-inheritance",
            tokens: TokenTotals(inputTokens: 200, outputTokens: 10),
            backendCost: 0.123456
        )

        XCTAssertTrue(result.hasKnownPricing)
        XCTAssertEqual(result.source, .remote)
        XCTAssertEqual(result.tierThreshold, 100)
        XCTAssertEqual(result.cost, 0.123456, accuracy: 0.0000001)
    }

    func testUsageSnapshotRecordsRemotePricingSourceAndCatalogRevision() throws {
        let response = try JSONDecoder().decode(CCUsageResponse.self, from: Data("""
        {
          "daily": [{
            "agent": "all",
            "period": "2026-08-26",
            "agents": [{
              "agent": "codex",
              "modelBreakdowns": [{
                "modelName": "remote-model",
                "inputTokens": 1000,
                "outputTokens": 1000,
                "cost": 99
              }]
            }]
          }]
        }
        """.utf8))
        let result = UsageSnapshotBuilder.makeResult(
            from: response,
            pricingUpdatedAt: nil,
            pricingContext: PricingResolutionContext(
                table: .empty,
                remoteCatalogEntries: [
                    makeEntry(
                        id: "remote-model",
                        modelName: "remote-model",
                        input: 0.000001,
                        output: 0.000002
                    )
                ],
                remoteCatalogRevision: "revision-1"
            )
        )

        let model = try XCTUnwrap(result.snapshot.models.first)
        XCTAssertEqual(model.pricingSource, .remote)
        XCTAssertEqual(model.pricingProviderIDs, ["provider"])
        XCTAssertEqual(result.snapshot.dailyModels.first?.pricingProviderIDs, ["provider"])
        XCTAssertEqual(model.estimatedCost, 99, accuracy: 0.0000001)
        XCTAssertEqual(result.snapshot.pricingSource, .remote)
        XCTAssertEqual(result.snapshot.modelCatalogRevision, "revision-1")
    }

    func testEquivalentRemoteProvidersRemainVisibleInPricingProvenance() {
        let first = makeEntry(
            id: "provider-a-model",
            modelName: "shared-model",
            input: 0.000001,
            output: 0.000002,
            providerID: "provider-a"
        )
        let second = makeEntry(
            id: "provider-b-model",
            modelName: "shared-model-alias",
            input: 0.000001,
            output: 0.000002,
            providerID: "provider-b",
            route: "shared-model"
        )

        let result = PricingResolver(
            context: PricingResolutionContext(
                table: .empty,
                remoteCatalogEntries: [first, second]
            )
        ).resolve(
            modelName: "shared-model",
            tokens: TokenTotals(inputTokens: 1_000, outputTokens: 1_000),
            backendCost: 99
        )

        XCTAssertTrue(result.hasKnownPricing)
        XCTAssertEqual(result.source, ModelPricingSource.remote)
        XCTAssertEqual(result.pricingProviderIDs, ["provider-a", "provider-b"])
    }

    func testCCSwitchRouteAliasesPreferExactModelAndDeduplicateSamePriceRecords() {
        let awsFirst = makeEntry(
            id: "aws-record-a",
            modelName: "gpt-5.6-sol-aws",
            input: 0.0000055,
            output: 0.000033,
            providerID: "example-gateway",
            route: "openai/openai.gpt-5.6-sol",
            version: "openai.gpt-5.6-sol",
            provider: "openai"
        )
        let awsDuplicate = makeEntry(
            id: "aws-record-b",
            modelName: "gpt-5.6-sol-aws",
            input: 0.0000055,
            output: 0.000033,
            providerID: "example-gateway",
            route: "openai/openai.gpt-5.6-sol",
            version: "openai.gpt-5.6-sol",
            provider: "openai"
        )
        let azure = makeEntry(
            id: "azure-record",
            modelName: "gpt-5.6-sol",
            input: 0.000005,
            output: 0.00003,
            providerID: "example-gateway",
            route: "azure/gpt-5.6-sol",
            version: "2026-07-09",
            baseModel: "azure/gpt-5.6-sol",
            provider: "azure"
        )

        XCTAssertEqual(ModelCatalogEntry.deduplicated([awsFirst, awsDuplicate]).count, 1)

        let context = PricingResolutionContext(
            table: .empty,
            remoteCatalogEntries: [awsFirst, awsDuplicate, azure]
        )
        let resolver = PricingResolver(context: context)
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        let awsRoute = resolver.resolve(
            modelName: "openai.gpt-5.6-sol",
            tokens: tokens,
            backendCost: 99
        )
        XCTAssertTrue(awsRoute.hasKnownPricing)
        XCTAssertEqual(awsRoute.source, .remote)
        XCTAssertEqual(awsRoute.pricingProviderIDs, ["example-gateway"])
        XCTAssertEqual(awsRoute.cost, 99)

        let azureDisplay = resolver.resolve(
            modelName: "gpt-5.6-sol",
            tokens: tokens,
            backendCost: 88
        )
        XCTAssertTrue(azureDisplay.hasKnownPricing)
        XCTAssertEqual(azureDisplay.source, .remote)
        XCTAssertEqual(azureDisplay.cost, 88)

        let awsDisplay = resolver.resolve(
            modelName: "gpt-5.6-sol-aws",
            tokens: tokens,
            backendCost: 77
        )
        XCTAssertTrue(awsDisplay.hasKnownPricing)
        XCTAssertEqual(awsDisplay.source, .remote)
        XCTAssertEqual(awsDisplay.cost, 77)
    }

    func testRecordIdentityDoesNotMergeDifferentModelRoutes() {
        let first = makeEntry(
            id: "shared-record-id",
            modelName: "model-a",
            input: 0.000001,
            output: 0.000002,
            route: "provider/model-a"
        )
        let second = makeEntry(
            id: "shared-record-id",
            modelName: "model-b",
            input: 0.000003,
            output: 0.000004,
            route: "provider/model-b"
        )
        let resolver = PricingResolver(context: PricingResolutionContext(
            table: .empty,
            remoteCatalogEntries: [first, second]
        ))
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        let firstResult = resolver.resolve(modelName: "model-a", tokens: tokens, backendCost: 11)
        let secondResult = resolver.resolve(modelName: "model-b", tokens: tokens, backendCost: 22)

        XCTAssertTrue(firstResult.hasKnownPricing)
        XCTAssertEqual(firstResult.cost, 11)
        XCTAssertTrue(secondResult.hasKnownPricing)
        XCTAssertEqual(secondResult.cost, 22)
    }

    func testKnownAgentDisplayWrapperIsAcceptedButProviderPrefixIsNotStripped() {
        let entry = makeEntry(
            id: "pi-model",
            modelName: "glm-5.2",
            input: 0.000001,
            output: 0.000002,
            route: "glm-5.2"
        )
        let resolver = PricingResolver(context: PricingResolutionContext(
            table: .empty,
            remoteCatalogEntries: [entry]
        ))
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        let wrapped = resolver.resolve(modelName: "[pi] glm-5.2", tokens: tokens, backendCost: 7)
        XCTAssertTrue(wrapped.hasKnownPricing)
        XCTAssertEqual(wrapped.source, .remote)

        let unrelatedRoute = resolver.resolve(
            modelName: "openai.glm-5.2",
            tokens: tokens,
            backendCost: 9
        )
        XCTAssertTrue(unrelatedRoute.hasKnownPricing)
        XCTAssertEqual(unrelatedRoute.source, .ccusage)
        XCTAssertEqual(unrelatedRoute.cost, 9)
    }

    func testReleaseDateVersionsDoNotMergeDifferentModels() {
        let first = makeEntry(
            id: "date-a",
            modelName: "date-model-a",
            input: 0.000001,
            output: 0.000002,
            route: "provider/date-a",
            version: "2026-07-09"
        )
        let second = makeEntry(
            id: "date-b",
            modelName: "date-model-b",
            input: 0.000003,
            output: 0.000004,
            route: "provider/date-b",
            version: "2026-07-09"
        )
        let resolver = PricingResolver(context: PricingResolutionContext(
            table: .empty,
            remoteCatalogEntries: [first, second]
        ))
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 1_000)

        XCTAssertTrue(resolver.resolve(modelName: "date-model-a", tokens: tokens, backendCost: 1).hasKnownPricing)
        XCTAssertTrue(resolver.resolve(modelName: "date-model-b", tokens: tokens, backendCost: 2).hasKnownPricing)
    }

    func testBuiltInModelCatalogProviderWinsDuplicateExternalProviderID() {
        let base = StaticModelCatalogProvider(
            id: "shared-provider",
            displayName: "Built-in provider"
        )
        let external = StaticModelCatalogProvider(
            id: "shared-provider",
            displayName: "External provider"
        )

        let merged = ModelCatalogProviderSelection.merging(
            base: [base],
            external: [external]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.manifest.displayName, "Built-in provider")
    }

    func testModelCatalogFetchBatchRejectsIdentityMismatchWithoutDiscardingOtherProviders() async {
        let mismatched = BatchModelCatalogProvider(
            id: "provider-a",
            snapshot: makeSnapshot(
                [makeEntry(
                    id: "mismatched-entry",
                    modelName: "mismatched-model",
                    providerID: "provider-b"
                )],
                date: Date(timeIntervalSince1970: 1)
            ),
            shouldFail: false,
            providerIDInSnapshot: "provider-b"
        )
        let healthy = BatchModelCatalogProvider(
            id: "provider-b",
            snapshot: makeSnapshot(
                [makeEntry(
                    id: "healthy-entry",
                    modelName: "healthy-model",
                    providerID: "provider-b"
                )],
                date: Date(timeIntervalSince1970: 1)
            ),
            shouldFail: false,
            providerIDInSnapshot: "provider-b"
        )
        let failing = BatchModelCatalogProvider(
            id: "provider-c",
            snapshot: makeSnapshot(
                [makeEntry(
                    id: "unused-entry",
                    modelName: "unused-model",
                    providerID: "provider-c"
                )],
                date: Date(timeIntervalSince1970: 1)
            ),
            shouldFail: true
        )

        let outcomes = await ModelCatalogFetchBatch.fetch(providers: [mismatched, healthy, failing])
        XCTAssertEqual(outcomes.map(\.providerID), ["provider-a", "provider-b", "provider-c"])

        guard case let .failure(providerID, message) = outcomes[0] else {
            return XCTFail("the mismatched provider must be rejected")
        }
        XCTAssertEqual(providerID, "provider-a")
        XCTAssertTrue(message.contains("identity"))

        guard case let .success(snapshot) = outcomes[1] else {
            return XCTFail("a valid provider must still succeed in the same batch")
        }
        XCTAssertEqual(snapshot.providerID, "provider-b")

        guard case let .failure(providerID, message) = outcomes[2] else {
            return XCTFail("the failing provider must remain an independent failure")
        }
        XCTAssertEqual(providerID, "provider-c")
        XCTAssertEqual(message, "test failure")
    }

    func testComposedCatalogProvidesOneDisplayMatchForCustomAndRemoteModels() throws {
        let custom = CustomPricingTable(entries: [
            "custom-model": CustomModelPricing(
                inputCostPerToken: 0.000003,
                outputCostPerToken: 0.000004,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            )
        ])
        let remote = makeEntry(
            id: "remote-display",
            modelName: "remote-model",
            input: 0.000005,
            output: 0.000006,
            providerID: "example-gateway"
        )

        let composition = PricingCatalogComposition.make(
            customTable: custom,
            remoteEntries: [remote]
        )
        let customMatch = try XCTUnwrap(composition.match(for: "custom-model"))
        let remoteMatch = try XCTUnwrap(composition.match(for: "remote-model"))

        XCTAssertEqual(customMatch.source, .custom)
        XCTAssertEqual(customMatch.schedule.base.input, 0.000003)
        XCTAssertEqual(remoteMatch.source, .remote)
        XCTAssertEqual(remoteMatch.providerIDs, ["example-gateway"])
        XCTAssertEqual(remoteMatch.schedule.base.output, 0.000006)
    }

    func testNotificationFeedSettingDefaultsOnAndPersistsOff() {
        let suiteName = "Meterlark.ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        var settings = store.load()

        XCTAssertTrue(settings.notificationFeedEnabled)
        settings.notificationFeedEnabled = false
        store.save(settings)

        XCTAssertFalse(store.load().notificationFeedEnabled)
    }

    private func assertDecodeError(_ data: Data, _ expected: ModelCatalogDecodeError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try JSONModelCatalogDecoder.decode(data: data, providerID: "provider"), file: file, line: line) { error in
            XCTAssertEqual(error as? ModelCatalogDecodeError, expected, file: file, line: line)
        }
    }

    private func loadManifest() throws -> PluginManifest {
        let url = repoRoot().appendingPathComponent("Examples/Plugins/ModelCatalog/plugin.json")
        return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func configurationData(endpoint: String, apiKey: String) -> Data {
        try! JSONEncoder().encode(PluginJSONValue.object([
            "endpoint": .string(endpoint),
            "apiKey": .string(apiKey)
        ]))
    }

    private func sampleLikeCatalogData() -> Data {
        Data("""
        {
          "data": [
            {
              "model_name": "same-display-name",
              "litellm_params": {"model": "bedrock/route-a"},
              "model_info": {
                "id": "id-a",
                "input_cost_per_token": 0.00000025,
                "output_cost_per_token": 0.00000125,
                "cache_creation_input_token_cost": 0.0000003125,
                "cache_read_input_token_cost": 0.000000025,
                "input_cost_per_token_above_200k_tokens": 0.0000005,
                "max_input_tokens": 200000,
                "max_output_tokens": 4096,
                "litellm_provider": "bedrock",
                "supports_vision": true,
                "page_display_data": {
                  "provider": "AWS Bedrock",
                  "modality": ["Text", "Vision"],
                  "description": "A sample catalog model",
                  "enabled": true
                }
              }
            },
            {
              "model_name": "same-display-name",
              "litellm_params": {"model": "bedrock/route-a"},
              "model_info": {
                "id": "id-a",
                "input_cost_per_token": 0.00000025,
                "output_cost_per_token": 0.00000125,
                "cache_creation_input_token_cost": 0.0000003125,
                "cache_read_input_token_cost": 0.000000025,
                "input_cost_per_token_above_200k_tokens": 0.0000005,
                "max_input_tokens": 200000,
                "max_output_tokens": 4096,
                "litellm_provider": "bedrock",
                "supports_vision": true,
                "page_display_data": {
                  "provider": "AWS Bedrock",
                  "modality": ["Text", "Vision"],
                  "description": "A sample catalog model",
                  "enabled": true
                }
              }
            },
            {
              "model_name": "same-display-name",
              "litellm_params": {"model": "bedrock/route-b"},
              "model_info": {
                "id": "id-b",
                "input_cost_per_token": 0.0000003,
                "output_cost_per_token": 0.0000013,
                "max_input_tokens": 128000,
                "litellm_provider": "bedrock",
                "page_display_data": {"provider": "AWS Bedrock", "enabled": false}
              }
            },
            {
              "model_name": "alias-name",
              "litellm_params": {"model": "bedrock/route-a"},
              "model_info": {
                "id": "id-a",
                "input_cost_per_token": 0.00000025,
                "output_cost_per_token": 0.00000125,
                "cache_creation_input_token_cost": 0.0000003125,
                "cache_read_input_token_cost": 0.000000025,
                "input_cost_per_token_above_200k_tokens": 0.0000005,
                "max_input_tokens": 200000,
                "max_output_tokens": 4096,
                "litellm_provider": "bedrock",
                "supports_vision": true,
                "page_display_data": {
                  "provider": "AWS Bedrock",
                  "modality": ["Text", "Vision"],
                  "description": "A sample catalog model",
                  "enabled": true
                }
              }
            }
          ]
        }
        """.utf8)
    }

    private func reorderedCatalogData() -> Data {
        let source = try! JSONDecoder().decode(JSONValue.self, from: sampleLikeCatalogData())
        var object = source.objectValue!
        var records = object["data"]!.arrayValue!
        records.reverse()
        object["data"] = .array(records)
        return try! JSONEncoder().encode(JSONValue.object(object))
    }

    private func makeSnapshot(
        _ entries: [ModelCatalogEntry],
        date: Date,
        identitySchemaVersion: Int = ModelCatalogSnapshot.currentIdentitySchemaVersion,
        pricingSchemaVersion: Int = ModelCatalogSnapshot.currentPricingSchemaVersion
    ) -> ModelCatalogSnapshot {
        ModelCatalogSnapshot(
            providerID: "provider",
            fetchedAt: date,
            entries: entries,
            identitySchemaVersion: identitySchemaVersion,
            pricingSchemaVersion: pricingSchemaVersion
        )
    }

    private func makeEntry(
        id: String,
        modelName: String,
        enabled: Bool? = true,
        input: Double? = 0.000001,
        output: Double? = 0.000002,
        providerID: String = "provider",
        route: String? = nil,
        schedule: CanonicalModelPricing? = nil,
        version: String? = nil,
        baseModel: String? = nil,
        provider: String? = nil
    ) -> ModelCatalogEntry {
        let base = PricingRates(input: input, output: output, cacheCreation: nil, cacheRead: nil)
        let canonical = schedule ?? CanonicalModelPricing(
            modelName: modelName,
            base: base,
            tiers: [],
            maxInputTokens: nil,
            fastMultiplier: nil
        )
        var modelInfo: [String: JSONValue] = [
            "id": .string(id)
        ]
        if let enabled {
            modelInfo["enabled"] = .bool(enabled)
        }
        var params: [String: JSONValue] = [:]
        if let route {
            params["model"] = .string(route)
        }
        if let version {
            var pageDisplayData = modelInfo["page_display_data"]?.objectValue ?? [:]
            pageDisplayData["version"] = .string(version)
            modelInfo["page_display_data"] = .object(pageDisplayData)
        }
        if let baseModel {
            modelInfo["base_model"] = .string(baseModel)
        }
        if let provider {
            modelInfo["litellm_provider"] = .string(provider)
        }
        return ModelCatalogEntry(
            id: id,
            modelName: modelName,
            pricing: CustomModelPricing(
                inputCostPerToken: input,
                outputCostPerToken: output,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            ),
            metadata: ModelCatalogMetadata(modelInfo: modelInfo, litellmParams: params),
            source: .remote,
            providerID: providerID,
            recordIdentity: id,
            enabled: enabled,
            pricingSchedule: canonical
        )
    }

    private func temporaryURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-model-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private actor RequestRecorder {
        private(set) var request: URLRequest?

        func record(_ request: URLRequest) {
            self.request = request
        }
    }

    private struct StaticModelCatalogProvider: ModelCatalogPluginProvider {
        let manifest: PluginManifest
        let snapshot: ModelCatalogSnapshot

        init(id: String, displayName: String) {
            self.manifest = PluginManifest(
                manifestVersion: PluginManifest.currentManifestVersion,
                id: id,
                displayName: displayName,
                version: "1.0.0",
                protocolVersion: PluginManifest.currentProtocolVersion,
                capabilities: [.modelCatalog]
            )
            self.snapshot = ModelCatalogSnapshot(
                providerID: id,
                fetchedAt: Date(timeIntervalSince1970: 0),
                entries: []
            )
        }

        func fetchModelCatalog() async throws -> ModelCatalogSnapshot {
            snapshot
        }
    }

    private struct BatchModelCatalogProvider: ModelCatalogPluginProvider {
        let manifest: PluginManifest
        let snapshot: ModelCatalogSnapshot
        let shouldFail: Bool

        init(
            id: String,
            snapshot: ModelCatalogSnapshot,
            shouldFail: Bool,
            providerIDInSnapshot: String? = nil
        ) {
            self.manifest = PluginManifest(
                manifestVersion: PluginManifest.currentManifestVersion,
                id: id,
                displayName: id,
                version: "1.0.0",
                protocolVersion: PluginManifest.currentProtocolVersion,
                capabilities: [.modelCatalog]
            )
            if let providerIDInSnapshot, providerIDInSnapshot != snapshot.providerID {
                self.snapshot = ModelCatalogSnapshot(
                    providerID: providerIDInSnapshot,
                    fetchedAt: snapshot.fetchedAt,
                    entries: snapshot.entries
                )
            } else {
                self.snapshot = snapshot
            }
            self.shouldFail = shouldFail
        }

        func fetchModelCatalog() async throws -> ModelCatalogSnapshot {
            if shouldFail { throw TestError.failed }
            return snapshot
        }
    }

    private enum TestError: LocalizedError {
        case failed

        var errorDescription: String? { "test failure" }
    }
}
