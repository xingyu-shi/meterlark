import Foundation
import XCTest
@testable import MeterlarkApp

final class ExternalPluginRegistryTests: XCTestCase {
    func testDiscoveredExternalPluginsAreDisabledUntilExplicitlyEnabled() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        let configurationRoot = root.appendingPathComponent("config", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(parent: root, id: "com.example.external")
        let installer = PluginPackageInstaller()
        _ = try installer.install(from: package, into: installRoot)

        let registry = makeRegistry(
            root: installRoot,
            activationURL: activationURL,
            configurationRoot: configurationRoot
        )

        let discovered = registry.discover()
        XCTAssertEqual(discovered.map(\.id), ["com.example.external"])
        XCTAssertFalse(discovered[0].enabled)
        XCTAssertTrue(registry.enabledProviders().isEmpty)

        try registry.setEnabled(true, pluginID: "com.example.external")

        let enabled = try XCTUnwrap(registry.discover().first)
        XCTAssertTrue(enabled.enabled)
        XCTAssertTrue(enabled.isValid)
        XCTAssertEqual(registry.enabledProviders().map { $0.manifest.id }, ["com.example.external"])
    }

    func testExamplePackageDiscoveryIsVisibleButDisabledByDefault() throws {
        let root = temporaryDirectory()
        let userPluginRoot = root.appendingPathComponent("UserPlugins", isDirectory: true)
        let bundledPluginRoot = root.appendingPathComponent("BundledPlugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        let configurationRoot = root.appendingPathComponent("config", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundledPackage = bundledPluginRoot.appendingPathComponent(
            "com.example.meterlark.gateway",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundledPackage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repoRoot().appendingPathComponent("Examples/Plugins/Gateway/plugin.json"),
            to: bundledPackage.appendingPathComponent("plugin.json")
        )

        let registry = makeRegistry(
            root: userPluginRoot,
            bundledRoot: bundledPluginRoot,
            activationURL: activationURL,
            configurationRoot: configurationRoot
        )

        let record = try XCTUnwrap(registry.discover().first)
        XCTAssertEqual(record.id, "com.example.meterlark.gateway")
        XCTAssertFalse(record.enabled)
        XCTAssertNil(record.validationMessage)
        XCTAssertTrue(record.configurationValidationMessage?.contains("Required") == true)
        XCTAssertTrue(record.isPackageValid)
        XCTAssertFalse(record.isConfigurationReady)
        XCTAssertTrue(record.canToggle)
        XCTAssertTrue(registry.enabledProviders().isEmpty)
    }

    func testInvalidInstalledPackageCannotBeEnabledOrRegistered() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePackage(
            parent: installRoot,
            id: "com.example.invalid",
            includeExecutable: false
        )
        let registry = makeRegistry(root: installRoot, activationURL: activationURL)

