import Foundation

enum PluginHTTPJSONSchemaError: Error, Equatable, Sendable {
    case invalid(String)
}

extension PluginHTTPJSONSchemaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalid(path):
            return "The http-json plugin schema is invalid at \(path)."
        }
    }
}

enum PluginHTTPJSONLimits {
    static let maximumHeaders = 16
    static let maximumConditions = 16
    static let maximumBlocks = PluginDashboardLimits.maximumBlocks
    static let maximumTiles = PluginDashboardLimits.maximumMetricTiles
    static let maximumMetricColumns = PluginDashboardLimits.maximumMetricColumns
    static let maximumRows = PluginDashboardLimits.maximumProgressItems
    static let maximumPointerBytes = 1_024
    static let maximumMappingTextBytes = 500
}

enum PluginHTTPMethod: String, Codable, Equatable, Sendable {
    case get = "GET"
}

struct PluginHTTPHeader: Codable, Equatable, Sendable {
    let name: String
    let value: String?
    let valueField: String?
    let valuePrefix: String?
    let valueSuffix: String?

    init(
        name: String,
        value: String? = nil,
        valueField: String? = nil,
        valuePrefix: String? = nil,
        valueSuffix: String? = nil
    ) {
        self.name = name
        self.value = value
        self.valueField = valueField
        self.valuePrefix = valuePrefix
        self.valueSuffix = valueSuffix
    }

    func validate(configuration: PluginConfigurationSchema?, path: String) throws {
        guard PluginHTTPJSONValidation.headerName(name) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).name")
        }
        guard (value == nil) != (valueField == nil) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).value/valueField")
        }
        if let value {
            try PluginHTTPJSONValidation.text(value, path: "\(path).value")
            guard valuePrefix == nil, valueSuffix == nil else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).valuePrefix/valueSuffix")
            }
        }
        if let valueField {
            guard let field = configuration?.fields.first(where: { $0.id == valueField }),
                  field.kind == .text || field.kind == .url || field.kind == .secret else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).valueField")
            }
            if let valuePrefix {
                try PluginHTTPJSONValidation.textFragment(valuePrefix, path: "\(path).valuePrefix", allowEmpty: true)
            }
            if let valueSuffix {
                try PluginHTTPJSONValidation.textFragment(valueSuffix, path: "\(path).valueSuffix", allowEmpty: true)
            }
        }
    }
}

struct PluginHTTPResponseCondition: Codable, Equatable, Sendable {
    let path: String
    let `operator`: PluginHTTPConditionOperator
    let value: PluginJSONValue

    func validate(path validationPath: String) throws {
        try PluginHTTPJSONValidation.pointer(path, path: "\(validationPath).path")
        switch `operator` {
        case .equals:
            break
        }
    }

    func evaluate(root: PluginJSONValue) -> Bool {
        guard let actual = PluginJSONPointer.resolve(path: path, in: root) else { return false }
        return actual == value
    }
}

enum PluginHTTPConditionOperator: String, Codable, Equatable, Sendable {
    case equals
}

enum PluginHTTPRefreshEncoding: String, Codable, Equatable, Sendable {
    case form
    case json
}

enum PluginHTTPAccessTokenHeaderMode: String, Codable, Equatable, Sendable {
    case bearer
    case raw
}

enum PluginHTTPMissingExpiryPolicy: String, Codable, Equatable, Sendable {
    case unauthorizedRetry = "unauthorized-retry"
    case fixedTTL = "fixed-ttl"
}

