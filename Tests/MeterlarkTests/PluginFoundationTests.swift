import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginFoundationTests: XCTestCase {
    func testManifestValidationAcceptsStableIdentityAndOpaqueVersion() throws {
        let manifest = try decodeManifest("""
        {
          "manifestVersion": 1,
          "id": "com.example.example-gateway",
          "displayName": "ExampleGateway",
          "version": "2026.08-preview",
          "protocolVersion": 1
        }
        """)

        XCTAssertEqual(manifest.id, "com.example.example-gateway")
        XCTAssertEqual(manifest.version, "2026.08-preview")
        XCTAssertNoThrow(try manifest.validate())
    }

    func testManifestValidationRejectsUnsupportedVersionsAndUnsafeFields() throws {
        let unsupportedManifest = try decodeManifest(manifestJSON(manifestVersion: 2))
        XCTAssertThrowsError(try unsupportedManifest.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .unsupportedManifestVersion(2))
        }

        let unsupportedProtocol = try decodeManifest(manifestJSON(protocolVersion: 3))
        XCTAssertThrowsError(try unsupportedProtocol.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .unsupportedProtocolVersion(3))
        }

        for identifier in ["../example-gateway", ".", "..", "com..example"] {
            let unsafeIdentifier = try decodeManifest(manifestJSON(id: identifier))
            XCTAssertThrowsError(try unsafeIdentifier.validate()) { error in
                XCTAssertEqual(error as? PluginManifestValidationError, .invalidIdentifier)
            }
        }

        let emptyDisplayName = try decodeManifest(manifestJSON(displayName: ""))
        XCTAssertThrowsError(try emptyDisplayName.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .invalidDisplayName)
        }

        let spacedVersion = try decodeManifest(manifestJSON(version: "1.0 beta"))
        XCTAssertThrowsError(try spacedVersion.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .invalidVersion)
        }
    }

    func testManifestTransportDefaultsToMetadataAndValidatesStdioEntrypoints() throws {
        let legacy = try decodeManifest(manifestJSON())
        XCTAssertEqual(legacy.transport, .metadataOnly)
        XCTAssertNil(legacy.entrypoint)
        XCTAssertNoThrow(try legacy.validate())

        let external = try decodeManifest("""
        {
          "manifestVersion": 1,
          "id": "com.example.external",
          "displayName": "External",
          "version": "1.0.0",
          "protocolVersion": 1,
          "transport": "stdio-json",
          "entrypoint": "bin/dashboard-plugin"
        }
        """)
        XCTAssertEqual(external.transport, .stdioJSON)
        XCTAssertEqual(external.entrypoint, "bin/dashboard-plugin")
        XCTAssertNoThrow(try external.validate())

        for entrypoint in ["/tmp/plugin", "../plugin", "bin/../plugin", "bin/./plugin", "~/plugin"] {
            let manifest = PluginManifest(
                manifestVersion: 1,
                id: "com.example.external",
                displayName: "External",
                version: "1.0.0",
                protocolVersion: 1,
                transport: .stdioJSON,
                entrypoint: entrypoint
            )
            XCTAssertThrowsError(try manifest.validate()) { error in
                XCTAssertEqual(error as? PluginManifestValidationError, .invalidEntrypoint)
            }
        }

        let missingEntrypoint = PluginManifest(
            manifestVersion: 1,
            id: "com.example.external",
            displayName: "External",
            version: "1.0.0",
            protocolVersion: 1,
            transport: .stdioJSON
        )
        XCTAssertThrowsError(try missingEntrypoint.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .missingEntrypoint)
        }

        let unexpectedEntrypoint = PluginManifest(
            manifestVersion: 1,
            id: "com.example.metadata",
            displayName: "Metadata",
            version: "1.0.0",
            protocolVersion: 1,
            entrypoint: "bin/plugin"
        )
        XCTAssertThrowsError(try unexpectedEntrypoint.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .unexpectedEntrypoint)
        }
    }

    func testManifestRoundTripsOptionalDeclarativeConfigurationSchema() throws {
        let schema = PluginConfigurationSchema(
            title: "Account",
            fields: [
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
            ]
        )
        let manifest = PluginManifest(
            manifestVersion: 1,
            id: "com.example.configured",
            displayName: "Configured",
            version: "1.0.0",
            protocolVersion: 1,
            transport: .stdioJSON,
            entrypoint: "bin/plugin",
            configuration: schema
        )

        let decoded = try JSONDecoder().decode(
            PluginManifest.self,
            from: try JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testMissingPluginRootIsAnEmptyInstallationState() {
        let root = temporaryDirectory().appendingPathComponent("missing", isDirectory: true)
        let result = PluginCatalog(rootURL: root).discover()

        XCTAssertTrue(result.plugins.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testDiscoveryReturnsValidPluginsInIDOrderAndReportsInvalidPackages() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeManifest(manifestJSON(id: "com.example.zeta"), packageID: "zeta", root: root)
        try writeManifest(manifestJSON(id: "com.example.alpha"), packageID: "alpha", root: root)
        try makePackage(packageID: "missing", root: root)
        try makePackage(packageID: "broken", root: root)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("broken/plugin.json"))

        let result = PluginCatalog(rootURL: root).discover()

        XCTAssertEqual(result.plugins.map(\.id), ["com.example.alpha", "com.example.zeta"])
        XCTAssertEqual(
            result.issues.map(\.kind),
            [.unreadableManifest, .missingManifest]
        )
    }

    func testDiscoveryExcludesEveryPackageWithDuplicateID() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeManifest(manifestJSON(id: "com.example.same"), packageID: "first", root: root)
        try writeManifest(manifestJSON(id: "com.example.same"), packageID: "second", root: root)

        let result = PluginCatalog(rootURL: root).discover()

        XCTAssertTrue(result.plugins.isEmpty)
        XCTAssertEqual(result.issues.filter { $0.kind == .duplicateIdentifier }.count, 2)
    }

    func testDiscoveryIncludesBundledPackagesAndPrefersUserUpdates() throws {
        let root = temporaryDirectory()
        let bundledRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: bundledRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)

        let bundledOnly = try writeManifest(
            manifestJSON(id: "com.example.bundled"),
            packageID: "bundled",
            root: bundledRoot
        )
        let bundledVersion = try writeManifest(
            manifestJSON(id: "com.example.updated", version: "1.0.0"),
            packageID: "updated",
            root: bundledRoot
        )
        let userVersion = try writeManifest(
            manifestJSON(id: "com.example.updated", version: "2.0.0"),
            packageID: "updated",
            root: root
        )

        let result = PluginCatalog(rootURL: root, bundledRootURL: bundledRoot).discover()

        XCTAssertEqual(result.plugins.map(\.id), ["com.example.bundled", "com.example.updated"])
        XCTAssertEqual(result.plugins.first?.manifest.version, "1.0.0")
        XCTAssertEqual(result.plugins.first?.packageURL.lastPathComponent, bundledOnly.lastPathComponent)
        XCTAssertEqual(result.plugins.last?.manifest.version, "2.0.0")
        XCTAssertEqual(result.plugins.last?.packageURL.lastPathComponent, userVersion.lastPathComponent)
        XCTAssertNotEqual(userVersion, bundledVersion)
    }

    func testDiscoveryRejectsSymlinkedPackageAndManifest() throws {
        let root = temporaryDirectory()
        let target = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeManifest(manifestJSON(id: "com.example.target"), packageID: "target", root: target)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("package-link"),
            withDestinationURL: target.appendingPathComponent("target")
        )

        let regularPackage = root.appendingPathComponent("manifest-link", isDirectory: true)
        try FileManager.default.createDirectory(at: regularPackage, withIntermediateDirectories: true)
        let externalManifest = target.appendingPathComponent("target/plugin.json")
        try FileManager.default.createSymbolicLink(
            at: regularPackage.appendingPathComponent("plugin.json"),
            withDestinationURL: externalManifest
        )

        let result = PluginCatalog(rootURL: root).discover()

        XCTAssertTrue(result.plugins.isEmpty)
        XCTAssertEqual(result.issues.filter { $0.kind == .symbolicLink }.count, 2)
    }

    private func decodeManifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func manifestJSON(
        manifestVersion: Int = 1,
        id: String = "com.example.plugin",
        displayName: String = "Example",
        version: String = "1.0.0",
        protocolVersion: Int = 1
    ) -> String {
        """
        {
          "manifestVersion": \(manifestVersion),
          "id": "\(id)",
          "displayName": "\(displayName)",
          "version": "\(version)",
          "protocolVersion": \(protocolVersion)
        }
        """
    }

    @discardableResult
    private func writeManifest(_ json: String, packageID: String, root: URL) throws -> URL {
        let package = try makePackage(packageID: packageID, root: root)
        try Data(json.utf8).write(to: package.appendingPathComponent("plugin.json"))
        return package
    }

    @discardableResult
    private func makePackage(packageID: String, root: URL) throws -> URL {
        let package = root.appendingPathComponent(packageID, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginFoundationTests.\(UUID().uuidString)", isDirectory: true)
    }
}
