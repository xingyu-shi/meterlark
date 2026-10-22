import Foundation
import XCTest
@testable import MeterlarkApp

final class ExternalPluginTransportTests: XCTestCase {
    func testValidRequestAndResponseRoundTripThroughProvider() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let manifest = package.manifest
        let document = readyDocument(for: manifest.id)
        let runner = StubRunner(output: try JSONEncoder().encode(document))
        let provider = try StdioJSONPluginProvider(
            manifest: manifest,
            packageURL: package.root,
            configurationData: Data("{\"endpoint\":\"https://example.test\"}".utf8),
            runner: runner
        )

        let received = try await provider.fetchDashboard()

        XCTAssertEqual(received, document)
        let recordedRequest = await runner.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.last, 0x0A)
        let requestWithoutNewline = request.dropLast()
        let envelope = try JSONDecoder().decode(
            ExternalPluginRequest.self,
            from: Data(requestWithoutNewline)
        )
        XCTAssertEqual(envelope.pluginID, manifest.id)
        guard case let .object(configuration)? = envelope.configuration else {
            return XCTFail("Expected a JSON object configuration")
        }
        XCTAssertEqual(configuration["endpoint"], .string("https://example.test"))
    }

    func testMalformedJSONIsRejectedBeforeItReachesTheDashboardLoader() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }
        let runner = StubRunner(output: Data("not-json".utf8))
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            runner: runner
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected malformed JSON to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .invalidJSON)
        }
    }

    func testNonZeroExitIsRejected() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }
        let runner = StubRunner(status: 17, output: Data())
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            runner: runner
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected non-zero exit to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .nonZeroExit(17))
        }
    }

    func testTimeoutAndOutputLimitRemainSafeProviderErrors() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let timeoutProvider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            runner: StubRunner(error: .timeout)
        )
        do {
            _ = try await timeoutProvider.fetchDashboard()
            XCTFail("Expected timeout to be surfaced")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .timeout)
        }

        let outputLimitProvider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            runner: StubRunner(error: .outputTooLarge)
        )
        do {
            _ = try await outputLimitProvider.fetchDashboard()
            XCTFail("Expected output limit to be surfaced")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .outputTooLarge)
        }
    }

    func testInvalidUTF8AndInvalidConfigurationAreRejected() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let invalidUTF8Provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            runner: StubRunner(output: Data([0xFF]))
        )
        do {
            _ = try await invalidUTF8Provider.fetchDashboard()
            XCTFail("Expected invalid UTF-8 to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .invalidUTF8)
        }

        let invalidConfigurationProvider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            configurationData: Data("[1,2,3]".utf8),
            runner: StubRunner(output: Data())
        )
        do {
            _ = try await invalidConfigurationProvider.fetchDashboard()
            XCTFail("Expected non-object configuration to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .invalidConfiguration)
        }
    }

    func testUnsafeOrSymlinkedEntrypointsCannotConstructProvider() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let unsafeManifest = PluginManifest(
            manifestVersion: 1,
            id: "com.example.external",
            displayName: "External",
            version: "1.0.0",
            protocolVersion: 1,
            transport: .stdioJSON,
            entrypoint: "../plugin"
        )
        XCTAssertThrowsError(
            try StdioJSONPluginProvider(
                manifest: unsafeManifest,
                packageURL: package.root,
                runner: StubRunner(output: Data())
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .invalidEntrypoint)
        }

        let symlink = package.root.appendingPathComponent("bin/symlink")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: package.executable
        )
        let symlinkManifest = PluginManifest(
            manifestVersion: 1,
            id: "com.example.external",
            displayName: "External",
            version: "1.0.0",
            protocolVersion: 1,
            transport: .stdioJSON,
            entrypoint: "bin/symlink"
        )
        XCTAssertThrowsError(
            try StdioJSONPluginProvider(
                manifest: symlinkManifest,
                packageURL: package.root,
                runner: StubRunner(output: Data())
            )
        ) { error in
            XCTAssertEqual(error as? ExternalPluginTransportError, .invalidEntrypoint)
        }
    }

    func testOversizedConfigurationIsRejectedBeforeLaunchingRunner() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package.root) }
        let oversized = Data(
            ("{\"value\":\"" + String(repeating: "x", count: 70_000) + "\"}").utf8
        )
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            configurationData: oversized,
            runner: StubRunner(output: Data())
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected oversized request to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .requestTooLarge)
        }
    }

    func testSystemRunnerExecutesOneShotJSONProcess() async throws {
        let package = try makePackage(executableContents: """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"protocolVersion":1,"pluginID":"com.example.external","lifecycle":{"kind":"ready"},"blocks":[]}'
        """)
        defer { try? FileManager.default.removeItem(at: package.root) }
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root
        )

        let document = try await provider.fetchDashboard()

        XCTAssertEqual(document, readyDocument(for: package.manifest.id))
    }

    func testSystemRunnerTerminatesAPluginThatExceedsTheTimeout() async throws {
        let package = try makePackage(executableContents: """
        #!/bin/sh
        sleep 5
        """)
        defer { try? FileManager.default.removeItem(at: package.root) }
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root,
            timeout: 0.1
        )
        let started = Date()

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected the plugin process to time out")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testSystemRunnerEnforcesTheOutputLimit() async throws {
        let package = try makePackage(executableContents: """
        #!/bin/sh
        head -c 600000 /dev/zero
        """)
        defer { try? FileManager.default.removeItem(at: package.root) }
        let provider = try StdioJSONPluginProvider(
            manifest: package.manifest,
            packageURL: package.root
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected oversized plugin output to be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalPluginTransportError, .outputTooLarge)
        }
    }

    private struct PackageFixture {
        let root: URL
        let executable: URL
        let manifest: PluginManifest
    }

    private func makePackage(executableContents: String = "placeholder") throws -> PackageFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.ExternalPluginTransportTests.\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("bin/dashboard-plugin")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(executableContents.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let manifest = PluginManifest(
            manifestVersion: 1,
            id: "com.example.external",
            displayName: "External",
            version: "1.0.0",
            protocolVersion: 1,
            transport: .stdioJSON,
            entrypoint: "bin/dashboard-plugin"
        )
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("plugin.json"))
        return PackageFixture(root: root, executable: executable, manifest: manifest)
    }

    private func readyDocument(for pluginID: String) -> PluginDashboardDocument {
        PluginDashboardDocument(
            protocolVersion: 1,
            pluginID: pluginID,
            lifecycle: PluginLifecyclePayload(kind: .ready, message: nil),
            blocks: []
        )
    }

    private actor StubRunner: ExternalPluginProcessRunner {
        let status: Int32
        let output: Data
        let error: ExternalPluginTransportError?
        private(set) var requests = [Data]()

        init(
            status: Int32 = 0,
            output: Data,
            error: ExternalPluginTransportError? = nil
        ) {
            self.status = status
            self.output = output
            self.error = error
        }

        init(error: ExternalPluginTransportError) {
            status = 0
            output = Data()
            self.error = error
        }

        var lastRequest: Data? { requests.last }

        func run(
            executableURL: URL,
            packageURL: URL,
            request: Data,
            timeout: TimeInterval,
            maximumOutputBytes: Int
        ) async throws -> ExternalPluginProcessResult {
            requests.append(request)
            if let error { throw error }
            return ExternalPluginProcessResult(stdout: output, terminationStatus: status)
        }
    }
}