struct PluginHTTPJSONAuthDefinition: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let requiredProtocolVersion = 2

    let version: Int
    let profileID: String
    let refreshURLField: String
    let refreshTokenField: String
    let encoding: PluginHTTPRefreshEncoding
    let refreshTokenParameter: String
    let grantTypeParameter: String?
    let grantTypeValue: String?
    let clientIDField: String?
    let clientSecretField: String?
    let scopeField: String?
    let accessTokenPath: String
    let refreshTokenPath: String?
    let expiresInPath: String?
    let accessTokenHeader: String
    let headerMode: PluginHTTPAccessTokenHeaderMode
    let timeoutSeconds: Double
    let expirySkewSeconds: Double
    let missingExpiryPolicy: PluginHTTPMissingExpiryPolicy
    let fallbackTTLSeconds: Double?
    let tokenExpiredStatusCodes: [Int]
    let tokenExpiredConditions: [PluginHTTPResponseCondition]

    init(
        version: Int = Self.currentVersion,
        profileID: String = "default",
        refreshURLField: String,
        refreshTokenField: String,
        encoding: PluginHTTPRefreshEncoding,
        refreshTokenParameter: String = "refresh_token",
        grantTypeParameter: String? = "grant_type",
        grantTypeValue: String? = "refresh_token",
        clientIDField: String? = nil,
        clientSecretField: String? = nil,
        scopeField: String? = nil,
        accessTokenPath: String,
        refreshTokenPath: String? = nil,
        expiresInPath: String? = nil,
        accessTokenHeader: String = "Authorization",
        headerMode: PluginHTTPAccessTokenHeaderMode = .bearer,
        timeoutSeconds: Double = 20,
        expirySkewSeconds: Double = 300,
        missingExpiryPolicy: PluginHTTPMissingExpiryPolicy = .unauthorizedRetry,
        fallbackTTLSeconds: Double? = nil,
        tokenExpiredStatusCodes: [Int] = [401],
        tokenExpiredConditions: [PluginHTTPResponseCondition] = []
    ) {
        self.version = version
        self.profileID = profileID
        self.refreshURLField = refreshURLField
        self.refreshTokenField = refreshTokenField
        self.encoding = encoding
        self.refreshTokenParameter = refreshTokenParameter
        self.grantTypeParameter = grantTypeParameter
        self.grantTypeValue = grantTypeValue
        self.clientIDField = clientIDField
        self.clientSecretField = clientSecretField
        self.scopeField = scopeField
        self.accessTokenPath = accessTokenPath
        self.refreshTokenPath = refreshTokenPath
        self.expiresInPath = expiresInPath
        self.accessTokenHeader = accessTokenHeader
        self.headerMode = headerMode
        self.timeoutSeconds = timeoutSeconds
        self.expirySkewSeconds = expirySkewSeconds
        self.missingExpiryPolicy = missingExpiryPolicy
        self.fallbackTTLSeconds = fallbackTTLSeconds
        self.tokenExpiredStatusCodes = tokenExpiredStatusCodes
        self.tokenExpiredConditions = tokenExpiredConditions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case profileID
        case refreshURLField
        case refreshTokenField
        case encoding
        case refreshTokenParameter
        case grantTypeParameter
        case grantTypeValue
        case clientIDField
        case clientSecretField
        case scopeField
        case accessTokenPath
        case refreshTokenPath
        case expiresInPath
        case accessTokenHeader
        case headerMode
        case timeoutSeconds
        case expirySkewSeconds
        case missingExpiryPolicy
        case fallbackTTLSeconds
        case tokenExpiredStatusCodes
        case tokenExpiredConditions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID) ?? "default"
        refreshURLField = try container.decode(String.self, forKey: .refreshURLField)
        refreshTokenField = try container.decode(String.self, forKey: .refreshTokenField)
        encoding = try container.decode(PluginHTTPRefreshEncoding.self, forKey: .encoding)
        refreshTokenParameter = try container.decodeIfPresent(String.self, forKey: .refreshTokenParameter)
            ?? "refresh_token"
        if try container.decodeNil(forKey: .grantTypeParameter) {
            grantTypeParameter = nil
        } else {
            grantTypeParameter = try container.decodeIfPresent(String.self, forKey: .grantTypeParameter)
                ?? "grant_type"
        }
        if try container.decodeNil(forKey: .grantTypeValue) {
            grantTypeValue = nil
        } else {
            grantTypeValue = try container.decodeIfPresent(String.self, forKey: .grantTypeValue)
                ?? "refresh_token"
        }
        clientIDField = try container.decodeIfPresent(String.self, forKey: .clientIDField)
        clientSecretField = try container.decodeIfPresent(String.self, forKey: .clientSecretField)
        scopeField = try container.decodeIfPresent(String.self, forKey: .scopeField)
        accessTokenPath = try container.decode(String.self, forKey: .accessTokenPath)
        refreshTokenPath = try container.decodeIfPresent(String.self, forKey: .refreshTokenPath)
        expiresInPath = try container.decodeIfPresent(String.self, forKey: .expiresInPath)
        accessTokenHeader = try container.decodeIfPresent(String.self, forKey: .accessTokenHeader)
            ?? "Authorization"
        headerMode = try container.decodeIfPresent(PluginHTTPAccessTokenHeaderMode.self, forKey: .headerMode)
            ?? .bearer
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 20
        expirySkewSeconds = try container.decodeIfPresent(Double.self, forKey: .expirySkewSeconds) ?? 300
        missingExpiryPolicy = try container.decodeIfPresent(
            PluginHTTPMissingExpiryPolicy.self,
            forKey: .missingExpiryPolicy
        ) ?? .unauthorizedRetry
        fallbackTTLSeconds = try container.decodeIfPresent(Double.self, forKey: .fallbackTTLSeconds)
        tokenExpiredStatusCodes = try container.decodeIfPresent([Int].self, forKey: .tokenExpiredStatusCodes)
            ?? [401]
        tokenExpiredConditions = try container.decodeIfPresent(
            [PluginHTTPResponseCondition].self,
            forKey: .tokenExpiredConditions
        ) ?? []
    }

    func validate(configuration: PluginConfigurationSchema?, path: String = "http.auth") throws {
        guard version == Self.currentVersion else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).version")
        }
        try PluginHTTPJSONValidation.identifier(profileID, path: "\(path).profileID")
        guard let refreshURLField = configuration?.fields.first(where: { $0.id == refreshURLField }),
              refreshURLField.kind == .url,
              refreshURLField.required || refreshURLField.defaultValue != nil else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).refreshURLField")
        }
        if let defaultValue = refreshURLField.defaultValue {
            guard case let .string(defaultURL) = defaultValue,
                  PluginHTTPJSONValidation.isAllowedHTTPSURL(defaultURL) else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).refreshURLField.defaultValue")
            }
        }
        guard let refreshTokenField = configuration?.fields.first(where: { $0.id == refreshTokenField }),
              refreshTokenField.kind == .secret,
              refreshTokenField.required else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).refreshTokenField")
        }
        try validateParameter(refreshTokenParameter, path: "\(path).refreshTokenParameter")
        if let grantTypeParameter {
            try validateParameter(grantTypeParameter, path: "\(path).grantTypeParameter")
            guard let grantTypeValue else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).grantTypeValue")
            }
            try PluginHTTPJSONValidation.text(grantTypeValue, path: "\(path).grantTypeValue")
        } else {
            guard grantTypeValue == nil else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).grantTypeValue")
            }
        }
        try validateFieldReference(
            clientIDField,
            configuration: configuration,
            allowedKinds: [.text, .secret],
            path: "\(path).clientIDField"
        )
        try validateFieldReference(
            clientSecretField,
            configuration: configuration,
            allowedKinds: [.secret],
            path: "\(path).clientSecretField"
        )
        try validateFieldReference(
            scopeField,
            configuration: configuration,
            allowedKinds: [.text],
            path: "\(path).scopeField"
        )
        try PluginHTTPJSONValidation.pointer(accessTokenPath, path: "\(path).accessTokenPath")
        if let refreshTokenPath {
            try PluginHTTPJSONValidation.pointer(refreshTokenPath, path: "\(path).refreshTokenPath")
        }
        if let expiresInPath {
            try PluginHTTPJSONValidation.pointer(expiresInPath, path: "\(path).expiresInPath")
        }
        try validateRefreshParameterNames(path: path)
        guard PluginHTTPJSONValidation.headerName(accessTokenHeader) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).accessTokenHeader")
        }
        guard timeoutSeconds.isFinite, (0.1...60).contains(timeoutSeconds) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).timeoutSeconds")
        }
        guard expirySkewSeconds.isFinite, (0...86_400).contains(expirySkewSeconds) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).expirySkewSeconds")
        }
        switch missingExpiryPolicy {
        case .unauthorizedRetry:
            guard fallbackTTLSeconds == nil else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).fallbackTTLSeconds")
            }
        case .fixedTTL:
            guard let fallbackTTLSeconds,
                  fallbackTTLSeconds.isFinite,
                  (1...86_400).contains(fallbackTTLSeconds) else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).fallbackTTLSeconds")
            }
        }
        guard !tokenExpiredStatusCodes.isEmpty,
              tokenExpiredStatusCodes.count <= 8,
              tokenExpiredStatusCodes.allSatisfy({ (400...499).contains($0) }) else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).tokenExpiredStatusCodes")
        }
        guard tokenExpiredConditions.count <= PluginHTTPJSONLimits.maximumConditions else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).tokenExpiredConditions")
        }
        for (index, condition) in tokenExpiredConditions.enumerated() {
            try condition.validate(path: "\(path).tokenExpiredConditions[\(index)]")
        }
    }

    private func validateFieldReference(
        _ fieldID: String?,
        configuration: PluginConfigurationSchema?,
        allowedKinds: Set<PluginConfigurationFieldKind>,
        path: String
    ) throws {
        guard let fieldID else { return }
        guard let field = configuration?.fields.first(where: { $0.id == fieldID }),
              allowedKinds.contains(field.kind) else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
    }

    private func validateParameter(_ value: String, path: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-_").contains($0)
              }) else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
    }

    private func validateRefreshParameterNames(path: String) throws {
        var names = Set<String>()
        func insert(_ name: String, _ validationPath: String) throws {
            guard names.insert(name).inserted else {
                throw PluginHTTPJSONSchemaError.invalid(validationPath)
            }
        }

        try insert(refreshTokenParameter, "\(path).refreshTokenParameter")
        if let grantTypeParameter {
            try insert(grantTypeParameter, "\(path).grantTypeParameter")
        }
        if clientIDField != nil {
            try insert("client_id", "\(path).clientIDField")
        }
        if clientSecretField != nil {
            try insert("client_secret", "\(path).clientSecretField")
        }
        if scopeField != nil {
            try insert("scope", "\(path).scopeField")
        }
    }
}