        let record = try XCTUnwrap(registry.discover().first)
        XCTAssertFalse(record.isValid)
        XCTAssertFalse(record.enabled)
        XCTAssertTrue(registry.enabledProviders().isEmpty)
        XCTAssertThrowsError(try registry.setEnabled(true, pluginID: record.id)) { error in
            XCTAssertEqual(error as? ExternalPluginRegistryError, .invalidPackage)
        }
        XCTAssertFalse(try PluginActivationStore(fileURL: activationURL).isEnabled(pluginID: record.id))
    }

    func testInvalidButEnabledPackageCanBeDisabled() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(
            parent: installRoot,
            id: "com.example.damaged",
            includeExecutable: false
        )
        let activationStore = PluginActivationStore(fileURL: activationURL)
        try activationStore.setEnabled(true, pluginID: "com.example.damaged")
        let registry = makeRegistry(root: installRoot, activationURL: activationURL)

        let enabledInvalid = try XCTUnwrap(registry.discover().first)
        XCTAssertFalse(enabledInvalid.isValid)
        XCTAssertTrue(enabledInvalid.enabled)
        XCTAssertTrue(enabledInvalid.canToggle)

        try registry.setEnabled(false, pluginID: "com.example.damaged")

        let disabledInvalid = try XCTUnwrap(registry.discover().first)
        XCTAssertFalse(disabledInvalid.enabled)
        XCTAssertFalse(try activationStore.isEnabled(pluginID: "com.example.damaged"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("plugin.json").path))
    }

    func testDiscoveryResultPreservesCatalogIssuesForDiagnostics() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try makePackage(parent: installRoot, id: "com.example.valid")
        let brokenPackage = installRoot.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenPackage, withIntermediateDirectories: true)

        let result = makeRegistry(root: installRoot, activationURL: activationURL).discoverResult()

        XCTAssertEqual(result.plugins.map(\.id), ["com.example.valid"])
        XCTAssertEqual(result.issues.map(\.kind), [.missingManifest])
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(result.issues.first?.path)).lastPathComponent,
            brokenPackage.lastPathComponent
        )
    }

    func testRegistryInstallRejectsMetadataOnlyPackagesAndLeavesRootUnchanged() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataPackage = try makePackage(
            parent: root,
            id: "com.example.metadata",
            transport: .metadataOnly,
            includeExecutable: false
        )
        let registry = makeRegistry(root: installRoot, activationURL: activationURL)

        XCTAssertThrowsError(try registry.install(from: metadataPackage)) { error in
            XCTAssertEqual(error as? ExternalPluginRegistryError, .unsupportedTransport)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.path))
    }

    func testRequiredPluginConfigurationGatesActivationUntilSaved() throws {
        let root = temporaryDirectory()
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let activationURL = root.appendingPathComponent("activations.json")
        let configurationRoot = root.appendingPathComponent("config", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(
                id: "endpoint",
                label: "Endpoint",
                kind: .url,
                required: true
            ),
            PluginConfigurationField(
                id: "token",
                label: "Token",
                kind: .secret,
                required: true
            )
        ])
        let package = try makePackage(
            parent: root,
            id: "com.example.configured",
            configuration: schema
        )
        _ = try PluginPackageInstaller().install(from: package, into: installRoot)
        let secrets = InMemorySecretStore()
        let registry = makeRegistry(
            root: installRoot,
            activationURL: activationURL,
            configurationRoot: configurationRoot,
            secretStore: secrets
        )

        let initial = try XCTUnwrap(registry.discover().first)
        XCTAssertFalse(initial.isValid)
        XCTAssertNil(initial.validationMessage)
        XCTAssertTrue(initial.configurationValidationMessage?.contains("Required") == true)
        XCTAssertThrowsError(try registry.setEnabled(true, pluginID: initial.id)) { error in
            XCTAssertEqual(error as? ExternalPluginRegistryError, .invalidConfiguration)
        }
        XCTAssertTrue(registry.enabledProviders().isEmpty)

        try registry.saveConfiguration(
            pluginID: initial.id,
            submission: PluginConfigurationSubmission(
                publicValues: ["endpoint": .string("https://example.test")],
                secretValues: ["token": "secret-value"],
                clearSecretIDs: []
            )
        )
        try registry.setEnabled(true, pluginID: initial.id)

        let enabled = try XCTUnwrap(registry.discover().first)
        XCTAssertTrue(enabled.isValid)
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(registry.enabledProviders().map { $0.manifest.id }, [initial.id])
    }

    private func makeRegistry(
        root: URL,
        bundledRoot: URL? = nil,
        activationURL: URL,
        configurationRoot: URL? = nil,
        secretStore: (any PluginSecretStore)? = nil
    ) -> ExternalPluginRegistry {
        ExternalPluginRegistry(
            catalog: PluginCatalog(rootURL: root, bundledRootURL: bundledRoot),
            activationStore: PluginActivationStore(fileURL: activationURL),
            configurationStore: PluginConfigurationStore(
                baseURL: configurationRoot ?? root.appendingPathComponent("config", isDirectory: true),
                secretStore: secretStore ?? InMemorySecretStore()
            )
        )
    }

    private func makePackage(
        parent: URL,
        id: String,
        transport: PluginTransportKind = .stdioJSON,
        includeExecutable: Bool = true,
        configuration: PluginConfigurationSchema? = nil
    ) throws -> URL {
        let package = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            manifestVersion: 1,
            id: id,
            displayName: id,
            version: "1.0.0",
            protocolVersion: 1,
            transport: transport,
            entrypoint: transport == .stdioJSON ? "bin/dashboard-plugin" : nil,
            configuration: configuration
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))
        if includeExecutable {
            let executable = package.appendingPathComponent("bin/dashboard-plugin")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return package
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.ExternalPluginRegistryTests.\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private final class InMemorySecretStore: PluginSecretStore, @unchecked Sendable {
        private var values = [String: Data]()

        func read(service: String, account: String) throws -> Data? {
            values["\(service):\(account)"]
        }

        func write(_ data: Data, service: String, account: String) throws {
            values["\(service):\(account)"] = data
        }

        func delete(service: String, account: String) throws {
            values.removeValue(forKey: "\(service):\(account)")
        }
    }
}
