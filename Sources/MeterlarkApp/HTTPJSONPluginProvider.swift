import CryptoKit
import Foundation

final class HTTPJSONRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectedURL = request.url,
              Self.sameOrigin(originalURL, redirectedURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard PluginHTTPJSONValidation.isAllowedHTTPSURL(lhs),
              PluginHTTPJSONValidation.isAllowedHTTPSURL(rhs),
              lhs.host?.lowercased() == rhs.host?.lowercased(),
              normalizedPort(lhs) == normalizedPort(rhs) else {
            return false
        }
        return true
    }

    private static func normalizedPort(_ url: URL) -> Int {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.port ?? 443
    }
}

enum HTTPJSONPluginError: Error, Equatable, Sendable {
    case unsupportedTransport
    case invalidConfiguration
    case invalidURL
    case insecureURL
    case requestFailed
    case responseTooLarge
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSON
    case responseConditionFailed
    case dashboardMappingFailed(String)
    case modelCatalogMappingFailed(String)
    case authenticationRequired
    case permissionDenied
    case temporarilyUnavailable
    case tokenResponseInvalid
    case providerReplaced
}

extension HTTPJSONPluginError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return "This plugin does not declare the http-json transport."
        case .invalidConfiguration:
            return "The http-json plugin configuration is invalid."
        case .invalidURL:
            return "The http-json plugin endpoint is invalid."
        case .insecureURL:
            return "The http-json plugin endpoint must use HTTPS."
        case .requestFailed:
            return "The http-json plugin request could not be completed."
        case .responseTooLarge:
            return "The http-json plugin response is too large."
        case .invalidHTTPResponse:
            return "The http-json plugin returned an invalid HTTP response."
        case let .httpStatus(status):
            return "The http-json plugin returned HTTP status \(status)."
        case .invalidJSON:
            return "The http-json plugin returned invalid JSON."
        case .responseConditionFailed:
            return "The http-json plugin response did not satisfy its success conditions."
        case let .dashboardMappingFailed(detail):
            return "The http-json plugin dashboard mapping is invalid: \(detail)"
        case let .modelCatalogMappingFailed(detail):
            return "The http-json plugin model catalog is invalid: \(detail)"
        case .authenticationRequired:
            return "The http-json plugin credentials need to be updated."
        case .permissionDenied:
            return "The http-json plugin credentials do not have permission for this endpoint."
        case .temporarilyUnavailable:
            return "The http-json plugin is temporarily unavailable."
        case .tokenResponseInvalid:
            return "The http-json plugin token endpoint returned an invalid response."
        case .providerReplaced:
            return "The http-json plugin configuration changed while refreshing."
        }
    }
}

struct HTTPJSONRawResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL
}

struct HTTPJSONPluginProvider: DashboardPluginProvider {
    typealias RequestSender = HTTPJSONRequestSender

    let manifest: PluginManifest
    private let configuration: [String: PluginJSONValue]
    private let send: RequestSender
    private let maximumResponseBytes: Int
    private let authSession: HTTPJSONAuthSession?
    private let nowProvider: @Sendable () -> Date

    init(
        manifest: PluginManifest,
        configurationData: Data? = nil,
        maximumResponseBytes: Int = ExternalPluginTransport.maximumResponseBytes,
        send: RequestSender? = nil,
        credentialStore: (any PluginRefreshCredentialStore)? = nil,
        sessionRegistry: HTTPJSONAuthSessionRegistry = HTTPJSONAuthSessionRegistry(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try manifest.validate()
        guard manifest.transport == .httpJSON,
              manifest.http != nil else {
            throw HTTPJSONPluginError.unsupportedTransport
        }
        guard maximumResponseBytes > 0 else {
            throw HTTPJSONPluginError.responseTooLarge
        }

        let configurationValues: [String: PluginJSONValue]
        if let configurationData {
            let value: PluginJSONValue
            do {
                value = try JSONDecoder().decode(PluginJSONValue.self, from: configurationData)
            } catch {
                throw HTTPJSONPluginError.invalidConfiguration
            }
            guard case let .object(values) = value else {
                throw HTTPJSONPluginError.invalidConfiguration
            }
            configurationValues = values
        } else {
            configurationValues = [:]
        }

        if let schema = manifest.configuration {
            do {
                try schema.validateEffectiveValues(configurationValues)
            } catch {
                throw HTTPJSONPluginError.invalidConfiguration
            }
        }

        self.manifest = manifest
        self.configuration = configurationValues
        self.maximumResponseBytes = maximumResponseBytes
        self.nowProvider = nowProvider
        let responseLimit = maximumResponseBytes
        let requestSender: RequestSender = send ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration,
                delegate: HTTPJSONRedirectPolicy(),
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in bytes {
                guard data.count < responseLimit else {
                    throw HTTPJSONPluginError.responseTooLarge
                }
                data.append(byte)
            }
            return (data, response)
        }
        self.send = requestSender

        if let auth = manifest.http?.auth {
            guard let refreshTokenValue = configurationValues[auth.refreshTokenField],
                  case let .string(refreshToken) = refreshTokenValue,
                  !refreshToken.isEmpty,
                  let credentialStore else {
                throw HTTPJSONPluginError.invalidConfiguration
            }
            try Self.validateRefreshEndpoint(
                configuration: configurationValues,
                auth: auth
            )
            let profileKey = "\(manifest.id)|\(auth.profileID)"
            let fingerprint = try Self.authFingerprint(
                configuration: configurationValues,
                auth: auth
            )
            self.authSession = sessionRegistry.session(
                for: profileKey,
                fingerprint: fingerprint
            ) { generation in
                HTTPJSONAuthSession(
                    pluginID: manifest.id,
                    profileKey: profileKey,
                    generation: generation,
                    auth: auth,
                    configuration: configurationValues,
                    initialRefreshToken: refreshToken,
                    sender: requestSender,
                    maximumResponseBytes: responseLimit,
                    credentialStore: credentialStore,
                    registry: sessionRegistry
                )
            }
        } else {
            self.authSession = nil
        }

        // Validate the complete request shape during provider construction so
        // registry discovery can report an invalid configured endpoint before
        // the plugin is enabled or the first refresh starts.
        _ = try makeRequest(accessToken: nil)
    }

