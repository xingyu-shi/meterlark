import Foundation
import XCTest
@testable import MeterlarkApp

@MainActor
final class PluginHostTests: XCTestCase {
    func testEmptyHostHasNoImplicitProviders() {
        let host = DashboardPluginHost(providers: [])

        XCTAssertTrue(host.snapshots.isEmpty)
    }

    func testEnabledExternalProviderReplacesBuiltInProviderWithSameID() async throws {
        let builtIn = StaticProvider(
            manifest: selectionManifest(version: "built-in"),
            document: readyDocument(id: "com.example.meterlark.gateway")
        )
        let external = StaticProvider(
            manifest: selectionManifest(version: "external"),
            document: readyDocument(id: "com.example.meterlark.gateway")
        )

        let providers = DashboardPluginProviderSelection.merging(
            base: [builtIn],
            external: [external]
        )

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].manifest.version, "external")

        let host = DashboardPluginHost(providers: providers)
        host.refreshAll()
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        XCTAssertEqual(host.snapshots.first?.manifest.version, "external")
        XCTAssertNotNil(host.snapshots.first?.runtime.dashboard)
    }

    func testProviderSelectionKeepsDistinctProvidersSorted() {
        let first = StaticProvider(
            manifest: selectionManifest(id: "com.example.z", version: "z"),
            document: readyDocument(id: "com.example.z")
        )
        let second = StaticProvider(
            manifest: selectionManifest(id: "com.example.a", version: "a"),
            document: readyDocument(id: "com.example.a")
        )

        let providers = DashboardPluginProviderSelection.merging(
            base: [first],
            external: [second]
        )

        XCTAssertEqual(providers.map { $0.manifest.id }, ["com.example.a", "com.example.z"])
    }

    func testHostSortsRegistrationsAndPublishesReadyState() async {
        let first = ControlledProvider(id: "com.example.z", displayName: "Zed", document: readyDocument(id: "com.example.z"))
        let second = ControlledProvider(id: "com.example.a", displayName: "Alpha", document: readyDocument(id: "com.example.a"))
        let host = DashboardPluginHost(providers: [first, second])

        XCTAssertEqual(host.snapshots.map(\.id), ["com.example.a", "com.example.z"])

        host.refreshAll(now: Date(timeIntervalSince1970: 100))
        await waitUntil { host.snapshots.allSatisfy { $0.runtime.phase == .ready } }

        XCTAssertEqual(host.snapshots.map(\.runtime.pluginID), ["com.example.a", "com.example.z"])
        XCTAssertTrue(host.snapshots.allSatisfy { $0.runtime.dashboard != nil })
    }

    func testHostDoesNotOverlapRefreshesForOnePlugin() async {
        let provider = ControlledProvider(
            id: "com.example.gated",
            displayName: "Gated",
            document: readyDocument(id: "com.example.gated"),
            waitsForRelease: true
        )
        let host = DashboardPluginHost(providers: [provider])

        host.refreshAll()
        await waitUntil { await provider.callCount == 1 }
        host.refreshAll()
        await Task.yield()
        let callsWhileBlocked = await provider.callCount
        XCTAssertEqual(callsWhileBlocked, 1)

        await provider.release()
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        let callsAfterRelease = await provider.callCount
        XCTAssertEqual(callsAfterRelease, 1)
    }

    func testHostKeepsLastDashboardWhenProviderFailsAfterSuccess() async {
        let provider = ControlledProvider(
            id: "com.example.stale",
            displayName: "Stale",
            document: readyDocument(id: "com.example.stale")
        )
        let host = DashboardPluginHost(providers: [provider])

        host.refreshAll(now: Date(timeIntervalSince1970: 100))
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        await provider.failNext()
        host.refreshAll(now: Date(timeIntervalSince1970: 200))
        await waitUntil { host.snapshots.first?.runtime.phase == .stale }

        XCTAssertNotNil(host.snapshots.first?.runtime.dashboard)
        XCTAssertEqual(host.snapshots.first?.runtime.updatedAt, Date(timeIntervalSince1970: 100))
        let staleMessage = host.snapshots.first?.runtime.message
        XCTAssertFalse(staleMessage?.isEmpty ?? true)

        host.setLanguage(.chinese)

        XCTAssertEqual(host.snapshots.first?.runtime.message, staleMessage)
    }

    func testReplacingUnchangedProviderPreservesStaleDiagnostic() async {
        let provider = ControlledProvider(
            id: "com.example.reload-stale",
            displayName: "Reload Stale",
            document: readyDocument(id: "com.example.reload-stale")
        )
        let host = DashboardPluginHost(providers: [provider])

        host.refreshAll(now: Date(timeIntervalSince1970: 100))
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        await provider.failNext()
        host.refreshAll(now: Date(timeIntervalSince1970: 200))
        await waitUntil { host.snapshots.first?.runtime.phase == .stale }
        let staleMessage = host.snapshots.first?.runtime.message

        let replacement = ControlledProvider(
            id: "com.example.reload-stale",
            displayName: "Reload Stale",
            document: readyDocument(id: "com.example.reload-stale")
        )
        host.replaceProviders([replacement])

        XCTAssertEqual(host.snapshots.first?.runtime.phase, .stale)
        XCTAssertEqual(host.snapshots.first?.runtime.message, staleMessage)
        XCTAssertNotNil(host.snapshots.first?.runtime.document)
        let replacementCallCount = await replacement.callCount
        XCTAssertEqual(replacementCallCount, 0)
    }

    func testChangingLanguageRendersCachedDocumentWithoutRefreshingProvider() async {
        let document = localizedDocument(id: "com.example.localized")
        let provider = ControlledProvider(
            id: "com.example.localized",
            displayName: "Usage",
            document: document
        )
        let host = DashboardPluginHost(providers: [provider], language: .english)

        host.refreshAll()
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        XCTAssertEqual(localizedHeader(host.snapshots), "Usage")
        let initialCallCount = await provider.callCount
        XCTAssertEqual(initialCallCount, 1)

        host.setLanguage(.chinese)

        XCTAssertEqual(localizedHeader(host.snapshots), "用量")
        let callCountAfterLanguageChange = await provider.callCount
        XCTAssertEqual(callCountAfterLanguageChange, 1)
    }

    func testHostCanReplaceProvidersWithoutRetainingRemovedPlugins() async {
        let first = ControlledProvider(
            id: "com.example.first",
            displayName: "First",
            document: readyDocument(id: "com.example.first")
        )
        let second = ControlledProvider(
            id: "com.example.second",
            displayName: "Second",
            document: readyDocument(id: "com.example.second")
        )
        let host = DashboardPluginHost(providers: [first])

        host.replaceProviders([second])
        XCTAssertEqual(host.snapshots.map(\.id), ["com.example.second"])

        host.refreshAll()
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }
        let firstCallCount = await first.callCount
        let secondCallCount = await second.callCount
        XCTAssertEqual(firstCallCount, 0)
        XCTAssertEqual(secondCallCount, 1)
    }

    func testReplacingProvidersPreservesUnchangedRuntimeButCanResetChangedIDs() async {
        let manifest = selectionManifest(id: "com.example.preserved", version: "1.0.0")
        let first = ControlledProvider(
            id: manifest.id,
            displayName: manifest.displayName,
            document: readyDocument(id: manifest.id)
        )
        let host = DashboardPluginHost(providers: [first])

        host.refreshAll(now: Date(timeIntervalSince1970: 100))
        await waitUntil { host.snapshots.first?.runtime.phase == .ready }

        let replacement = ControlledProvider(
            id: manifest.id,
            displayName: manifest.displayName,
            document: readyDocument(id: manifest.id)
        )
        host.replaceProviders([replacement])
        XCTAssertEqual(host.snapshots.first?.runtime.phase, .ready)
        let callsBeforeReset = await replacement.callCount
        XCTAssertEqual(callsBeforeReset, 0)

        host.replaceProviders([replacement], replacingIDs: [manifest.id])
        XCTAssertEqual(host.snapshots.first?.runtime.phase, .idle)
        host.refreshAll()
        await waitUntil { await replacement.callCount == 1 }
    }

    private func readyDocument(id: String) -> PluginDashboardDocument {
        PluginDashboardDocument(
            protocolVersion: 1,
            pluginID: id,
            lifecycle: PluginLifecyclePayload(kind: .ready, message: nil),
            blocks: []
        )
    }

    private func localizedDocument(id: String) -> PluginDashboardDocument {
        PluginDashboardDocument(
            protocolVersion: 1,
            pluginID: id,
            lifecycle: PluginLifecyclePayload(kind: .ready, message: nil),
            blocks: [
                .metricGrid(PluginMetricGridPayload(
                    id: "summary",
                    columns: 1,
                    tiles: [PluginMetricTilePayload(
                        id: "usage",
                        header: PluginTextPayload(localizedText: PluginLocalizedText(
                            fallback: "Usage",
                            translations: ["zh-Hans": "用量"]
                        )),
                        primary: PluginMetricValuePayload(
                            integer: 1,
                            display: PluginTextPayload(text: "1")
                        ),
                        detail: nil
                    )]
                ))
            ]
        )
    }

    private func localizedHeader(_ snapshots: [DashboardPluginRuntimeSnapshot]) -> String? {
        guard let dashboard = snapshots.first?.runtime.dashboard,
              case let .metricGrid(_, grid) = dashboard.blocks.first else {
            return nil
        }
        return grid.tiles.first?.header.text
    }

    private func selectionManifest(
        id: String = "com.example.meterlark.gateway",
        version: String
    ) -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            id: id,
            displayName: "ExampleGateway",
            version: version,
            protocolVersion: 1
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private actor ControlledProvider: DashboardPluginProvider {
        let manifest: PluginManifest
        let document: PluginDashboardDocument
        let waitsForRelease: Bool
        private(set) var callCount = 0
        private var shouldFail = false
        private var continuations: [CheckedContinuation<PluginDashboardDocument, Never>] = []

        init(
            id: String,
            displayName: String,
            document: PluginDashboardDocument,
            waitsForRelease: Bool = false
        ) {
            self.manifest = PluginManifest(
                manifestVersion: 1,
                id: id,
                displayName: displayName,
                version: "1.0.0",
                protocolVersion: 1
            )
            self.document = document
            self.waitsForRelease = waitsForRelease
        }

        func failNext() {
            shouldFail = true
        }

        func release() {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume(returning: document) }
        }

        func fetchDashboard() async throws -> PluginDashboardDocument {
            callCount += 1
            if shouldFail {
                shouldFail = false
                throw URLError(.badServerResponse)
            }
            guard waitsForRelease else { return document }
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    private struct StaticProvider: DashboardPluginProvider {
        let manifest: PluginManifest
        let document: PluginDashboardDocument

        func fetchDashboard() async throws -> PluginDashboardDocument {
            document
        }
    }
}