struct PluginHTTPJSONDefinition: Codable, Equatable, Sendable {
    let method: PluginHTTPMethod
    let urlField: String
    let headers: [PluginHTTPHeader]
    let timeoutSeconds: Double
    let conditions: [PluginHTTPResponseCondition]
    let auth: PluginHTTPJSONAuthDefinition?

    init(
        method: PluginHTTPMethod = .get,
        urlField: String,
        headers: [PluginHTTPHeader] = [],
        timeoutSeconds: Double = 20,
        conditions: [PluginHTTPResponseCondition] = [],
        auth: PluginHTTPJSONAuthDefinition? = nil
    ) {
        self.method = method
        self.urlField = urlField
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
        self.conditions = conditions
        self.auth = auth
    }

    func validate(configuration: PluginConfigurationSchema?) throws {
        guard method == .get else {
            throw PluginHTTPJSONSchemaError.invalid("http.method")
        }
        guard let urlField = configuration?.fields.first(where: { $0.id == urlField }),
              urlField.kind == .url else {
            throw PluginHTTPJSONSchemaError.invalid("http.urlField")
        }
        guard urlField.required || urlField.defaultValue != nil else {
            throw PluginHTTPJSONSchemaError.invalid("http.urlField")
        }
        if let defaultValue = urlField.defaultValue {
            guard case let .string(defaultURL) = defaultValue,
                  PluginHTTPJSONValidation.isAllowedHTTPSURL(defaultURL) else {
                throw PluginHTTPJSONSchemaError.invalid("http.urlField.defaultValue")
            }
        }
        guard timeoutSeconds.isFinite, (0.1...60).contains(timeoutSeconds) else {
            throw PluginHTTPJSONSchemaError.invalid("http.timeoutSeconds")
        }
        guard headers.count <= PluginHTTPJSONLimits.maximumHeaders else {
            throw PluginHTTPJSONSchemaError.invalid("http.headers")
        }
        var headerNames = Set<String>()
        for (index, header) in headers.enumerated() {
            let path = "http.headers[\(index)]"
            guard headerNames.insert(header.name.lowercased()).inserted else {
                throw PluginHTTPJSONSchemaError.invalid("\(path).name")
            }
            try header.validate(configuration: configuration, path: path)
        }
        if let auth {
            try auth.validate(configuration: configuration)
            guard !headers.contains(where: { $0.name.lowercased() == auth.accessTokenHeader.lowercased() }) else {
                throw PluginHTTPJSONSchemaError.invalid("http.headers/auth.accessTokenHeader")
            }
        }
        guard conditions.count <= PluginHTTPJSONLimits.maximumConditions else {
            throw PluginHTTPJSONSchemaError.invalid("http.conditions")
        }
        for (index, condition) in conditions.enumerated() {
            try condition.validate(path: "http.conditions[\(index)]")
        }
    }
}