    func fetchDashboard() async throws -> PluginDashboardDocument {
        guard manifest.supportsDashboard,
              manifest.dashboard != nil,
              manifest.http != nil else {
            throw HTTPJSONPluginError.unsupportedTransport
        }

        let response = try await fetchRawResponse()
        return try makeDocument(data: response.data)
    }

    func fetchRawResponse() async throws -> HTTPJSONRawResponse {
        guard let definition = manifest.http else {
            throw HTTPJSONPluginError.unsupportedTransport
        }

        let firstToken: String?
        if let authSession {
            do {
                firstToken = try await authSession.accessToken(now: nowProvider())
            } catch let error as HTTPJSONAuthSessionError {
                throw Self.mapAuthError(error)
            } catch {
                throw HTTPJSONPluginError.requestFailed
            }
        } else {
            firstToken = nil
        }

        let first = try await performRequest(accessToken: firstToken)
        if let auth = definition.auth,
           isTokenExpiredResponse(first.data, response: first.httpResponse, auth: auth) {
            guard let authSession else {
                throw Self.statusError(first.httpResponse.statusCode, authenticated: true)
            }
            let token: String
            do {
                token = try await authSession.forceRefresh(
                    observedAccessToken: firstToken,
                    now: nowProvider()
                )
            } catch let error as HTTPJSONAuthSessionError {
                throw Self.mapAuthError(error)
            } catch {
                throw HTTPJSONPluginError.requestFailed
            }
            let retry = try await performRequest(accessToken: token)
            guard (200..<300).contains(retry.httpResponse.statusCode) else {
                throw Self.statusError(retry.httpResponse.statusCode, authenticated: true)
            }
            guard let retryURL = retry.httpResponse.url else {
                throw HTTPJSONPluginError.invalidHTTPResponse
            }
            try validateResponseConditions(data: retry.data)
            return HTTPJSONRawResponse(
                data: retry.data,
                statusCode: retry.httpResponse.statusCode,
                url: retryURL
            )
        }

        guard (200..<300).contains(first.httpResponse.statusCode) else {
            throw Self.statusError(
                first.httpResponse.statusCode,
                authenticated: definition.auth != nil
            )
        }
        guard let url = first.httpResponse.url else {
            throw HTTPJSONPluginError.invalidHTTPResponse
        }
        try validateResponseConditions(data: first.data)
        return HTTPJSONRawResponse(
            data: first.data,
            statusCode: first.httpResponse.statusCode,
            url: url
        )
    }

    private func performRequest(accessToken: String?) async throws -> (data: Data, httpResponse: HTTPURLResponse) {
        let request = try makeRequest(accessToken: accessToken)
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await send(request)
        } catch let error as HTTPJSONPluginError {
            throw error
        } catch {
            throw HTTPJSONPluginError.requestFailed
        }

