import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginRuntimeTests: XCTestCase {
    func testSuccessfulRefreshPublishesReadyDashboard() async throws {
        let provider = StubProvider(document: readyDocument())
        let runtime = PluginDashboardRuntime(provider: provider)

        let state = await runtime.refresh(now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(state.pluginID, provider.manifest.id)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNotNil(state.dashboard)
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 100))
    }

    func testFailureAfterSuccessfulRefreshKeepsLastDashboardAsStale() async throws {
        let provider = StubProvider(document: readyDocument())
        let runtime = PluginDashboardRuntime(provider: provider)
        _ = await runtime.refresh(now: Date(timeIntervalSince1970: 100))
        await provider.failNext()

        let state = await runtime.refresh(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(state.phase, .stale)
        XCTAssertNotNil(state.dashboard)
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertFalse(state.message?.isEmpty ?? true)
    }

    func testFirstFailureDoesNotPretendStaleDataExists() async {
        let provider = StubProvider(document: readyDocument())
        await provider.failNext()
        let runtime = PluginDashboardRuntime(provider: provider)

        let state = await runtime.refresh()

        XCTAssertEqual(state.phase, .failed)
        XCTAssertNil(state.dashboard)
        XCTAssertNil(state.updatedAt)
    }

    func testProviderUnavailableDocumentRemainsUnavailable() async throws {
        let document = PluginDashboardDocument(
            protocolVersion: 1,
            pluginID: "com.example.plugin",
            lifecycle: PluginLifecyclePayload(
                kind: .unavailable,
                message: PluginTextPayload(text: "Not configured")
            ),
            blocks: []
        )
        let runtime = PluginDashboardRuntime(provider: StubProvider(document: document))

        let state = await runtime.refresh()

        XCTAssertEqual(state.phase, PluginRuntimePhase.unavailable)
        XCTAssertEqual(state.message, "Not configured")
        XCTAssertNotNil(state.dashboard)
    }

    private func readyDocument() -> PluginDashboardDocument {
        PluginDashboardDocument(
            protocolVersion: 1,
            pluginID: "com.example.plugin",
            lifecycle: PluginLifecyclePayload(kind: .ready, message: nil),
            blocks: []
        )
    }

    private actor StubProvider: DashboardPluginProvider {
        let manifest = PluginManifest(
            manifestVersion: 1,
            id: "com.example.plugin",
            displayName: "Example",
            version: "1.0.0",
            protocolVersion: 1
        )
        let document: PluginDashboardDocument
        var shouldFail = false

        init(document: PluginDashboardDocument) {
            self.document = document
        }

        func failNext() {
            shouldFail = true
        }

        func fetchDashboard() async throws -> PluginDashboardDocument {
            if shouldFail {
                shouldFail = false
                throw URLError(.badServerResponse)
            }
            return document
        }
    }
}
