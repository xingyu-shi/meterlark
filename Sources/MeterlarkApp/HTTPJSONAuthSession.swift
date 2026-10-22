import Foundation

typealias HTTPJSONRequestSender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum HTTPJSONAuthSessionError: Error, Equatable, Sendable {
    case missingRefreshCredential
    case invalidResponse
    case reconfigurationRequired
    case permissionDenied
    case transient
    case rateLimited
    case backoff
    case superseded
    case credentialPersistenceFailed
}

extension HTTPJSONAuthSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingRefreshCredential:
            return "The plugin refresh credential is not configured."
        case .invalidResponse:
            return "The plugin token endpoint returned an invalid response."
        case .reconfigurationRequired, .credentialPersistenceFailed:
            return "The plugin credentials need to be updated."
        case .permissionDenied:
            return "The plugin credentials do not have permission for this endpoint."
        case .transient:
            return "The plugin token endpoint is temporarily unavailable."
        case .rateLimited:
            return "The plugin token endpoint is rate limited."
        case .backoff:
            return "The plugin token endpoint is temporarily unavailable; retrying later."
        case .superseded:
            return "The plugin configuration changed while authentication was in progress."
        }
    }
}

/// Shared session identity and generation fence for external HTTP providers.
/// The lock protects the small registry only; network work and Keychain I/O
/// happen outside the provider's value semantics but a rotation commit holds
/// the lock across the credential write so replacement cannot interleave with
/// an old write.
final class HTTPJSONAuthSessionRegistry: @unchecked Sendable {
    private struct Entry {
        let fingerprint: Data
        let generation: UInt64
        let session: HTTPJSONAuthSession
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generations: [String: UInt64] = [:]

    func session(
        for profileKey: String,
        fingerprint: Data,
        make: (UInt64) -> HTTPJSONAuthSession
    ) -> HTTPJSONAuthSession {
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[profileKey], entry.fingerprint == fingerprint {
            return entry.session
        }

        let generation = generations[profileKey, default: 0] &+ 1
        generations[profileKey] = generation
        let session = make(generation)
        entries[profileKey] = Entry(
            fingerprint: fingerprint,
            generation: generation,
            session: session
        )
        return session
    }

    func invalidate(pluginID: String) {
        lock.lock()
        defer { lock.unlock() }

        let prefix = pluginID + "|"
        for key in entries.keys.filter({ $0.hasPrefix(prefix) }) {
            entries.removeValue(forKey: key)
            generations[key] = generations[key, default: 0] &+ 1
        }
    }

    /// Fence all sessions for a plugin while its configuration store performs
    /// an atomic replacement. A failed replacement restores the old entries so
    /// the currently active provider is not stranded by a failed UI save.
    func withPluginFenced<T>(pluginID: String, operation: () throws -> T) rethrows -> T {
        lock.lock()
        let prefix = pluginID + "|"
        let previousEntries = entries.filter { $0.key.hasPrefix(prefix) }
        let previousGenerations = generations.filter { $0.key.hasPrefix(prefix) }
        for key in previousEntries.keys {
            entries.removeValue(forKey: key)
            generations[key] = generations[key, default: 0] &+ 1
        }

        do {
            let result = try operation()
            lock.unlock()
            return result
        } catch {
            for (key, entry) in previousEntries {
                entries[key] = entry
            }
            for (key, generation) in previousGenerations {
                generations[key] = generation
            }
            lock.unlock()
            throw error
        }
    }

    func isCurrent(profileKey: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[profileKey]?.generation == generation
    }

