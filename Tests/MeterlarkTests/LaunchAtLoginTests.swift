import XCTest
@testable import MeterlarkApp

final class LaunchAtLoginTests: XCTestCase {
    func testEnablingRequestsRegistrationOnlyWhenNotRegistered() {
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: true, status: .notRegistered),
            .register
        )
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: true, status: .enabled),
            .none
        )
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: true, status: .requiresApproval),
            .none
        )
    }

    func testDisablingUnregistersRegisteredStatesOnly() {
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: false, status: .enabled),
            .unregister
        )
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: false, status: .requiresApproval),
            .unregister
        )
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: false, status: .notRegistered),
            .none
        )
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: false, status: .notFound),
            .none
        )
    }

    func testNotFoundCannotBeEnabled() {
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: true, status: .notFound),
            .unavailable
        )
    }
}