enum PluginBindingFormat: String, Codable, Equatable, Sendable {
    case text
    case integer
    case decimal
    case currency
}

struct PluginTextFallback: Codable, Equatable, Sendable {
    let text: String
    let accessibilityText: String?
    let localizedText: PluginLocalizedText?
    let localizedAccessibilityText: PluginLocalizedText?

    init(text: String, accessibilityText: String? = nil) {
        self.text = text
        self.accessibilityText = accessibilityText
        self.localizedText = nil
        self.localizedAccessibilityText = nil
    }

    init(
        localizedText: PluginLocalizedText,
        accessibilityText: PluginLocalizedText? = nil
    ) {
        self.text = localizedText.fallback
        self.accessibilityText = accessibilityText?.fallback
        self.localizedText = localizedText.translations.isEmpty ? nil : localizedText
        self.localizedAccessibilityText = accessibilityText?.translations.isEmpty == false
            ? accessibilityText
            : nil
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case accessibilityText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let localizedText = try container.decode(PluginLocalizedText.self, forKey: .text)
        let localizedAccessibilityText = try container.decodeIfPresent(
            PluginLocalizedText.self,
            forKey: .accessibilityText
        )
        self.text = localizedText.fallback
        self.accessibilityText = localizedAccessibilityText?.fallback
        self.localizedText = localizedText.translations.isEmpty ? nil : localizedText
        self.localizedAccessibilityText = localizedAccessibilityText?.translations.isEmpty == false
            ? localizedAccessibilityText
            : nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localizedText ?? PluginLocalizedText(text), forKey: .text)
        let accessibility = localizedAccessibilityText ?? accessibilityText.map { PluginLocalizedText($0) }
        try container.encodeIfPresent(accessibility, forKey: .accessibilityText)
    }

    func validate(path: String) throws {
        let textValue = localizedText ?? PluginLocalizedText(text)
        guard PluginLocalizedTextValidation.invalidPath(
            textValue,
            path: "\(path).text",
            maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
            trimWhitespace: true
        ) == nil else {
            throw PluginHTTPJSONSchemaError.invalid("\(path).text")
        }
        let accessibleText = localizedAccessibilityText ?? accessibilityText.map { PluginLocalizedText($0) }
        if let accessibleText,
           PluginLocalizedTextValidation.invalidPath(
               accessibleText,
               path: "\(path).accessibilityText",
               maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
               trimWhitespace: true
           ) != nil {
            throw PluginHTTPJSONSchemaError.invalid("\(path).accessibilityText")
        }
    }

    func payload() -> PluginTextPayload {
        if let localizedText {
            return PluginTextPayload(
                localizedText: localizedText,
                accessibilityText: localizedAccessibilityText
                    ?? accessibilityText.map { PluginLocalizedText($0) }
            )
        }
        if let localizedAccessibilityText {
            return PluginTextPayload(
                localizedText: PluginLocalizedText(text),
                accessibilityText: localizedAccessibilityText
            )
        }
        return PluginTextPayload(text: text, accessibilityText: accessibilityText)
    }
}

struct PluginTextBinding: Codable, Equatable, Sendable {
    let literalText: PluginLocalizedText?
    let path: String?
    let format: PluginBindingFormat?
    let prefixText: PluginLocalizedText?
    let suffixText: PluginLocalizedText?
    let missing: PluginTextFallback?

    var literal: String? { literalText?.fallback }
    var prefix: String? { prefixText?.fallback }
    var suffix: String? { suffixText?.fallback }

