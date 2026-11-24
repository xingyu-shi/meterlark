import XCTest
@testable import MeterlarkApp

final class CCUsageRunnerTimeoutTests: XCTestCase {
    func testRunnerDisablesCcusageTelemetryInChildEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-telemetry-opt-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("ccusage.sh")
        let markerURL = root.appendingPathComponent("telemetry-state.txt")
        let script = """
        #!/bin/sh
        printf '%s' "${CCUSAGE_TELEMETRY_DISABLED-unset}" > '\(markerURL.path)'
        printf '{}'
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        _ = try CCUsageRunner(bundledExecutableURL: scriptURL).run(
            settings: .default,
            mode: .onlinePricing,
            previousPricingDate: nil
        )

        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "1")
    }

    func testTimeoutKillsBlockingBundledRunnerAndReturnsPromptly() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-timeout-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let started = Date()
        XCTAssertThrowsError(
            try CCUsageRunner(timeout: 0.1, bundledExecutableURL: scriptURL).run(
                settings: .default,
                mode: .usage,
                previousPricingDate: nil
            )
        ) { error in
            guard case .timedOut = error as? CCUsageRunnerError else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testExitedRunnerCannotHoldRefreshOpenThroughDescendantPipes() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-descendant-pipe-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n(sleep 5) &\nexit 0\n".utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let started = Date()
        XCTAssertThrowsError(
            try CCUsageRunner(timeout: 10, bundledExecutableURL: scriptURL).run(
                settings: .default,
                mode: .usage,
                previousPricingDate: nil
            )
        ) { error in
            guard case .timedOut = error as? CCUsageRunnerError else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
