import Foundation
import XCTest
@testable import MeterlarkApp

final class SourceChangeWatcherTests: XCTestCase {
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
