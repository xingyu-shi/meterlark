import Foundation
import XCTest
@testable import MeterlarkApp

final class LegacyDataMigrationTests: XCTestCase {
    func testCopiesDataAndPreferencesWithoutRemovingPreviousData() throws {
        try withEnvironment { root, defaults in
            let previous = root.appendingPathComponent(LegacyDataMigration.dataDirectoryName)
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let priceFile = previous.appendingPathComponent("custom-pricing.json")
            try Data("{}".utf8).write(to: priceFile)
            let legacy: [String: Any] = [
                LegacyDataMigration.preferencesPrefix + "lookbackDays": 30,
                LegacyDataMigration.preferencesPrefix + "customPricingPath": priceFile.path,
                LegacyDataMigration.preferencesPrefix + "launchAtLogin": true,
                "unrelated": "ignored"
            ]
            try LegacyDataMigration.migrate(defaults: defaults, legacyValues: legacy, supportRoot: root)

            let currentPrice = root.appendingPathComponent(AppIdentity.dataDirectoryName)
                .appendingPathComponent("custom-pricing.json")
            XCTAssertEqual(try Data(contentsOf: currentPrice), Data("{}".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: priceFile.path))
            XCTAssertEqual(defaults.integer(forKey: "Meterlark.lookbackDays"), 30)
            XCTAssertEqual(defaults.string(forKey: "Meterlark.customPricingPath"), currentPrice.path)
            XCTAssertFalse(defaults.bool(forKey: "Meterlark.launchAtLogin"))
            XCTAssertNil(defaults.object(forKey: "unrelated"))
        }
    }

    func testExistingMeterlarkDataAndPreferencesWinAndMigrationRunsOnce() throws {
        try withEnvironment { root, defaults in
            let current = root.appendingPathComponent(AppIdentity.dataDirectoryName)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            let snapshot = current.appendingPathComponent("snapshot.json")
            try Data("current".utf8).write(to: snapshot)
            defaults.set(7, forKey: "Meterlark.lookbackDays")
            let legacy = [LegacyDataMigration.preferencesPrefix + "lookbackDays": 90]
            try LegacyDataMigration.migrate(defaults: defaults, legacyValues: legacy, supportRoot: root)
            XCTAssertEqual(defaults.integer(forKey: "Meterlark.lookbackDays"), 7)
            defaults.removeObject(forKey: "Meterlark.lookbackDays")
            try LegacyDataMigration.migrate(defaults: defaults, legacyValues: legacy, supportRoot: root)
            XCTAssertNil(defaults.object(forKey: "Meterlark.lookbackDays"))
            XCTAssertEqual(try Data(contentsOf: snapshot), Data("current".utf8))
        }
    }

    func testFailedMigrationCanRetryWithoutLosingPreviousData() throws {
        try withEnvironment { root, defaults in
            let previous = root.appendingPathComponent(LegacyDataMigration.dataDirectoryName)
            let current = root.appendingPathComponent(AppIdentity.dataDirectoryName)
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: previous.appendingPathComponent("snapshot.json"))
            try Data("blocking file".utf8).write(to: current)
            XCTAssertThrowsError(try LegacyDataMigration.migrate(defaults: defaults, legacyValues: [:], supportRoot: root))
            try FileManager.default.removeItem(at: current)
            try LegacyDataMigration.migrate(defaults: defaults, legacyValues: [:], supportRoot: root)
            XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("snapshot.json")), Data("original".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("snapshot.json").path))
        }
    }

    func testCredentialMigrationCopiesOnceAndClearingCannotRestoreOldValue() throws {
        let base = MemorySecretStore()
        let store = MigratingPluginSecretStore(base: base)
        let account = "example:token"
        let service = AppIdentity.pluginSecretService
        try base.write(Data("previous-test-value".utf8), service: LegacyDataMigration.pluginSecretService, account: account)
        XCTAssertEqual(try store.read(service: service, account: account), Data("previous-test-value".utf8))
        try store.write(Data("current-test-value".utf8), service: service, account: account)
        XCTAssertEqual(try store.read(service: service, account: account), Data("current-test-value".utf8))
        try store.delete(service: service, account: account)
        XCTAssertNil(try store.read(service: service, account: account))
        XCTAssertNil(try base.read(service: LegacyDataMigration.pluginSecretService, account: account))
    }

    func testUnrelatedKeychainServiceDoesNotImportCredentials() throws {
        let base = MemorySecretStore()
        try base.write(Data("previous-test-value".utf8), service: LegacyDataMigration.pluginSecretService, account: "example")
        XCTAssertNil(try MigratingPluginSecretStore(base: base).read(service: "unrelated", account: "example"))
    }

    func testFailedCredentialCopyPreservesLegacyCredential() throws {
        let base = MemorySecretStore()
        let value = Data("previous-test-value".utf8)
        try base.write(value, service: LegacyDataMigration.pluginSecretService, account: "example")
        base.failWrites = true
        XCTAssertThrowsError(try MigratingPluginSecretStore(base: base).read(service: AppIdentity.pluginSecretService, account: "example"))
        XCTAssertEqual(try base.read(service: LegacyDataMigration.pluginSecretService, account: "example"), value)
    }

    func testPackagedIdentityMatchesPersistenceIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Meterlark")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Meterlark")
    }

    private func withEnvironment(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Meterlark.MigrationTests.\(UUID().uuidString)")
        let suite = "Meterlark.MigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try body(root, defaults)
    }

    private final class MemorySecretStore: PluginSecretStore, @unchecked Sendable {
        private var values: [String: Data] = [:]
        var failWrites = false

        func read(service: String, account: String) throws -> Data? { values[service + ":" + account] }
        func write(_ data: Data, service: String, account: String) throws {
            if failWrites { throw PluginSecretStoreError.operationFailed(-1) }
            values[service + ":" + account] = data
        }
        func delete(service: String, account: String) throws { values.removeValue(forKey: service + ":" + account) }
    }
}