    init(
        literal: String? = nil,
        path: String? = nil,
        format: PluginBindingFormat? = nil,
        prefix: String? = nil,
        suffix: String? = nil,
        missing: PluginTextFallback? = nil,
        localizedLiteral: PluginLocalizedText? = nil,
        localizedPrefix: PluginLocalizedText? = nil,
        localizedSuffix: PluginLocalizedText? = nil
    ) {
        self.literalText = localizedLiteral ?? literal.map { PluginLocalizedText($0) }
        self.path = path
        self.format = format
        self.prefixText = localizedPrefix ?? prefix.map { PluginLocalizedText($0) }
        self.suffixText = localizedSuffix ?? suffix.map { PluginLocalizedText($0) }
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case literal
        case path
        case format
        case prefix
        case suffix
        case missing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        literalText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .literal)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        format = try container.decodeIfPresent(PluginBindingFormat.self, forKey: .format)
        prefixText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .prefix)
        suffixText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .suffix)
        missing = try container.decodeIfPresent(PluginTextFallback.self, forKey: .missing)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(literalText, forKey: .literal)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(prefixText, forKey: .prefix)
        try container.encodeIfPresent(suffixText, forKey: .suffix)
        try container.encodeIfPresent(missing, forKey: .missing)
    }

    func validate(path validationPath: String) throws {
        guard (literal == nil) != (path == nil) else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).literal/path")
        }
        if let literalText {
            guard PluginLocalizedTextValidation.invalidPath(
                literalText,
                path: "\(validationPath).literal",
                maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
                trimWhitespace: true
            ) == nil else {
                throw PluginHTTPJSONSchemaError.invalid("\(validationPath).literal")
            }
            guard format == nil, prefixText == nil, suffixText == nil else {
                throw PluginHTTPJSONSchemaError.invalid(validationPath)
            }
        }
        if let path {
            try PluginHTTPJSONValidation.pointer(path, path: "\(validationPath).path")
            if let prefixText {
                guard PluginLocalizedTextValidation.invalidPath(
                    prefixText,
                    path: "\(validationPath).prefix",
                    maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
                    allowEmpty: true
                ) == nil else {
                    throw PluginHTTPJSONSchemaError.invalid("\(validationPath).prefix")
                }
            }
            if let suffixText {
                guard PluginLocalizedTextValidation.invalidPath(
                    suffixText,
                    path: "\(validationPath).suffix",
                    maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
                    allowEmpty: true
                ) == nil else {
                    throw PluginHTTPJSONSchemaError.invalid("\(validationPath).suffix")
                }
            }
        }
        try missing?.validate(path: "\(validationPath).missing")
    }

    func resolve(in root: PluginJSONValue) throws -> PluginTextPayload {
        if let literalText {
            return PluginTextPayload(localizedText: literalText)
        }
        guard let path,
              let value = PluginJSONPointer.resolve(path: path, in: root) else {
            return missing?.payload() ?? PluginTextPayload(text: "—", accessibilityText: "No data")
        }
        let text = PluginHTTPJSONDisplayFormatter.text(
            value: value,
            format: format ?? .text,
            prefix: "",
            suffix: ""
        )
        guard let text else {
            return missing?.payload() ?? PluginTextPayload(text: "—", accessibilityText: "No data")
        }
        let composed = PluginLocalizedText.composed(
            prefix: prefixText,
            value: text,
            suffix: suffixText
        )
        guard PluginLocalizedTextValidation.invalidPath(
            composed,
            path: "binding.result",
            maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
            trimWhitespace: true
        ) == nil else {
            throw PluginHTTPJSONSchemaError.invalid("binding.result")
        }
        return PluginTextPayload(localizedText: composed)
    }
}

struct PluginMetricValueBinding: Codable, Equatable, Sendable {
    let kind: PluginBindingFormat
    let path: String?
    let literalText: PluginLocalizedText?
    let missing: PluginTextFallback?

    var literal: String? { literalText?.fallback }

    init(
        kind: PluginBindingFormat,
        path: String? = nil,
        literal: String? = nil,
        missing: PluginTextFallback? = nil,
        localizedLiteral: PluginLocalizedText? = nil
    ) {
        self.kind = kind
        self.path = path
        self.literalText = localizedLiteral ?? literal.map { PluginLocalizedText($0) }
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case literal
        case missing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(PluginBindingFormat.self, forKey: .kind)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        literalText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .literal)
        missing = try container.decodeIfPresent(PluginTextFallback.self, forKey: .missing)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(literalText, forKey: .literal)
        try container.encodeIfPresent(missing, forKey: .missing)
    }

    func validate(path validationPath: String) throws {
        if kind == .text {
            guard (path == nil) != (literalText == nil) else {
                throw PluginHTTPJSONSchemaError.invalid("\(validationPath).path/literal")
            }
            if let path {
                try PluginHTTPJSONValidation.pointer(path, path: "\(validationPath).path")
            }
            if let literalText {
                guard PluginLocalizedTextValidation.invalidPath(
                    literalText,
                    path: "\(validationPath).literal",
                    maximumUTF8Length: PluginHTTPJSONLimits.maximumMappingTextBytes,
                    trimWhitespace: true
                ) == nil else {
                    throw PluginHTTPJSONSchemaError.invalid("\(validationPath).literal")
                }
            }
        } else {
            guard let path, literalText == nil else {
                throw PluginHTTPJSONSchemaError.invalid("\(validationPath).path")
            }
            try PluginHTTPJSONValidation.pointer(path, path: "\(validationPath).path")
        }
        try missing?.validate(path: "\(validationPath).missing")
    }

    func resolve(in root: PluginJSONValue) throws -> PluginMetricValuePayload {
        if let literalText {
            return PluginMetricValuePayload(text: PluginTextPayload(localizedText: literalText))
        }
        guard let path,
              let value = PluginJSONPointer.resolve(path: path, in: root) else {
            return PluginMetricValuePayload(
                text: (missing ?? PluginTextFallback(text: "—", accessibilityText: "No data")).payload()
            )
        }
        switch kind {
        case .text:
            guard let text = PluginHTTPJSONDisplayFormatter.text(
                value: value,
                format: .text,
                prefix: "",
                suffix: ""
            ) else {
                return PluginMetricValuePayload(
                    text: (missing ?? PluginTextFallback(text: "—", accessibilityText: "No data")).payload()
                )
            }
            return PluginMetricValuePayload(text: PluginTextPayload(text: text))
        case .integer:
            guard case let .integer(integer) = value else { return missingValue() }
            return PluginMetricValuePayload(
                integer: integer,
                display: PluginTextPayload(
                    text: PluginHTTPJSONDisplayFormatter.integer(integer)
                )
            )
        case .decimal:
            guard let number = value.finiteNumber else { return missingValue() }
            let display = PluginHTTPJSONDisplayFormatter.decimal(number)
            return PluginMetricValuePayload(
                decimal: number,
                display: PluginTextPayload(text: display)
            )
        case .currency:
            guard let number = value.finiteNumber else { return missingValue() }
            let display = PluginHTTPJSONDisplayFormatter.currency(number)
            return PluginMetricValuePayload(
                currency: number,
                display: PluginTextPayload(text: display, accessibilityText: display)
            )
        }
    }

    private func missingValue() -> PluginMetricValuePayload {
        PluginMetricValuePayload(
            text: (missing ?? PluginTextFallback(text: "—", accessibilityText: "No data")).payload()
        )
    }
}