    func commitIfCurrent(
        profileKey: String,
        generation: UInt64,
        operation: () throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard entries[profileKey]?.generation == generation else {
            throw HTTPJSONAuthSessionError.superseded
        }
        do {
            try operation()
        } catch {
            throw HTTPJSONAuthSessionError.credentialPersistenceFailed
        }
    }
}

actor HTTPJSONAuthSession {
    private struct TokenState: Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    private let pluginID: String
    private let profileKey: String
    private let generation: UInt64
    private let auth: PluginHTTPJSONAuthDefinition
    private let configuration: [String: PluginJSONValue]
    private let sender: HTTPJSONRequestSender
    private let maximumResponseBytes: Int
    private let credentialStore: any PluginRefreshCredentialStore
    private let registry: HTTPJSONAuthSessionRegistry

    private var refreshToken: String
    private var accessTokenValue: String?
    private var expiresAt: Date?
    private var refreshTask: Task<TokenState, Error>?
    private var reconfigurationRequired = false
    private var retryAfter: Date?
    private var transientFailureCount = 0

    init(
        pluginID: String,
        profileKey: String,
        generation: UInt64,
        auth: PluginHTTPJSONAuthDefinition,
        configuration: [String: PluginJSONValue],
        initialRefreshToken: String,
        sender: @escaping HTTPJSONRequestSender,
        maximumResponseBytes: Int,
        credentialStore: any PluginRefreshCredentialStore,
        registry: HTTPJSONAuthSessionRegistry
    ) {
        self.pluginID = pluginID
        self.profileKey = profileKey
        self.generation = generation
        self.auth = auth
        self.configuration = configuration
        self.refreshToken = initialRefreshToken
        self.sender = sender
        self.maximumResponseBytes = maximumResponseBytes
        self.credentialStore = credentialStore
        self.registry = registry
    }

    func accessToken(now: Date) async throws -> String {
        if let accessTokenValue, !needsRefresh(now: now) {
            return accessTokenValue
        }
        return try await refresh(force: false, observedAccessToken: nil, now: now)
    }

    func forceRefresh(observedAccessToken: String?, now: Date) async throws -> String {
        if let accessTokenValue,
           let observedAccessToken,
           accessTokenValue != observedAccessToken,
           !needsRefresh(now: now) {
            return accessTokenValue
        }
        return try await refresh(force: true, observedAccessToken: observedAccessToken, now: now)
    }

    private func needsRefresh(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(auth.expirySkewSeconds) >= expiresAt
    }

    private func refresh(
        force: Bool,
        observedAccessToken: String?,
        now: Date
    ) async throws -> String {
        if reconfigurationRequired {
            throw HTTPJSONAuthSessionError.reconfigurationRequired
        }
        if !force, let accessTokenValue, !needsRefresh(now: now) {
            return accessTokenValue
        }
        if force,
           let accessTokenValue,
           let observedAccessToken,
           accessTokenValue != observedAccessToken,
           !needsRefresh(now: now) {
            return accessTokenValue
        }
        if let retryAfter, now < retryAfter {
            throw HTTPJSONAuthSessionError.backoff
        }

        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let task = Task { [weak self] () throws -> TokenState in
            guard let self else {
                throw HTTPJSONAuthSessionError.superseded
            }
            return try await self.performRefreshAndRecord(now: now)
        }
        refreshTask = task
        defer { refreshTask = nil }

        let state = try await task.value
        guard registry.isCurrent(profileKey: profileKey, generation: generation) else {
            throw HTTPJSONAuthSessionError.superseded
        }
        accessTokenValue = state.accessToken
        expiresAt = state.expiresAt
        transientFailureCount = 0
        retryAfter = nil
        return state.accessToken
    }

    private func performRefreshAndRecord(now: Date) async throws -> TokenState {
        do {
            return try await performRefresh(now: now)
        } catch let error as HTTPJSONAuthSessionError {
            record(error: error, now: now)
            throw error
        } catch {
            record(error: .transient, now: now)
            throw HTTPJSONAuthSessionError.transient
        }
    }

    private func record(error: HTTPJSONAuthSessionError, now: Date) {
        switch error {
        case .reconfigurationRequired, .credentialPersistenceFailed, .missingRefreshCredential:
            reconfigurationRequired = true
        case .transient, .rateLimited:
            transientFailureCount = min(transientFailureCount + 1, 5)
            let multiplier = pow(2, Double(max(transientFailureCount - 1, 0)))
            let delay = min(30 * multiplier, 300)
            retryAfter = now.addingTimeInterval(delay)
        case .invalidResponse, .permissionDenied, .backoff, .superseded:
            break
        }
    }

    private func performRefresh(now: Date) async throws -> TokenState {
        guard !refreshToken.isEmpty else {
            throw HTTPJSONAuthSessionError.missingRefreshCredential
        }
        guard registry.isCurrent(profileKey: profileKey, generation: generation) else {
            throw HTTPJSONAuthSessionError.superseded
        }

        let request: URLRequest
        do {
            request = try makeRefreshRequest()
        } catch {
            throw HTTPJSONAuthSessionError.reconfigurationRequired
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sender(request)
        } catch let error as HTTPJSONPluginError {
            if error == .responseTooLarge {
                throw HTTPJSONAuthSessionError.invalidResponse
            }
            throw HTTPJSONAuthSessionError.transient
        } catch {
            throw HTTPJSONAuthSessionError.transient
        }

        guard data.count <= maximumResponseBytes,
              let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              let requestURL = request.url,
              HTTPJSONRedirectPolicy.sameOrigin(requestURL, finalURL) else {
            throw HTTPJSONAuthSessionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            switch httpResponse.statusCode {
            case 400, 401, 404, 422:
                throw HTTPJSONAuthSessionError.reconfigurationRequired
            case 403:
                throw HTTPJSONAuthSessionError.permissionDenied
            case 429:
                throw HTTPJSONAuthSessionError.rateLimited
            case 500...599:
                throw HTTPJSONAuthSessionError.transient
            default:
                throw HTTPJSONAuthSessionError.invalidResponse
            }
        }

        let root: PluginJSONValue
        do {
            root = try JSONDecoder().decode(PluginJSONValue.self, from: data)
        } catch {
            throw HTTPJSONAuthSessionError.invalidResponse
        }

        guard let accessTokenValue = PluginJSONPointer.resolve(
            path: auth.accessTokenPath,
            in: root
        ), case let .string(newAccessToken) = accessTokenValue,
              Self.isValidToken(newAccessToken) else {
            throw HTTPJSONAuthSessionError.invalidResponse
        }

        let replacementRefreshToken: String?
        if let refreshTokenPath = auth.refreshTokenPath,
           let value = PluginJSONPointer.resolve(path: refreshTokenPath, in: root),
           !(value == .null) {
            guard case let .string(candidate) = value, Self.isValidToken(candidate) else {
                throw HTTPJSONAuthSessionError.invalidResponse
            }
            replacementRefreshToken = candidate
        } else {
            replacementRefreshToken = nil
        }

        let expiresIn = try parseExpiresIn(from: root)
        let expiresAt: Date?
        if let expiresIn {
            expiresAt = now.addingTimeInterval(expiresIn)
        } else if auth.missingExpiryPolicy == .fixedTTL,
                  let fallbackTTLSeconds = auth.fallbackTTLSeconds {
            expiresAt = now.addingTimeInterval(fallbackTTLSeconds)
        } else {
            expiresAt = nil
        }

        if let replacementRefreshToken {
            do {
                try registry.commitIfCurrent(
                    profileKey: profileKey,
                    generation: generation
                ) {
                    try credentialStore.write(
                        replacementRefreshToken,
                        pluginID: pluginID,
                        fieldID: auth.refreshTokenField
                    )
                }
            } catch let error as HTTPJSONAuthSessionError {
                throw error
            } catch {
                throw HTTPJSONAuthSessionError.credentialPersistenceFailed
            }
            guard registry.isCurrent(profileKey: profileKey, generation: generation) else {
                throw HTTPJSONAuthSessionError.superseded
            }
            refreshToken = replacementRefreshToken
        }

        guard registry.isCurrent(profileKey: profileKey, generation: generation) else {
            throw HTTPJSONAuthSessionError.superseded
        }
        return TokenState(accessToken: newAccessToken, expiresAt: expiresAt)
    }

    private func parseExpiresIn(from root: PluginJSONValue) throws -> TimeInterval? {
        guard let path = auth.expiresInPath,
              let value = PluginJSONPointer.resolve(path: path, in: root) else {
            return nil
        }
        if case .null = value { return nil }
        let seconds: Double
        switch value {
        case let .integer(integer):
            seconds = Double(integer)
        case let .decimal(decimal):
            seconds = decimal
        default:
            throw HTTPJSONAuthSessionError.invalidResponse
        }
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= 31_536_000 else {
            throw HTTPJSONAuthSessionError.invalidResponse
        }
        return seconds
    }

    private func makeRefreshRequest() throws -> URLRequest {
        guard let endpointValue = configuration[auth.refreshURLField],
              case let .string(endpoint) = endpointValue,
              let url = URL(string: endpoint),
              PluginHTTPJSONValidation.isAllowedHTTPSURL(url) else {
            throw HTTPJSONAuthSessionError.reconfigurationRequired
        }

        var parameters: [(String, String)] = [
            (auth.refreshTokenParameter, refreshToken)
        ]
        if let grantTypeParameter = auth.grantTypeParameter,
           let grantTypeValue = auth.grantTypeValue {
            parameters.append((grantTypeParameter, grantTypeValue))
        }
        appendConfigurationValue(
            fieldID: auth.clientIDField,
            parameter: "client_id",
            to: &parameters
        )
        appendConfigurationValue(
            fieldID: auth.clientSecretField,
            parameter: "client_secret",
            to: &parameters
        )
        appendConfigurationValue(
            fieldID: auth.scopeField,
            parameter: "scope",
            to: &parameters
        )

        var request = URLRequest(url: url, timeoutInterval: auth.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth.encoding {
        case .form:
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Self.formEncoded(parameters)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let object = Dictionary(uniqueKeysWithValues: parameters.map { ($0.0, PluginJSONValue.string($0.1)) })
            request.httpBody = try JSONEncoder().encode(PluginJSONValue.object(object))
        }
        return request
    }

    private func appendConfigurationValue(
        fieldID: String?,
        parameter: String,
        to parameters: inout [(String, String)]
    ) {
        guard let fieldID,
              let value = configuration[fieldID],
              case let .string(text) = value,
              !text.isEmpty else {
            return
        }
        parameters.append((parameter, text))
    }

    private static func formEncoded(_ parameters: [(String, String)]) -> Data {
        let text = parameters.map { escapeForm($0.0) + "=" + escapeForm($0.1) }
            .joined(separator: "&")
        return Data(text.utf8)
    }

    private static func escapeForm(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            case 0x20:
                return "+"
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 16_384
            && !value.contains("\n")
            && !value.contains("\r")
            && value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    }
}
