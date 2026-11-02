import AppKit
import SwiftUI
import XCTest
@testable import MeterlarkApp

@MainActor
final class AppSettingsWindowTests: XCTestCase {
    func testReopeningSettingsReusesTheWindowAndHostAndUpdatesLanguage() throws {
        try withStore { store, _ in
            let controller = AppSettingsWindowController()
            controller.show(store: store, updater: AppUpdater())
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            let host = try XCTUnwrap(window.contentView)
            window.setContentSize(NSSize(width: 840, height: 650))
            settle(host)
            XCTAssertEqual(host.bounds.height, 650, accuracy: 1)
            XCTAssertEqual(window.title, L10n(language: .english).generalSettings + " · Meterlark")

            controller.close()
            store.setLanguage(.chinese)
            controller.show(store: store, updater: AppUpdater())
            settle(host)
            XCTAssertTrue(controller.window === window)
            XCTAssertTrue(window.contentView === host)
            XCTAssertEqual(window.title, L10n(language: .chinese).generalSettings + " · Meterlark")
        }
    }

    func testEverySettingsPageCanRenderWithoutChangingPreferences() throws {
        try withStore { store, _ in
            let renderDirectory = ProcessInfo.processInfo.environment["METERLARK_SETTINGS_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
            if let renderDirectory {
                try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
            }
            for language in [AppLanguage.english, .chinese] {
                store.setLanguage(language)
                store.setAppearance(language == .english ? .light : .dark)
                store.setInterfaceTextSize(language == .english ? .standard : .largest)
                let before = store.settings
                for page in AppSettingsPage.allCases {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    defer { window.close() }
                    let host = NSHostingView(rootView: AppSettingsView(store: store, updater: AppUpdater(), initialPage: page))
                    host.sizingOptions = []
                    window.contentView = host
                    window.orderFront(nil)
                    settle(host)
                    XCTAssertEqual(host.bounds.height, 650, accuracy: 1, "Page content must scroll instead of resizing its host")
                    XCTAssertEqual(store.settings, before, "Opening \(page) must not change saved preferences")
                    XCTAssertGreaterThan(host.bounds.width, 0)
                    if let renderDirectory {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: renderDirectory.appendingPathComponent("\(language.rawValue)-\(page.rawValue).png"))
                    }
                }
            }
        }
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        view.layoutSubtreeIfNeeded()
    }

    private func withStore(_ body: (MonitorStore, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Meterlark.SettingsWindowTests.\(UUID().uuidString)", isDirectory: true)
        let suite = "Meterlark.SettingsWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("english", forKey: "Meterlark.language")
        defaults.set(false, forKey: "Meterlark.automaticPricingRefresh")
        let registry = ExternalPluginRegistry(
            catalog: PluginCatalog(rootURL: root.appendingPathComponent("plugins")),
            activationStore: PluginActivationStore(fileURL: root.appendingPathComponent("activations.json")),
            configurationStore: PluginConfigurationStore(baseURL: root.appendingPathComponent("configuration"), secretStore: NoSecrets())
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
        try body(store, root)
    }

    private struct NoSecrets: PluginSecretStore {
        func read(service: String, account: String) throws -> Data? { nil }
        func write(_ data: Data, service: String, account: String) throws {}
        func delete(service: String, account: String) throws {}
    }

    private final class EmptyRunner: CCUsageRunnerProtocol {
        func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot { .empty }
    }

    private final class IdleWatcher: SourceChangeWatcherProtocol {
        var isRunning: Bool { true }
        func start() {}
        func stop() {}
    }
}