struct PluginNumericBinding: Codable, Equatable, Sendable {
    let path: String

    func validate(path validationPath: String) throws {
        try PluginHTTPJSONValidation.pointer(path, path: validationPath)
    }

    func resolve(in root: PluginJSONValue) -> Double? {
        PluginJSONPointer.resolve(path: path, in: root)?.finiteNumber
    }
}

enum PluginNumericComparison: String, Codable, Equatable, Sendable {
    case equals
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
}

struct PluginNumericCondition: Codable, Equatable, Sendable {
    let leftPath: String
    let `operator`: PluginNumericComparison
    let rightPath: String?
    let rightValue: Double?

    init(
        leftPath: String,
        operator: PluginNumericComparison,
        rightPath: String? = nil,
        rightValue: Double? = nil
    ) {
        self.leftPath = leftPath
        self.operator = `operator`
        self.rightPath = rightPath
        self.rightValue = rightValue
    }

    func validate(path validationPath: String) throws {
        try PluginHTTPJSONValidation.pointer(leftPath, path: "\(validationPath).leftPath")
        guard (rightPath == nil) != (rightValue == nil) else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).rightPath/rightValue")
        }
        if let rightPath {
            try PluginHTTPJSONValidation.pointer(rightPath, path: "\(validationPath).rightPath")
        }
        if let rightValue, !rightValue.isFinite {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).rightValue")
        }
    }

    func evaluate(in root: PluginJSONValue) -> Bool? {
        guard let left = PluginJSONPointer.resolve(path: leftPath, in: root)?.finiteNumber else {
            return nil
        }
        let right: Double?
        if let rightPath {
            right = PluginJSONPointer.resolve(path: rightPath, in: root)?.finiteNumber
        } else {
            right = rightValue
        }
        guard let right else { return nil }
        switch `operator` {
        case .equals: return left == right
        case .greaterThan: return left > right
        case .greaterThanOrEqual: return left >= right
        case .lessThan: return left < right
        case .lessThanOrEqual: return left <= right
        }
    }
}

struct PluginStatusBinding: Codable, Equatable, Sendable {
    let kind: PluginStatusKind
    let text: PluginTextBinding

    func validate(path validationPath: String) throws {
        guard kind != .disabled else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).kind")
        }
        try text.validate(path: "\(validationPath).text")
    }

    func payload(in root: PluginJSONValue) throws -> PluginStatusPayload {
        PluginStatusPayload(kind: kind, text: try text.resolve(in: root))
    }
}

struct PluginStatusRule: Codable, Equatable, Sendable {
    let condition: PluginNumericCondition
    let whenTrue: PluginStatusBinding
    let whenFalse: PluginStatusBinding?
    let whenMissing: PluginStatusBinding?

    func validate(path validationPath: String, requireFalse: Bool) throws {
        try condition.validate(path: "\(validationPath).condition")
        try whenTrue.validate(path: "\(validationPath).whenTrue")
        if requireFalse && whenFalse == nil {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).whenFalse")
        }
        try whenFalse?.validate(path: "\(validationPath).whenFalse")
        try whenMissing?.validate(path: "\(validationPath).whenMissing")
    }

    func resolve(in root: PluginJSONValue) throws -> PluginStatusPayload? {
        switch condition.evaluate(in: root) {
        case .some(true): return try whenTrue.payload(in: root)
        case .some(false): return try whenFalse?.payload(in: root)
        case .none: return try whenMissing?.payload(in: root)
        }
    }
}

struct PluginMetricTileTemplate: Codable, Equatable, Sendable {
    let id: String
    let header: PluginTextBinding
    let primary: PluginMetricValueBinding
    let detail: PluginTextBinding?

    func validate(path validationPath: String) throws {
        try PluginHTTPJSONValidation.identifier(id, path: "\(validationPath).id")
        try header.validate(path: "\(validationPath).header")
        try primary.validate(path: "\(validationPath).primary")
        try detail?.validate(path: "\(validationPath).detail")
    }

    func makePayload(in root: PluginJSONValue) throws -> PluginMetricTilePayload {
        PluginMetricTilePayload(
            id: id,
            header: try header.resolve(in: root),
            primary: try primary.resolve(in: root),
            detail: try detail?.resolve(in: root)
        )
    }
}

struct PluginMetricGridTemplate: Codable, Equatable, Sendable {
    let type: String
    let id: String
    let columns: Int
    let tiles: [PluginMetricTileTemplate]

    func validate(path validationPath: String) throws {
        guard type == "metricGrid" else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).type")
        }
        try PluginHTTPJSONValidation.identifier(id, path: "\(validationPath).id")
        guard (1...PluginHTTPJSONLimits.maximumMetricColumns).contains(columns) else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).columns")
        }
        guard !tiles.isEmpty, tiles.count <= PluginHTTPJSONLimits.maximumTiles else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).tiles")
        }
        var identifiers = Set<String>()
        for (index, tile) in tiles.enumerated() {
            guard identifiers.insert(tile.id).inserted else {
                throw PluginHTTPJSONSchemaError.invalid("\(validationPath).tiles")
            }
            try tile.validate(path: "\(validationPath).tiles[\(index)]")
        }
    }

    func makePayload(in root: PluginJSONValue) throws -> PluginMetricGridPayload {
        PluginMetricGridPayload(
            id: id,
            columns: columns,
            tiles: try tiles.map { try $0.makePayload(in: root) }
        )
    }
}

