import Foundation
import XCTest
@testable import MeterlarkApp

final class SourceChangeWatcherTests: XCTestCase {
    func testSourceRootsUseCodexHomeInsteadOfTheDefaultDirectory() {
        let home = URL(fileURLWithPath: "/tmp/meterlark-test-home", isDirectory: true)
        let customHome = URL(fileURLWithPath: "/tmp/meterlark-other-codex", isDirectory: true)
        let roots = SourceFingerprintReader.sourceRoots(
            home: home,
            environment: ["CODEX_HOME": customHome.path]
        )
        XCTAssertTrue(roots.contains(customHome.appendingPathComponent("sessions", isDirectory: true)))
        XCTAssertFalse(roots.contains(home.appendingPathComponent(".codex/sessions", isDirectory: true)))
        XCTAssertTrue(roots.contains(home.appendingPathComponent(".claude/projects", isDirectory: true)))
    }

    func testSourceRootsFallBackWhenCodexHomeIsMissingOrEmpty() {
        let home = URL(fileURLWithPath: "/tmp/meterlark-test-home", isDirectory: true)
        let expected = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        for environment in [[:], ["CODEX_HOME": ""]] {
            XCTAssertTrue(SourceFingerprintReader.sourceRoots(home: home, environment: environment).contains(expected))
        }
    }

    func testFSEventsDeliversCallbackForAppendToExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.SourceChangeWatcherTests.\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("existing-session.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: session)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let callback = expectation(description: "FSEvents callback for an existing file append")
        let watcher = SourceChangeWatcher(paths: [root]) {
            callback.fulfill()
        }
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended\n".utf8))
        try handle.synchronize()
        try handle.close()

        wait(for: [callback], timeout: 5)
    }

    func testFSEventsDeliversCallbackForAppendUnderHiddenDirectory() throws {
        let hiddenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(".Meterlark.SourceChangeWatcherTests.\(UUID().uuidString)", isDirectory: true)
        let root = hiddenRoot.appendingPathComponent("nested", isDirectory: true)
        let session = root.appendingPathComponent("existing-session.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: session)
        addTeardownBlock { try? FileManager.default.removeItem(at: hiddenRoot) }

        let callback = expectation(description: "FSEvents callback under a hidden directory")
        let watcher = SourceChangeWatcher(paths: [root]) {
            callback.fulfill()
        }
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended\n".utf8))
        try handle.close()

        wait(for: [callback], timeout: 5)
    }

}
