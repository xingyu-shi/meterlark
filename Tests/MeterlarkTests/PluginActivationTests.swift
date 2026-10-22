import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginActivationTests: XCTestCase {
    func testActivationDefaultsToDisabledAndIsIsolatedPerPlugin() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PluginActivationStore(fileURL: fileURL)

        XCTAssertFalse(try store.isEnabled(pluginID: "com.example.one"))
        XCTAssertFalse(try store.isEnabled(pluginID: "com.example.two"))

        try store.setEnabled(true, pluginID: "com.example.one")
        XCTAssertTrue(try store.isEnabled(pluginID: "com.example.one"))
        XCTAssertFalse(try store.isEnabled(pluginID: "com.example.two"))

        try store.setEnabled(false, pluginID: "com.example.one")
        XCTAssertFalse(try store.isEnabled(pluginID: "com.example.one"))
    }

    func testActivationStateRoundTripsAtomicallyAndCanRemoveEntries() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PluginActivationStore(fileURL: fileURL)

        try store.setEnabled(true, pluginID: "com.example.one")
        try store.setEnabled(true, pluginID: "com.example.two")
        XCTAssertEqual(
            try store.load(),
            ["com.example.one": true, "com.example.two": true]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try store.remove(pluginID: "com.example.one")
        XCTAssertNil(try store.load()["com.example.one"])
        XCTAssertTrue(try store.isEnabled(pluginID: "com.example.two"))
    }

    func testInvalidIdentifiersAndCorruptStateAreRejected() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PluginActivationStore(fileURL: fileURL)

        for pluginID in ["", "../escape", "com.example/other"] {
            XCTAssertThrowsError(try store.setEnabled(true, pluginID: pluginID)) { error in
                XCTAssertEqual(error as? PluginActivationError, .invalidPluginIdentifier)
            }
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PluginActivationError, .invalidState)
        }
    }

    func testSymlinkedStateIsRejected() throws {
        let root = fileURLRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        let state = root.appendingPathComponent("PluginActivations.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)

        let store = PluginActivationStore(fileURL: state)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PluginActivationError, .symbolicLink)
        }
    }

    private func temporaryFileURL() -> URL {
        fileURLRoot().appendingPathComponent("PluginActivations.json")
    }

    private func fileURLRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginActivationTests.\(UUID().uuidString)", isDirectory: true)
    }
}
