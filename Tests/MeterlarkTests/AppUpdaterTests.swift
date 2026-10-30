import XCTest
@testable import MeterlarkApp

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testUnconfiguredTestHostDoesNotStartAnUpdater() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        let updater = AppUpdater()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertNil(updater.availableVersion)
    }
}
