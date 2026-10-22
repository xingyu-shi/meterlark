import XCTest
@testable import MeterlarkApp

final class CCUsageRunnerTimeoutTests: XCTestCase {
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
