import AppKit
import XCTest
@testable import MeterlarkApp

@MainActor
final class PluginConfigurationWindowTests: XCTestCase {
    func testSwitchingPluginsAndReopeningLoadsTheCorrectConfiguration() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.ConfigurationWindowTests.\(UUID().uuidString)", isDirectory: true)
        let suite = "Meterlark.ConfigurationWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("english", forKey: "Meterlark.language")
        defaults.set(false, forKey: "Meterlark.automaticPricingRefresh")
        let configurationStore = PluginConfigurationStore(
            baseURL: root.appendingPathComponent("configuration"),
            secretStore: NoSecrets()
        )
        let pluginRoot = root.appendingPathComponent("plugins")
        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/Plugins/Gateway/plugin.json")
        let exampleData = try Data(contentsOf: exampleURL)
        for (name, endpoint) in [
            ("a", "https://provider-a.example.test"),
            ("b", "https://provider-b.example.test")
        ] {
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: exampleData) as? [String: Any])
            let id = "com.example.review-\(name)"
            object["id"] = id
            object["displayName"] = "Review \(name)"
            let directory = pluginRoot.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("plugin.json"))
            try saveEndpoint(endpoint, pluginID: id, store: configurationStore)
        }
        let registry = ExternalPluginRegistry(
            catalog: PluginCatalog(rootURL: pluginRoot),
            activationStore: PluginActivationStore(fileURL: root.appendingPathComponent("activations.json")),
            configurationStore: configurationStore
        )
        let store = MonitorStore(
            snapshotStore: SnapshotStore(baseURL: root),
            budgetSnapshotStore: BudgetSnapshotStore(baseURL: root),
            settingsStore: SettingsStore(defaults: defaults),
            runner: EmptyRunner(),
            sourceRootsProvider: { [] },
            watcherFactory: { _, _ in IdleWatcher() },
            fingerprintReader: { [] },
            generatedPricingDirectory: root.appendingPathComponent("pricing"),
            externalPluginRegistry: registry,
            modelCatalogStore: ModelCatalogStore(fileURL: root.appendingPathComponent("catalog.json")),
            notificationFeedStore: NotificationFeedStore(fileURL: root.appendingPathComponent("feed.json"))
        )
        XCTAssertEqual(store.externalPlugins.count, 2)
        store.showPluginConfiguration(pluginID: "com.example.review-a")
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.title == L10n(language: .english).pluginConfigurationTitle("Review a")
        })
        defer { window.close() }
        XCTAssertTrue(renderedTextFields(in: window).contains("https://provider-a.example.test"))

        store.showPluginConfiguration(pluginID: "com.example.review-b")
        let switchedFields = renderedTextFields(in: window)
        XCTAssertTrue(switchedFields.contains("https://provider-b.example.test"))
        XCTAssertFalse(switchedFields.contains("https://provider-a.example.test"))

        try saveEndpoint("https://updated-b.example.test", pluginID: "com.example.review-b", store: configurationStore)
        window.orderOut(nil)
        store.showPluginConfiguration(pluginID: "com.example.review-b")
        let reopenedFields = renderedTextFields(in: window)
        XCTAssertTrue(reopenedFields.contains("https://updated-b.example.test"))
        XCTAssertFalse(reopenedFields.contains("https://provider-b.example.test"))
    }

    private func renderedTextFields(in window: NSWindow) -> [String] {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func fields(in view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? [])
                + view.subviews.flatMap { fields(in: $0) }
        }
        return window.contentView.map { fields(in: $0) } ?? []
    }

    private func saveEndpoint(_ endpoint: String, pluginID: String, store: PluginConfigurationStore) throws {
        try store.save(
            JSONEncoder().encode(PluginJSONValue.object([
                "endpoint": .string(endpoint),
                "refreshEndpoint": .string("https://token.example.test")
            ])),
            pluginID: pluginID
        )
    }

    private struct NoSecrets: PluginSecretStore {
        func read(service: String, account: String) throws -> Data? { nil }
        func write(_ data: Data, service: String, account: String) throws {}
        func delete(service: String, account: String) throws {}
    }

    private final class EmptyRunner: CCUsageRunnerProtocol {
        func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
            .empty
        }
    }

    private final class IdleWatcher: SourceChangeWatcherProtocol {
        var isRunning: Bool { true }
        func start() {}
        func stop() {}
    }
}
