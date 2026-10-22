import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginPackageTests: XCTestCase {
    func testMetadataOnlyPackageCanBeValidatedWithoutAnExecutable() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(
            parent: root,
            id: "com.example.metadata",
            transport: .metadataOnly,
            includeExecutable: false
        )

        let result = try PluginPackageValidator().validate(packageURL: package)

        XCTAssertEqual(result.manifest.id, "com.example.metadata")
        XCTAssertEqual(result.manifest.transport, .metadataOnly)
    }

    func testValidatorRejectsSymlinksAtAnyDepth() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let package = try makePackage(
            parent: root,
            id: "com.example.external",
            transport: .stdioJSON
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let target = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: target)
        let nestedLink = package.appendingPathComponent("resources/secret.txt")
        try FileManager.default.createDirectory(
            at: nestedLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: target)

        XCTAssertThrowsError(try PluginPackageValidator().validate(packageURL: package)) { error in
            guard case let .symbolicLink(path) = error as? PluginPackageValidationError else {
                return XCTFail("Expected a symbolic-link validation error, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("/resources/secret.txt"))
        }
    }

    func testExternalPackageRequiresARegularExecutableEntrypoint() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(
            parent: root,
            id: "com.example.external",
            transport: .stdioJSON,
            includeExecutable: false
        )

        XCTAssertThrowsError(try PluginPackageValidator().validate(packageURL: package)) { error in
            XCTAssertEqual(error as? PluginPackageValidationError, .entrypointMissing)
        }

        let nonExecutable = package.appendingPathComponent("bin/dashboard-plugin")
        try FileManager.default.createDirectory(
            at: nonExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not executable".utf8).write(to: nonExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: nonExecutable.path
        )
        XCTAssertThrowsError(try PluginPackageValidator().validate(packageURL: package)) { error in
            XCTAssertEqual(error as? PluginPackageValidationError, .entrypointNotExecutable)
        }
    }

    func testValidatorRejectsAnOversizedManifestBeforeDecoding() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makePackage(
            parent: root,
            id: "com.example.large",
            transport: .metadataOnly,
            includeExecutable: false
        )
        let oversized = Data(repeating: 0x20, count: PluginManifestLoader.maximumManifestBytes + 1)
        try oversized.write(to: package.appendingPathComponent("plugin.json"))

        XCTAssertThrowsError(try PluginPackageValidator().validate(packageURL: package)) { error in
            XCTAssertEqual(error as? PluginPackageValidationError, .manifestTooLarge)
        }
    }

    func testInstallerStagesAndReplacesAnExistingPackage() throws {
        let sourceRoot = temporaryDirectory()
        let installRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: installRoot)
        }

        let first = try makePackage(
            parent: sourceRoot,
            id: "com.example.external",
            version: "1.0.0",
            marker: "first"
        )
        let installer = PluginPackageInstaller()
        let installed = try installer.install(from: first, into: installRoot)
        let destination = installRoot.appendingPathComponent("com.example.external", isDirectory: true)
        XCTAssertEqual(installed.packageURL, destination)
        XCTAssertEqual(
            try PluginPackageValidator().validate(packageURL: destination).manifest.version,
            "1.0.0"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("bin/dashboard-plugin")),
            "first"
        )

        let second = try makePackage(
            parent: sourceRoot,
            id: "com.example.external.updated",
            version: "2.0.0",
            marker: "second"
        )
        let updated = try installer.install(from: second, into: installRoot)
        XCTAssertEqual(
            updated.packageURL,
            installRoot.appendingPathComponent("com.example.external.updated", isDirectory: true)
        )

        let replacement = try makePackage(
            parent: sourceRoot,
            id: "com.example.external",
            version: "1.1.0",
            marker: "replacement"
        )
        try installer.install(from: replacement, into: installRoot)
        XCTAssertEqual(
            try PluginPackageValidator().validate(packageURL: destination).manifest.version,
            "1.1.0"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("bin/dashboard-plugin")),
            "replacement"
        )

        let invalid = try makePackage(
            parent: sourceRoot,
            id: "com.example.external",
            version: "9.9.9",
            marker: "invalid"
        )
        let outside = sourceRoot.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = invalid.appendingPathComponent("resources/outside.txt")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try installer.install(from: invalid, into: installRoot))
        XCTAssertEqual(
            try PluginPackageValidator().validate(packageURL: destination).manifest.version,
            "1.1.0",
            "An invalid update must not replace the existing package"
        )
    }

    func testInstallerDoesNotExecuteTheEntrypoint() throws {
        let sourceRoot = temporaryDirectory()
        let installRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: installRoot)
        }
        let package = try makePackage(
            parent: sourceRoot,
            id: "com.example.external",
            transport: .stdioJSON,
            marker: "#!/bin/sh\ntouch \"\(sourceRoot.path)/executed\"\n"
        )

        _ = try PluginPackageInstaller().install(from: package, into: installRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("executed").path))
    }

    private func makePackage(
        parent: URL,
        id: String,
        transport: PluginTransportKind = .stdioJSON,
        version: String = "1.0.0",
        includeExecutable: Bool = true,
        marker: String = "placeholder"
    ) throws -> URL {
        let package = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            manifestVersion: 1,
            id: id,
            displayName: id,
            version: version,
            protocolVersion: 1,
            transport: transport,
            entrypoint: transport == .stdioJSON ? "bin/dashboard-plugin" : nil
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))

        if includeExecutable {
            let executable = package.appendingPathComponent("bin/dashboard-plugin")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(marker.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return package
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginPackageTests.\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
