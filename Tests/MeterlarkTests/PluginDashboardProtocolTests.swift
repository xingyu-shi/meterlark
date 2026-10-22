import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginDashboardProtocolTests: XCTestCase {
    func testValidDocumentMapsOneTwoAndFourTileGridsToHostModels() throws {
        let manifest = makeManifest()
        for (columns, tileCount) in [(1, 1), (2, 2), (2, 4)] {
            let document = try decodeDocument(gridJSON(columns: columns, tileCount: tileCount))
            let model = try document.makeModel(for: manifest)

            XCTAssertEqual(model.blocks.count, 1)
            guard case let .metricGrid(_, grid) = try XCTUnwrap(model.blocks.first) else {
                return XCTFail("Expected a metric-grid block")
            }
            XCTAssertEqual(grid.columns, columns)
            XCTAssertEqual(grid.tiles.count, tileCount)
        }
    }

    func testValidDocumentMapsAllProgressListRowSemantics() throws {
        let document = try decodeDocument("""
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [{
            "type": "progressList",
            "id": "quota",
            "header": {
              "title": { "text": "Quota" },
              "subtitle": { "text": "Current usage" },
              "trailingStatus": {
                "status": { "kind": "alert", "text": { "text": "Alert" } },
                "systemImage": "exclamationmark.triangle.fill"
              }
            },
            "items": [
              {
                "type": "progress",
                "id": "daily",
                "label": { "text": "Today" },
                "current": 25,
                "maximum": 100,
                "value": { "text": "25 / 100" },
                "status": { "kind": "normal", "text": { "text": "Normal" } }
              },
              {
                "type": "progressUnavailable",
                "id": "monthly",
                "label": { "text": "Month" },
                "maximum": 300,
                "message": { "text": "Waiting" },
                "status": { "kind": "noData", "text": { "text": "No data" } }
              },
              {
                "type": "value",
                "id": "account",
                "label": { "text": "Account" },
                "value": { "text": "xingyus" },
                "status": { "kind": "disabled", "text": { "text": "Configured" } }
              },
              {
                "type": "status",
                "id": "sync",
                "label": { "text": "Sync" },
                "message": { "text": "Up to date" },
                "status": { "kind": "normal", "text": { "text": "OK" } }
              }
            ]
          }]
        }
        """)

        let model = try document.makeModel(for: makeManifest())
        guard case let .progressList(_, list) = try XCTUnwrap(model.blocks.first) else {
            return XCTFail("Expected a progress-list block")
        }
        XCTAssertEqual(list.items.count, 4)
        XCTAssertEqual(list.header.trailingStatus?.systemImage, "exclamationmark.triangle.fill")
        guard case let .progress(progress) = list.items[0] else { return XCTFail("Expected progress row") }
        XCTAssertEqual(progress.current, 25)
        XCTAssertEqual(progress.progress, 0.25, accuracy: 0.0001)
        guard case let .progressUnavailable(unavailable) = list.items[1] else {
            return XCTFail("Expected unavailable progress row")
        }
        XCTAssertEqual(unavailable.maximum, 300)
        guard case .value = list.items[2] else { return XCTFail("Expected value row") }
        guard case .status = list.items[3] else { return XCTFail("Expected status row") }
    }

    func testTypedMetricValuesKeepSemanticKindsAndAccessibilityText() throws {
        let document = try decodeDocument("""
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [{
            "type": "metricGrid",
            "id": "metrics",
            "columns": 2,
            "tiles": [{
              "id": "cost",
              "header": { "text": "Today" },
              "primary": {
                "kind": "currency",
                "value": 6.81,
                "display": { "text": "$6.81", "accessibilityText": "$6.81 USD" }
              },
              "detail": { "text": "Daily cost" }
            }]
          }]
        }
        """)

        let model = try document.makeModel(for: makeManifest())
        guard case let .metricGrid(_, grid) = try XCTUnwrap(model.blocks.first) else {
            return XCTFail("Expected metric grid")
        }
        guard case let .currency(value, display) = grid.tiles[0].primary else {
            return XCTFail("Expected currency semantic value")
        }
        XCTAssertEqual(value, 6.81, accuracy: 0.0001)
        XCTAssertEqual(display.spokenText, "$6.81 USD")
        XCTAssertEqual(grid.tiles[0].accessibilityText, "Today, $6.81 USD, Daily cost")
    }

    func testDocumentRejectsIdentityDuplicatesInvalidNumbersAndInvalidRowStatus() throws {
        let manifest = makeManifest()

        let mismatched = try decodeDocument(gridJSON(columns: 1, tileCount: 1, pluginID: "com.other.plugin"))
        XCTAssertThrowsError(try mismatched.makeModel(for: manifest)) { error in
            XCTAssertEqual(
                error as? PluginDashboardValidationError,
                .pluginIDMismatch(expected: manifest.id, actual: "com.other.plugin")
            )
        }

        let duplicateBlocks = try decodeDocument(duplicateBlockJSON())
        XCTAssertThrowsError(try duplicateBlocks.makeModel(for: manifest)) { error in
            XCTAssertEqual(error as? PluginDashboardValidationError, .duplicateIdentifier("blocks"))
        }

        let invalidProgress = try decodeDocument(invalidProgressJSON())
        XCTAssertThrowsError(try invalidProgress.makeModel(for: manifest)) { error in
            guard case let .invalidNumericValue(path) = error as? PluginDashboardValidationError else {
                return XCTFail("Expected invalid numeric value, got \(error)")
            }
            XCTAssertTrue(path.contains("current/maximum"))
        }

        let invalidStatus = try decodeDocument(invalidProgressStatusJSON())
        XCTAssertThrowsError(try invalidStatus.makeModel(for: manifest)) { error in
            guard case let .invalidStatus(path) = error as? PluginDashboardValidationError else {
                return XCTFail("Expected invalid status, got \(error)")
            }
            XCTAssertTrue(path.contains("status"))
        }
    }

    func testDocumentRejectsMetricGridColumnsOutsideHostRange() throws {
        let manifest = makeManifest()
        for columns in [0, PluginDashboardLimits.maximumMetricColumns + 1] {
            let document = try decodeDocument(gridJSON(columns: columns, tileCount: 1))
            XCTAssertThrowsError(try document.makeModel(for: manifest)) { error in
                XCTAssertEqual(
                    error as? PluginDashboardValidationError,
                    .invalidBlock("blocks[0].columns")
                )
            }
        }
    }

    func testDocumentAppliesTheSameStructuralLimitsToProviderPayloads() throws {
        let manifest = makeManifest()

        let tooManyTiles = try decodeDocument(
            gridJSON(columns: 4, tileCount: PluginDashboardLimits.maximumMetricTiles + 1)
        )
        XCTAssertThrowsError(try tooManyTiles.makeModel(for: manifest)) { error in
            XCTAssertEqual(
                error as? PluginDashboardValidationError,
                .limitExceeded("blocks[0].tiles", PluginDashboardLimits.maximumMetricTiles)
            )
        }

        let tooManyBlocks = try decodeDocument(
            blocksJSON(count: PluginDashboardLimits.maximumBlocks + 1)
        )
        XCTAssertThrowsError(try tooManyBlocks.makeModel(for: manifest)) { error in
            XCTAssertEqual(
                error as? PluginDashboardValidationError,
                .limitExceeded("blocks", PluginDashboardLimits.maximumBlocks)
            )
        }

        let tooManyItems = try decodeDocument(
            progressListJSON(itemCount: PluginDashboardLimits.maximumProgressItems + 1)
        )
        XCTAssertThrowsError(try tooManyItems.makeModel(for: manifest)) { error in
            XCTAssertEqual(
                error as? PluginDashboardValidationError,
                .limitExceeded("blocks[0].items", PluginDashboardLimits.maximumProgressItems)
            )
        }
    }

    func testNonReadyLifecycleRequiresMessageAndStaleCanKeepBlocks() throws {
        let loading = try decodeDocument("""
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "loading" },
          "blocks": []
        }
        """)
        XCTAssertThrowsError(try loading.makeModel(for: makeManifest())) { error in
            XCTAssertEqual(error as? PluginDashboardValidationError, .missingLifecycleMessage)
        }

        let stale = try decodeDocument(gridJSON(columns: 1, tileCount: 1, lifecycle: "stale", lifecycleMessage: "Last update was 2 minutes ago"))
        let model = try stale.makeModel(for: makeManifest())
        XCTAssertEqual(model.lifecycle.kind, .stale)
        XCTAssertEqual(model.lifecycle.message?.text, "Last update was 2 minutes ago")
        XCTAssertEqual(model.blocks.count, 1)
    }

    func testUnknownBlockTypeIsRejectedDuringJSONDecoding() {
        XCTAssertThrowsError(try decodeDocument("""
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [{ "type": "chart", "id": "chart" }]
        }
        """))
    }

    func testDocumentRoundTripsThroughJSONEncoder() throws {
        let document = try decodeDocument("""
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "stale", "message": { "text": "Cached" } },
          "blocks": [{
            "type": "metricGrid",
            "id": "metrics",
            "columns": 1,
            "tiles": [{
              "id": "count",
              "header": { "text": "Count" },
              "primary": { "kind": "integer", "value": 12, "display": { "text": "12" } }
            }]
          }]
        }
        """)

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(PluginDashboardDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }

    private func makeManifest() -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            id: "com.example.plugin",
            displayName: "Example",
            version: "1.0.0",
            protocolVersion: 1
        )
    }

    private func decodeDocument(_ json: String) throws -> PluginDashboardDocument {
        try JSONDecoder().decode(PluginDashboardDocument.self, from: Data(json.utf8))
    }

    private func gridJSON(
        columns: Int,
        tileCount: Int,
        pluginID: String = "com.example.plugin",
        lifecycle: String = "ready",
        lifecycleMessage: String? = nil
    ) -> String {
        let tiles = (1...tileCount).map { index in
            """
            {
              "id": "tile-\(index)",
              "header": { "text": "Tile \(index)" },
              "primary": { "kind": "integer", "value": \(index), "display": { "text": "\(index)" } },
              "detail": { "text": "Detail \(index)" }
            }
            """
        }.joined(separator: ",")
        let message = lifecycleMessage.map { ", \"message\": { \"text\": \"\($0)\" }" } ?? ""
        return """
        {
          "protocolVersion": 1,
          "pluginID": "\(pluginID)",
          "lifecycle": { "kind": "\(lifecycle)"\(message) },
          "blocks": [{
            "type": "metricGrid",
            "id": "metrics",
            "columns": \(columns),
            "tiles": [\(tiles)]
          }]
        }
        """
    }

    private func blocksJSON(count: Int) -> String {
        let blocks = (0..<count).map { index in
            """
            {"type":"metricGrid","id":"grid-\(index)","columns":1,"tiles":[{"id":"tile","header":{"text":"Tile"},"primary":{"kind":"integer","value":1,"display":{"text":"1"}}}]}
            """
        }.joined(separator: ",")
        return """
        {"protocolVersion":1,"pluginID":"com.example.plugin","lifecycle":{"kind":"ready"},"blocks":[\(blocks)]}
        """
    }

    private func progressListJSON(itemCount: Int) -> String {
        let items = (0..<itemCount).map { index in
            """
            {"type":"value","id":"item-\(index)","label":{"text":"Item"},"value":{"text":"1"},"status":{"kind":"normal","text":{"text":"OK"}}}
            """
        }.joined(separator: ",")
        return """
        {"protocolVersion":1,"pluginID":"com.example.plugin","lifecycle":{"kind":"ready"},"blocks":[{"type":"progressList","id":"list","header":{"title":{"text":"List"}},"items":[\(items)]}]}
        """
    }

    private func duplicateBlockJSON() -> String {
        """
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [
            {
              "type": "metricGrid",
              "id": "same",
              "columns": 1,
              "tiles": []
            },
            {
              "type": "metricGrid",
              "id": "same",
              "columns": 1,
              "tiles": []
            }
          ]
        }
        """
    }

    private func invalidProgressJSON() -> String {
        """
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [{
            "type": "progressList",
            "id": "quota",
            "header": { "title": { "text": "Quota" } },
            "items": [{
              "type": "progress",
              "id": "daily",
              "label": { "text": "Today" },
              "current": 5,
              "maximum": 0,
              "value": { "text": "5 / 0" },
              "status": { "kind": "normal", "text": { "text": "Normal" } }
            }]
          }]
        }
        """
    }

    private func invalidProgressStatusJSON() -> String {
        """
        {
          "protocolVersion": 1,
          "pluginID": "com.example.plugin",
          "lifecycle": { "kind": "ready" },
          "blocks": [{
            "type": "progressList",
            "id": "quota",
            "header": { "title": { "text": "Quota" } },
            "items": [{
              "type": "progress",
              "id": "daily",
              "label": { "text": "Today" },
              "current": 5,
              "maximum": 100,
              "value": { "text": "5 / 100" },
              "status": { "kind": "noData", "text": { "text": "No data" } }
            }]
          }]
        }
        """
    }
}
