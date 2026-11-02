import XCTest
import UniformTypeIdentifiers
@testable import MeterlarkApp

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    func testDraggedIconProvidesTheAppFileURL() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Meterlark.app", isDirectory: true)
        let item = LoginItemSetupView.dragItem(for: appURL)
        XCTAssertTrue(item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let loaded: NSURL = try await withCheckedThrowingContinuation { continuation in
            _ = item.loadObject(ofClass: NSURL.self) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = value as? NSURL {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
        XCTAssertEqual(loaded as URL, appURL)
    }

    func testPendingApprovalDoesNotAppearEnabled() {
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.isRegistered)
        XCTAssertFalse(LaunchAtLoginStatus.requiresApproval.isEnabled)
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.notFound.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.notRegistered.isEnabled)
    }

    func testInstallerCannotEnableLoginEvenWhenAnOldEntryIsEnabled() {
        for status: LaunchAtLoginStatus in [.notRegistered, .notFound, .enabled, .requiresApproval] {
            XCTAssertThrowsError(try LaunchAtLoginService.setEnabled(
                true,
                readStatus: { status },
                register: { XCTFail("An installer must not be registered") },
                unregister: { XCTFail("Enabling must not unregister") },
                isOnReadOnlyVolume: { true }
            )) { error in
                XCTAssertEqual(error as? LaunchAtLoginError, .appOnReadOnlyVolume)
            }
        }
    }

    func testInstallerStatusDoesNotQueryTheSystemWithItsBundleIdentity() {
        let status = LaunchAtLoginService.currentStatus(
            isOnReadOnlyVolume: { true },
            readSystemStatus: {
                XCTFail("The installer must not query Service Management")
                return .enabled
            }
        )
        XCTAssertEqual(status, .notFound)
    }

    func testWritableAppReadsTheSystemLoginStatus() {
        var readCount = 0
        let status = LaunchAtLoginService.currentStatus(
            isOnReadOnlyVolume: { false },
            readSystemStatus: { readCount += 1; return .enabled }
        )
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(status, .enabled)
    }

    func testInstallerCanStillDisableAnOldLoginEntry() throws {
        var status = LaunchAtLoginStatus.enabled
        var unregistrationCount = 0
        let result = try LaunchAtLoginService.setEnabled(
            false,
            readStatus: { status },
            register: { XCTFail("Disabling must not register") },
            unregister: { unregistrationCount += 1; status = .notRegistered },
            isOnReadOnlyVolume: { true }
        )
        XCTAssertEqual(unregistrationCount, 1)
        XCTAssertEqual(result, .notRegistered)
    }

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

    func testNotFoundRequestsFirstRegistration() {
        XCTAssertEqual(
            LaunchAtLoginService.operation(for: true, status: .notFound),
            .register
        )
    }

    func testFirstRegistrationReadsEnabledOrPendingSystemState() throws {
        for outcome: LaunchAtLoginStatus in [.enabled, .requiresApproval] {
            var status = LaunchAtLoginStatus.notFound
            var registrationCount = 0
            let result = try LaunchAtLoginService.setEnabled(
                true,
                readStatus: { status },
                register: { registrationCount += 1; status = outcome },
                unregister: { XCTFail("Enabling must not unregister") }
            )
            XCTAssertEqual(registrationCount, 1)
            XCTAssertEqual(result, outcome)
            XCTAssertTrue(result.isRegistered)
        }
    }

    func testRegistrationThatLeavesNoSystemEntryFails() {
        for status: LaunchAtLoginStatus in [.notFound, .notRegistered] {
            var registrationCount = 0
            XCTAssertThrowsError(try LaunchAtLoginService.setEnabled(
                true,
                readStatus: { status },
                register: { registrationCount += 1 },
                unregister: { XCTFail("Enabling must not unregister") }
            )) { error in
                XCTAssertEqual(error as? LaunchAtLoginError, .registrationDidNotStick)
            }
            XCTAssertEqual(registrationCount, 1)
        }
    }

    func testDisablingRemovesEnabledAndPendingRegistrations() throws {
        for initial: LaunchAtLoginStatus in [.enabled, .requiresApproval] {
            var status = initial
            var unregistrationCount = 0
            let result = try LaunchAtLoginService.setEnabled(
                false,
                readStatus: { status },
                register: { XCTFail("Disabling must not register") },
                unregister: { unregistrationCount += 1; status = .notRegistered }
            )
            XCTAssertEqual(unregistrationCount, 1)
            XCTAssertFalse(result.isRegistered)
        }
    }

    func testUnregistrationThatLeavesTheEntryEnabledFails() {
        XCTAssertThrowsError(try LaunchAtLoginService.setEnabled(
            false,
            readStatus: { .enabled },
            register: { XCTFail("Disabling must not register") },
            unregister: {}
        )) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .unregistrationDidNotStick)
        }
    }
}
