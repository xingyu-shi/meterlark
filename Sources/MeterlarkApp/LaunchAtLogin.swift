import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LaunchAtLoginOperation: Equatable, Sendable {
    case none
    case register
    case unregister
    case unavailable
}

enum LaunchAtLoginError: LocalizedError {
    case serviceNotFound
    case registrationDidNotStick

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "The app is not available as a macOS login item."
        case .registrationDidNotStick:
            return "macOS did not register the app as a login item."
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
            case .notRegistered:
                return .register
            case .enabled, .requiresApproval:
                return .none
            case .notFound:
                return .unavailable
            }
        }

        switch status {
        case .enabled, .requiresApproval:
            return .unregister
        case .notRegistered, .notFound:
            return .none
        }
    }

    static func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        let service = SMAppService.mainApp
        let status = currentStatus()

        switch operation(for: enabled, status: status) {
        case .none:
            return status
        case .register:
            try service.register()
        case .unregister:
            try service.unregister()
        case .unavailable:
            throw LaunchAtLoginError.serviceNotFound
        }

        let resultingStatus = currentStatus()
        if enabled, resultingStatus == .notRegistered {
            throw LaunchAtLoginError.registrationDidNotStick
        }
        return resultingStatus
    }
}