        guard responseData.count <= maximumResponseBytes else {
            throw HTTPJSONPluginError.responseTooLarge
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPJSONPluginError.invalidHTTPResponse
        }
        guard let requestURL = request.url,
              let finalURL = httpResponse.url,
              HTTPJSONRedirectPolicy.sameOrigin(requestURL, finalURL) else {
            throw HTTPJSONPluginError.insecureURL
        }
        return (responseData, httpResponse)
    }

    private func validateResponseConditions(data: Data) throws {
        guard let definition = manifest.http,
              !definition.conditions.isEmpty else {
            return
        }
        let responseValue: PluginJSONValue
        do {
            responseValue = try JSONDecoder().decode(PluginJSONValue.self, from: data)
        } catch {
            throw HTTPJSONPluginError.invalidJSON
        }
        guard definition.conditions.allSatisfy({ $0.evaluate(root: responseValue) }) else {
            throw HTTPJSONPluginError.responseConditionFailed
        }
    }

    private func makeDocument(data responseData: Data) throws -> PluginDashboardDocument {
        let responseValue: PluginJSONValue
        do {
            responseValue = try JSONDecoder().decode(PluginJSONValue.self, from: responseData)
        } catch {
            throw HTTPJSONPluginError.invalidJSON
        }

        guard let definition = manifest.http,
              definition.conditions.allSatisfy({ $0.evaluate(root: responseValue) }) else {
            throw HTTPJSONPluginError.responseConditionFailed
        }
        guard let dashboard = manifest.dashboard else {
            throw HTTPJSONPluginError.unsupportedTransport
        }

        let document: PluginDashboardDocument
        do {
            document = try dashboard.makeDocument(
                pluginID: manifest.id,
                response: responseValue
            )
            _ = try document.makeModel(for: manifest)
        } catch {
            throw HTTPJSONPluginError.dashboardMappingFailed(Self.safeMessage(for: error))
        }
        return document
    }

    private func makeRequest(accessToken: String?) throws -> URLRequest {
        guard let definition = manifest.http else {
            throw HTTPJSONPluginError.unsupportedTransport
        }
        guard let endpointValue = configuration[definition.urlField],
              case let .string(endpoint) = endpointValue,
              let url = URL(string: endpoint) else {
            throw HTTPJSONPluginError.invalidConfiguration
        }
        guard PluginHTTPJSONValidation.isAllowedHTTPSURL(url) else {
            throw HTTPJSONPluginError.insecureURL
        }

        var request = URLRequest(url: url, timeoutInterval: definition.timeoutSeconds)
        request.httpMethod = definition.method.rawValue
        for header in definition.headers {
            let value: String
            if let literal = header.value {
                value = literal
            } else if let valueField = header.valueField,
                      let fieldValue = configuration[valueField],
                      case let .string(fieldText) = fieldValue {
                value = (header.valuePrefix ?? "") + fieldText + (header.valueSuffix ?? "")
            } else {
                throw HTTPJSONPluginError.invalidConfiguration
            }
            request.setValue(value, forHTTPHeaderField: header.name)
        }
        if let auth = definition.auth, let accessToken {
            let headerValue: String
            switch auth.headerMode {
            case .raw:
                headerValue = accessToken
            case .bearer:
                headerValue = "Bearer \(accessToken)"
            }
            request.setValue(headerValue, forHTTPHeaderField: auth.accessTokenHeader)
        }
        return request
    }

    private func isTokenExpiredResponse(
        _ data: Data,
        response: HTTPURLResponse,
        auth: PluginHTTPJSONAuthDefinition
    ) -> Bool {
        if auth.tokenExpiredStatusCodes.contains(response.statusCode) {
            return true
        }
        guard !auth.tokenExpiredConditions.isEmpty,
              let value = try? JSONDecoder().decode(PluginJSONValue.self, from: data) else {
            return false
        }
        return auth.tokenExpiredConditions.allSatisfy { $0.evaluate(root: value) }
    }

    private static func statusError(
        _ statusCode: Int,
        authenticated: Bool
    ) -> HTTPJSONPluginError {
        guard authenticated else { return .httpStatus(statusCode) }
        switch statusCode {
        case 401:
            return .authenticationRequired
        case 403:
            return .permissionDenied
        default:
            return .httpStatus(statusCode)
        }
    }

    private static func mapAuthError(_ error: HTTPJSONAuthSessionError) -> HTTPJSONPluginError {
        switch error {
        case .missingRefreshCredential, .reconfigurationRequired, .credentialPersistenceFailed:
            return .authenticationRequired
        case .permissionDenied:
            return .permissionDenied
        case .transient, .rateLimited, .backoff:
            return .temporarilyUnavailable
        case .invalidResponse:
            return .tokenResponseInvalid
        case .superseded:
            return .providerReplaced
        }
    }

    private static func authFingerprint(
        configuration: [String: PluginJSONValue],
        auth: PluginHTTPJSONAuthDefinition
    ) throws -> Data {
        struct ConfigurationEntry: Codable {
            let key: String
            let value: PluginJSONValue
        }

        struct Fingerprint: Codable {
            let configuration: [ConfigurationEntry]
            let auth: PluginHTTPJSONAuthDefinition
        }
        let authRelevantKeys = Set([
            auth.refreshURLField,
            auth.clientIDField,
            auth.clientSecretField,
            auth.scopeField
        ].compactMap { $0 })
        let entries = configuration.keys
            .filter { authRelevantKeys.contains($0) }
            .sorted()
            .map { key in
                ConfigurationEntry(key: key, value: configuration[key]!)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(Fingerprint(configuration: entries, auth: auth))
        return Data(SHA256.hash(data: canonical))
    }

    private static func validateRefreshEndpoint(
        configuration: [String: PluginJSONValue],
        auth: PluginHTTPJSONAuthDefinition
    ) throws {
        guard let endpointValue = configuration[auth.refreshURLField],
              case let .string(endpoint) = endpointValue,
              let url = URL(string: endpoint) else {
            throw HTTPJSONPluginError.invalidConfiguration
        }
        guard PluginHTTPJSONValidation.isAllowedHTTPSURL(url) else {
            throw HTTPJSONPluginError.insecureURL
        }
    }

    private static func safeMessage(for error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(message.isEmpty ? "Unknown dashboard mapping error." : message.prefix(240))
    }
}