struct PluginProgressHeaderTemplate: Codable, Equatable, Sendable {
    let title: PluginTextBinding
    let subtitle: PluginTextBinding?
    let trailingStatus: PluginStatusRule?

    func validate(path validationPath: String) throws {
        try title.validate(path: "\(validationPath).title")
        try subtitle?.validate(path: "\(validationPath).subtitle")
        try trailingStatus?.validate(path: "\(validationPath).trailingStatus", requireFalse: false)
    }

    func makePayload(in root: PluginJSONValue) throws -> PluginProgressListHeaderPayload {
        let trailing: PluginStatusBadgePayload?
        if let status = try trailingStatus?.resolve(in: root) {
            trailing = PluginStatusBadgePayload(status: status, systemImage: "exclamationmark.triangle.fill")
        } else {
            trailing = nil
        }
        return PluginProgressListHeaderPayload(
            title: try title.resolve(in: root),
            subtitle: try subtitle?.resolve(in: root),
            trailingStatus: trailing
        )
    }
}

struct PluginProgressItemTemplate: Codable, Equatable, Sendable {
    let type: String
    let id: String
    let label: PluginTextBinding
    let current: PluginNumericBinding
    let maximum: PluginNumericBinding
    let valueFormat: PluginBindingFormat
    let statusRule: PluginStatusRule

    func validate(path validationPath: String) throws {
        guard type == "progress" else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).type")
        }
        try PluginHTTPJSONValidation.identifier(id, path: "\(validationPath).id")
        try label.validate(path: "\(validationPath).label")
        try current.validate(path: "\(validationPath).current")
        try maximum.validate(path: "\(validationPath).maximum")
        guard valueFormat == .integer || valueFormat == .decimal || valueFormat == .currency else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).valueFormat")
        }
        try statusRule.validate(path: "\(validationPath).statusRule", requireFalse: true)
    }

    func makePayload(in root: PluginJSONValue) throws -> PluginProgressListItemPayload {
        let label = try label.resolve(in: root)
        guard let maximumValue = maximum.resolve(in: root), maximumValue.isFinite, maximumValue > 0 else {
            let status = try statusRule.resolve(in: root)
                ?? PluginStatusPayload(kind: .noData, text: PluginTextPayload(text: "No data"))
            return .status(PluginStatusItemPayload(
                id: id,
                label: label,
                message: status.text,
                status: PluginStatusPayload(kind: .noData, text: status.text)
            ))
        }
        guard let currentValue = current.resolve(in: root), currentValue.isFinite else {
            let status = try statusRule.resolve(in: root)
                ?? PluginStatusPayload(kind: .noData, text: PluginTextPayload(text: "No data"))
            return .progressUnavailable(PluginProgressUnavailableItemPayload(
                id: id,
                label: label,
                maximum: maximumValue,
                message: status.text,
                status: PluginStatusPayload(kind: .noData, text: status.text)
            ))
        }
        let status = try statusRule.resolve(in: root)
            ?? PluginStatusPayload(kind: .normal, text: PluginTextPayload(text: "Available"))
        guard status.kind == .normal || status.kind == .alert else {
            throw PluginHTTPJSONSchemaError.invalid("progress item \(id) status")
        }
        let valueText = PluginHTTPJSONDisplayFormatter.pair(
            current: currentValue,
            maximum: maximumValue,
            format: valueFormat
        )
        return .progress(PluginProgressItemPayload(
            id: id,
            label: label,
            current: currentValue,
            maximum: maximumValue,
            value: PluginTextPayload(text: valueText),
            status: status
        ))
    }
}

struct PluginProgressListTemplate: Codable, Equatable, Sendable {
    let type: String
    let id: String
    let header: PluginProgressHeaderTemplate
    let items: [PluginProgressItemTemplate]

    func validate(path validationPath: String) throws {
        guard type == "progressList" else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).type")
        }
        try PluginHTTPJSONValidation.identifier(id, path: "\(validationPath).id")
        try header.validate(path: "\(validationPath).header")
        guard !items.isEmpty, items.count <= PluginHTTPJSONLimits.maximumRows else {
            throw PluginHTTPJSONSchemaError.invalid("\(validationPath).items")
        }
        var identifiers = Set<String>()
        for (index, item) in items.enumerated() {
            guard identifiers.insert(item.id).inserted else {
                throw PluginHTTPJSONSchemaError.invalid("\(validationPath).items")
            }
            try item.validate(path: "\(validationPath).items[\(index)]")
        }
    }

    func makePayload(in root: PluginJSONValue) throws -> PluginProgressListPayload {
        PluginProgressListPayload(
            id: id,
            header: try header.makePayload(in: root),
            items: try items.map { try $0.makePayload(in: root) }
        )
    }
}

enum PluginDashboardTemplateBlock: Codable, Equatable, Identifiable, Sendable {
    case metricGrid(PluginMetricGridTemplate)
    case progressList(PluginProgressListTemplate)

