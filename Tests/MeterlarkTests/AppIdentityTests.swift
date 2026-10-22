import Foundation
import XCTest
@testable import MeterlarkApp

final class AppIdentityTests: XCTestCase {
    func testPackagedIdentityMatchesPersistenceIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Meterlark")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Meterlark")
    }
}
