import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
    var isEnabled: Bool { self == .enabled }
}

enum LaunchAtLoginOperation: Equatable, Sendable {
    case none
    case register
    case unregister
}

enum LaunchAtLoginError: LocalizedError, Equatable {
    case registrationDidNotStick
    case unregistrationDidNotStick

    var errorDescription: String? {
        switch self {
        case .registrationDidNotStick:
            return "macOS did not register the app as a login item."
        case .unregistrationDidNotStick:
            return "macOS did not remove the app as a login item."
        }
    }
}

enum LaunchAtLoginService {
    static func currentStatus() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    static func operation(for enabled: Bool, status: LaunchAtLoginStatus) -> LaunchAtLoginOperation {
        if enabled {
            switch status {
            case .notRegistered, .notFound:
                return .register
            case .enabled, .requiresApproval:
                return .none
            }
        }

        switch status {
        case .enabled, .requiresApproval:
            return .unregister
        case .notRegistered, .notFound:
            return .none
        }
    }

    static func setEnabled(
        _ enabled: Bool,
        readStatus: () -> LaunchAtLoginStatus = { currentStatus() },
        register: () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) throws -> LaunchAtLoginStatus {
        let status = readStatus()

        switch operation(for: enabled, status: status) {
        case .none:
            return status
        case .register:
            try register()
        case .unregister:
            try unregister()
        }

        let resultingStatus = readStatus()
        if enabled != resultingStatus.isRegistered {
            throw enabled
                ? LaunchAtLoginError.registrationDidNotStick
                : LaunchAtLoginError.unregistrationDidNotStick
        }
        return resultingStatus
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