    var id: String {
        switch self {
        case let .metricGrid(grid): return grid.id
        case let .progressList(list): return list.id
        }
    }

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "metricGrid": self = .metricGrid(try PluginMetricGridTemplate(from: decoder))
        case "progressList": self = .progressList(try PluginProgressListTemplate(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown dashboard mapping block type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .metricGrid(grid): try grid.encode(to: encoder)
        case let .progressList(list): try list.encode(to: encoder)
        }
    }
}

struct PluginDashboardTemplate: Codable, Equatable, Sendable {
    let version: Int
    let blocks: [PluginDashboardTemplateBlock]

    static let currentVersion = 1

    func validate() throws {
        guard version == Self.currentVersion else {
            throw PluginHTTPJSONSchemaError.invalid("dashboard.version")
        }
        guard !blocks.isEmpty, blocks.count <= PluginHTTPJSONLimits.maximumBlocks else {
            throw PluginHTTPJSONSchemaError.invalid("dashboard.blocks")
        }
        var identifiers = Set<String>()
        for (index, block) in blocks.enumerated() {
            guard identifiers.insert(block.id).inserted else {
                throw PluginHTTPJSONSchemaError.invalid("dashboard.blocks")
            }
            switch block {
            case let .metricGrid(grid): try grid.validate(path: "dashboard.blocks[\(index)]")
            case let .progressList(list): try list.validate(path: "dashboard.blocks[\(index)]")
            }
        }
    }

    func makeDocument(
        pluginID: String,
        response: PluginJSONValue
    ) throws -> PluginDashboardDocument {
        try validate()
        let blocks = try blocks.map { block -> PluginDashboardBlockPayload in
            switch block {
            case let .metricGrid(grid):
                return .metricGrid(try grid.makePayload(in: response))
            case let .progressList(list):
                return .progressList(try list.makePayload(in: response))
            }
        }
        return PluginDashboardDocument(
            protocolVersion: PluginDashboardProtocol.currentVersion,
            pluginID: pluginID,
            lifecycle: PluginLifecyclePayload(kind: .ready, message: nil),
            blocks: blocks
        )
    }
}

enum PluginHTTPJSONValidation {
    static func identifier(_ value: String, path: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
    }

    static func text(_ value: String, path: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= PluginHTTPJSONLimits.maximumMappingTextBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
    }

    static func textFragment(_ value: String, path: String, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !value.isEmpty),
              value.utf8.count <= PluginHTTPJSONLimits.maximumMappingTextBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
    }

    static func pointer(_ value: String, path: String) throws {
        guard value.isEmpty || (value.hasPrefix("/") && value.utf8.count <= PluginHTTPJSONLimits.maximumPointerBytes),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw PluginHTTPJSONSchemaError.invalid(path)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        for component in components.dropFirst() {
            let characters = Array(component)
            for index in characters.indices where characters[index] == "~" {
                guard characters.index(after: index) < characters.endIndex else {
                    throw PluginHTTPJSONSchemaError.invalid(path)
                }
                let next = characters[characters.index(after: index)]
                guard next == "0" || next == "1" else {
                    throw PluginHTTPJSONSchemaError.invalid(path)
                }
            }
        }
    }

    static func headerName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isAllowedHTTPSURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return isAllowedHTTPSURL(url)
    }

    static func isAllowedHTTPSURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }
}

enum PluginJSONPointer {
    static func resolve(path: String, in root: PluginJSONValue) -> PluginJSONValue? {
        guard path.isEmpty || path.hasPrefix("/") else { return nil }
        guard !path.isEmpty else { return root }
        var current = root
        for rawComponent in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            let component = rawComponent
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch current {
            case let .object(object):
                guard let next = object[component] else { return nil }
                current = next
            case let .array(array):
                guard let index = Self.arrayIndex(component), index < array.count else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func arrayIndex(_ component: String) -> Int? {
        guard component == "0"
                || (component.first.map { $0 >= "1" && $0 <= "9" } == true
                    && component.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int(component)
    }
}

private extension PluginJSONValue {
    var finiteNumber: Double? {
        switch self {
        case let .integer(value):
            let number = Double(value)
            return number.isFinite ? number : nil
        case let .decimal(value) where value.isFinite:
            return value
        default:
            return nil
        }
    }
}

enum PluginHTTPJSONDisplayFormatter {
    static func text(
        value: PluginJSONValue,
        format: PluginBindingFormat,
        prefix: String,
        suffix: String
    ) -> String? {
        let valueText: String?
        switch format {
        case .text:
            switch value {
            case let .string(string): valueText = string
            case let .boolean(boolean): valueText = boolean ? "true" : "false"
            case let .integer(integer): valueText = String(integer)
            case let .decimal(number) where number.isFinite: valueText = decimal(number)
            default: valueText = nil
            }
        case .integer:
            guard case let .integer(integer) = value else { return nil }
            valueText = String(integer)
        case .decimal:
            guard let number = value.finiteNumber else { return nil }
            valueText = decimal(number)
        case .currency:
            guard let number = value.finiteNumber else { return nil }
            valueText = currency(number)
        }
        guard let valueText else { return nil }
        return prefix + valueText + suffix
    }

    static func integer(_ value: Int64) -> String { String(value) }

    static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = value < 10 ? 2 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    static func currency(_ value: Double) -> String { "$" + decimal(value) }

    static func pair(current: Double, maximum: Double, format: PluginBindingFormat) -> String {
        switch format {
        case .integer:
            return "\(integer(Int64(current))) / \(integer(Int64(maximum)))"
        case .decimal:
            return "\(decimal(current)) / \(decimal(maximum))"
        case .currency, .text:
            return "\(currency(current)) / \(currency(maximum))"
        }
    }
}
