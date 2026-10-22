import Foundation
import Security

enum PluginConfigurationFieldKind: String, Codable, Equatable, Sendable {
    case text
    case url
    case integer
    case decimal
    case boolean
    case choice
    case secret
}

struct PluginConfigurationOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let labelText: PluginLocalizedText

    var label: String { labelText.fallback }

    func localizedLabel(for language: AppLanguage) -> String {
        labelText.resolve(for: language)
    }

    init(id: String, label: String) {
        self.id = id
        self.labelText = PluginLocalizedText(label)
    }

    init(id: String, labelText: PluginLocalizedText) {
        self.id = id
        self.labelText = labelText
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        labelText = try container.decode(PluginLocalizedText.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(labelText, forKey: .label)
    }
}

struct PluginConfigurationField: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let labelText: PluginLocalizedText
    let kind: PluginConfigurationFieldKind
    let required: Bool
    let defaultValue: PluginJSONValue?
    let placeholderText: PluginLocalizedText?
    let options: [PluginConfigurationOption]?

    var label: String { labelText.fallback }
    var placeholder: String? { placeholderText?.fallback }

    func localizedLabel(for language: AppLanguage) -> String {
        labelText.resolve(for: language)
    }

    func localizedPlaceholder(for language: AppLanguage) -> String? {
        placeholderText?.resolve(for: language)
    }

    init(
        id: String,
        label: String,
        kind: PluginConfigurationFieldKind,
        required: Bool = false,
        defaultValue: PluginJSONValue? = nil,
        placeholder: String? = nil,
        options: [PluginConfigurationOption]? = nil
    ) {
        self.id = id
        self.labelText = PluginLocalizedText(label)
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.placeholderText = placeholder.map { PluginLocalizedText($0) }
        self.options = options
    }

    init(
        id: String,
        labelText: PluginLocalizedText,
        kind: PluginConfigurationFieldKind,
        required: Bool = false,
        defaultValue: PluginJSONValue? = nil,
        placeholderText: PluginLocalizedText? = nil,
        options: [PluginConfigurationOption]? = nil
    ) {
        self.id = id
        self.labelText = labelText
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.placeholderText = placeholderText
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case kind
        case required
        case defaultValue
        case placeholder
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        labelText = try container.decode(PluginLocalizedText.self, forKey: .label)
        kind = try container.decode(PluginConfigurationFieldKind.self, forKey: .kind)
        required = try container.decode(Bool.self, forKey: .required)
        defaultValue = try container.decodeIfPresent(PluginJSONValue.self, forKey: .defaultValue)
        placeholderText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .placeholder)
        options = try container.decodeIfPresent([PluginConfigurationOption].self, forKey: .options)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(labelText, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(required, forKey: .required)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(placeholderText, forKey: .placeholder)
        try container.encodeIfPresent(options, forKey: .options)
    }
}

struct PluginConfigurationSchema: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumFields = 32
    static let maximumOptionsPerField = 64

    let version: Int
    let titleText: PluginLocalizedText?
    let descriptionText: PluginLocalizedText?
    let fields: [PluginConfigurationField]

    var title: String? { titleText?.fallback }
    var description: String? { descriptionText?.fallback }

    func localizedTitle(for language: AppLanguage) -> String? {
        titleText?.resolve(for: language)
    }

    func localizedDescription(for language: AppLanguage) -> String? {
        descriptionText?.resolve(for: language)
    }

    init(
        version: Int = Self.currentVersion,
        title: String? = nil,
        description: String? = nil,
        fields: [PluginConfigurationField],
        localizedTitle: PluginLocalizedText? = nil,
        localizedDescription: PluginLocalizedText? = nil
    ) {
        self.version = version
        self.titleText = localizedTitle ?? title.map { PluginLocalizedText($0) }
        self.descriptionText = localizedDescription ?? description.map { PluginLocalizedText($0) }
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case title
        case description
        case fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        titleText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .title)
        descriptionText = try container.decodeIfPresent(PluginLocalizedText.self, forKey: .description)
        fields = try container.decode([PluginConfigurationField].self, forKey: .fields)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(titleText, forKey: .title)
        try container.encodeIfPresent(descriptionText, forKey: .description)
        try container.encode(fields, forKey: .fields)
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw PluginConfigurationSchemaError.unsupportedVersion(version)
        }
        if let titleText {
            guard PluginLocalizedTextValidation.invalidPath(
                titleText,
                path: "configuration.title",
                maximumUTF8Length: 200,
                allowEmpty: true
            ) == nil else {
                throw PluginConfigurationSchemaError.invalidText("configuration.title")
            }
        }
        if let descriptionText {
            guard PluginLocalizedTextValidation.invalidPath(
                descriptionText,
                path: "configuration.description",
                maximumUTF8Length: 1_000,
                allowEmpty: true
            ) == nil else {
                throw PluginConfigurationSchemaError.invalidText("configuration.description")
            }
        }
        guard fields.count <= Self.maximumFields else {
            throw PluginConfigurationSchemaError.tooManyFields
        }

        var fieldIDs = Set<String>()
        for (index, field) in fields.enumerated() {
            let path = "configuration.fields[\(index)]"
            try validateIdentifier(field.id, path: "\(path).id")
            guard fieldIDs.insert(field.id).inserted else {
                throw PluginConfigurationSchemaError.duplicateIdentifier(field.id)
            }
            guard PluginLocalizedTextValidation.invalidPath(
                field.labelText,
                path: "\(path).label",
                maximumUTF8Length: 200,
                allowEmpty: true
            ) == nil else {
                throw PluginConfigurationSchemaError.invalidText("\(path).label")
            }
            if let placeholderText = field.placeholderText {
                guard PluginLocalizedTextValidation.invalidPath(
                    placeholderText,
                    path: "\(path).placeholder",
                    maximumUTF8Length: 300,
                    allowEmpty: true
                ) == nil else {
                    throw PluginConfigurationSchemaError.invalidText("\(path).placeholder")
                }
            }

            switch field.kind {
            case .choice:
                try validateOptions(field.options, path: "\(path).options")
            case .secret:
                guard field.options == nil else {
                    throw PluginConfigurationSchemaError.unsupportedOptions("\(path).options")
                }
                guard field.defaultValue == nil else {
                    throw PluginConfigurationSchemaError.secretDefault(field.id)
                }
            default:
                guard field.options == nil else {
                    throw PluginConfigurationSchemaError.unsupportedOptions("\(path).options")
                }
            }

            if let defaultValue = field.defaultValue {
                _ = try normalize(defaultValue, for: field, path: "\(path).default")
            }
        }
    }

    func makeEffectiveValues(
        publicValues: [String: PluginJSONValue],
        secretValues: [String: String]
    ) throws -> [String: PluginJSONValue] {
        try validate()
        var result = [String: PluginJSONValue]()
        let fieldsByID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })

        for key in publicValues.keys where fieldsByID[key]?.kind == .secret {
            throw PluginConfigurationSchemaError.secretValueStoredPublic(key)
        }
        for key in secretValues.keys where fieldsByID[key]?.kind != .secret {
            throw PluginConfigurationSchemaError.unexpectedSecretValue(key)
        }

        for field in fields {
            let candidate: PluginJSONValue?
            if field.kind == .secret {
                candidate = secretValues[field.id].map(PluginJSONValue.string)
            } else {
                candidate = publicValues[field.id] ?? field.defaultValue
            }

            guard let candidate else {
                if field.required {
                    throw PluginConfigurationSchemaError.missingRequiredValue(field.id)
                }
                continue
            }
            if case .null = candidate {
                if field.required {
                    throw PluginConfigurationSchemaError.missingRequiredValue(field.id)
                }
                continue
            }

            let value = try normalize(candidate, for: field, path: "configuration.\(field.id)")
            if isEmptyString(value) {
                if field.required {
                    throw PluginConfigurationSchemaError.missingRequiredValue(field.id)
                }
                continue
            }
            result[field.id] = value
        }
        return result
    }

    /// Validates the merged in-memory object that a transport receives.
    ///
    /// Public configuration files and Keychain values are validated separately
    /// while they are stored. A transport can also be constructed directly in
    /// tests or by a future host integration, so it must not assume that an
    /// arbitrary JSON object has passed through `PluginConfigurationStore`.
    /// Secret values are accepted here because this method is only for the
    /// already-merged, in-memory request object.
    func validateEffectiveValues(_ values: [String: PluginJSONValue]) throws {
        try validate()
        let fieldsByID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        var publicValues = [String: PluginJSONValue]()
        var secretValues = [String: String]()

        for (key, value) in values {
            guard let field = fieldsByID[key] else {
                throw PluginConfigurationSchemaError.invalidValue("configuration.\(key)")
            }
            if field.kind == .secret {
                guard case let .string(secret) = value else {
                    throw PluginConfigurationSchemaError.invalidValue("configuration.\(key)")
                }
                secretValues[key] = secret
            } else {
                publicValues[key] = value
            }
        }

        _ = try makeEffectiveValues(
            publicValues: publicValues,
            secretValues: secretValues
        )
    }

    private func validateOptions(
        _ options: [PluginConfigurationOption]?,
        path: String
    ) throws {
        guard let options, !options.isEmpty, options.count <= Self.maximumOptionsPerField else {
            throw PluginConfigurationSchemaError.invalidOptions(path)
        }
        var optionIDs = Set<String>()
        for (index, option) in options.enumerated() {
            try validateIdentifier(option.id, path: "\(path)[\(index)].id")
            guard PluginLocalizedTextValidation.invalidPath(
                option.labelText,
                path: "\(path)[\(index)].label",
                maximumUTF8Length: 200,
                allowEmpty: true
            ) == nil else {
                throw PluginConfigurationSchemaError.invalidText("\(path)[\(index)].label")
            }
            guard optionIDs.insert(option.id).inserted else {
                throw PluginConfigurationSchemaError.duplicateOptionIdentifier(option.id)
            }
        }
    }

    private func normalize(
        _ value: PluginJSONValue,
        for field: PluginConfigurationField,
        path: String
    ) throws -> PluginJSONValue {
        switch field.kind {
        case .text, .secret:
            guard case let .string(string) = value else {
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
            try validateText(string, path: path, maximumUTF8Length: 4_000)
            return .string(string)
        case .url:
            guard case let .string(string) = value else {
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
            try validateText(string, path: path, maximumUTF8Length: 4_000)
            if !string.isEmpty, URL(string: string) == nil {
                throw PluginConfigurationSchemaError.invalidURL(path)
            }
            return .string(string)
        case .integer:
            guard case .integer = value else {
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
            return value
        case .decimal:
            switch value {
            case let .integer(integer):
                return .decimal(Double(integer))
            case let .decimal(decimal) where decimal.isFinite:
                return .decimal(decimal)
            default:
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
        case .boolean:
            guard case .boolean = value else {
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
            return value
        case .choice:
            guard case let .string(string) = value,
                  let options = field.options,
                  options.contains(where: { $0.id == string }) else {
                throw PluginConfigurationSchemaError.invalidValue(path)
            }
            return .string(string)
        }
    }

    private func validateIdentifier(_ value: String, path: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw PluginConfigurationSchemaError.invalidIdentifier(path)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PluginConfigurationSchemaError.invalidIdentifier(path)
        }
    }

    private func validateText(_ value: String, path: String, maximumUTF8Length: Int) throws {
        guard value.utf8.count <= maximumUTF8Length,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginConfigurationSchemaError.invalidText(path)
        }
    }

    private func isEmptyString(_ value: PluginJSONValue) -> Bool {
        guard case let .string(string) = value else { return false }
        return string.isEmpty
    }
}

enum PluginConfigurationSchemaError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case tooManyFields
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case invalidText(String)
    case invalidOptions(String)
    case unsupportedOptions(String)
    case duplicateOptionIdentifier(String)
    case secretDefault(String)
    case invalidValue(String)
    case invalidURL(String)
    case missingRequiredValue(String)
    case secretValueStoredPublic(String)
    case unexpectedSecretValue(String)
}

extension PluginConfigurationSchemaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): return "Unsupported plugin configuration schema version: \(version)."
        case .tooManyFields: return "The plugin configuration has too many fields."
        case let .invalidIdentifier(path): return "Invalid plugin configuration identifier at \(path)."
        case let .duplicateIdentifier(identifier): return "Duplicate plugin configuration identifier: \(identifier)."
        case let .invalidText(path): return "Invalid plugin configuration text at \(path)."
        case let .invalidOptions(path): return "Invalid plugin configuration options at \(path)."
        case let .unsupportedOptions(path): return "Options are not supported at \(path)."
        case let .duplicateOptionIdentifier(identifier): return "Duplicate plugin configuration option: \(identifier)."
        case let .secretDefault(identifier): return "Secret field \(identifier) must not declare a default."
        case let .invalidValue(path): return "Invalid plugin configuration value at \(path)."
        case let .invalidURL(path): return "Invalid plugin configuration URL at \(path)."
        case let .missingRequiredValue(identifier): return "Required plugin configuration is missing: \(identifier)."
        case let .secretValueStoredPublic(identifier): return "Secret configuration must not be stored as a public value: \(identifier)."
        case let .unexpectedSecretValue(identifier): return "Unexpected secret configuration value: \(identifier)."
        }
    }
}

struct PluginConfigurationDraft: Equatable, Sendable {
    let publicValues: [String: PluginJSONValue]
    let configuredSecretIDs: Set<String>
}

struct PluginConfigurationSubmission: Equatable, Sendable {
    let publicValues: [String: PluginJSONValue]
    let secretValues: [String: String]
    let clearSecretIDs: Set<String>
}

protocol PluginSecretStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// The narrow credential seam used by token-refresh sessions. It deliberately
/// exposes only the declared plugin secret field, never the public
/// configuration document or an arbitrary Keychain account.
protocol PluginRefreshCredentialStore: Sendable {
    func read(pluginID: String, fieldID: String) throws -> String?
    func write(_ value: String, pluginID: String, fieldID: String) throws
}

struct PluginConfigurationCredentialStore: PluginRefreshCredentialStore {
    private let secretStore: any PluginSecretStore

    init(secretStore: any PluginSecretStore) {
        self.secretStore = secretStore
    }

    func read(pluginID: String, fieldID: String) throws -> String? {
        let account = try PluginConfigurationStore.secretAccount(
            pluginID: pluginID,
            fieldID: fieldID
        )
        guard let data = try secretStore.read(
            service: PluginConfigurationStore.secretService,
            account: account
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty,
              value.utf8.count <= 4_000,
              !value.contains("\n"),
              !value.contains("\r") else {
            throw PluginSecretStoreError.invalidStoredData
        }
        return value
    }

    func write(_ value: String, pluginID: String, fieldID: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 4_000,
              !value.contains("\n"),
              !value.contains("\r") else {
            throw PluginSecretStoreError.invalidStoredData
        }
        let account = try PluginConfigurationStore.secretAccount(
            pluginID: pluginID,
            fieldID: fieldID
        )
        try secretStore.write(
            Data(value.utf8),
            service: PluginConfigurationStore.secretService,
            account: account
        )
    }
}

enum PluginSecretStoreError: Error, Equatable, Sendable {
    case operationFailed(Int32)
    case invalidStoredData
}

struct KeychainSecretStore: PluginSecretStore {
    func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            keychainQuery(service: service, account: account, returningData: true) as CFDictionary,
            &result
        )
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw PluginSecretStoreError.invalidStoredData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PluginSecretStoreError.operationFailed(status)
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        let identity = keychainQuery(service: service, account: account, returningData: false)
        var addQuery = identity
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else {
            guard addStatus == errSecSuccess else {
                throw PluginSecretStoreError.operationFailed(addStatus)
            }
            return
        }

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw PluginSecretStoreError.operationFailed(updateStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(keychainQuery(service: service, account: account, returningData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PluginSecretStoreError.operationFailed(status)
        }
    }

    private func keychainQuery(service: String, account: String, returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

enum PluginConfigurationError: Error, Equatable, Sendable {
    case invalidPluginIdentifier
    case invalidJSON
    case pluginNotInstalled
    case schemaRequired
    case secretPersistenceFailed
}

extension PluginConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPluginIdentifier:
            return "The plugin identifier is invalid."
        case .invalidJSON:
            return "Plugin configuration must be a JSON object."
        case .pluginNotInstalled:
            return "The external plugin is not installed."
        case .schemaRequired:
            return "This plugin does not declare a configuration schema."
        case .secretPersistenceFailed:
            return "The plugin secret could not be saved securely."
        }
    }
}

struct PluginConfigurationStore {
    private let fileManager: FileManager
    private let baseURL: URL
    private let secretStore: any PluginSecretStore

    static let secretService = AppIdentity.pluginSecretService

    init(
        fileManager: FileManager = .default,
        baseURL: URL? = nil,
        secretStore: any PluginSecretStore = KeychainSecretStore()
    ) {
        self.fileManager = fileManager
        self.baseURL = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("PluginConfigurations", isDirectory: true)
        self.secretStore = secretStore
    }

    var refreshCredentialStore: any PluginRefreshCredentialStore {
        PluginConfigurationCredentialStore(secretStore: secretStore)
    }

    func load(pluginID: String) throws -> Data? {
        let url = try configurationURL(for: pluginID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        try validateJSONDocument(data)
        return data
    }

    func save(_ data: Data, pluginID: String) throws {
        let url = try configurationURL(for: pluginID)
        try validateJSONDocument(data)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func remove(pluginID: String) throws {
        let url = try configurationURL(for: pluginID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func loadDraft(
        pluginID: String,
        schema: PluginConfigurationSchema
    ) throws -> PluginConfigurationDraft {
        try validatePluginSchema(schema)
        let publicValues = try loadPublicValues(pluginID: pluginID)
        var configuredSecretIDs = Set<String>()
        for field in schema.fields where field.kind == .secret {
            if try loadSecret(pluginID: pluginID, fieldID: field.id) != nil {
                configuredSecretIDs.insert(field.id)
            }
        }
        return PluginConfigurationDraft(
            publicValues: publicValues,
            configuredSecretIDs: configuredSecretIDs
        )
    }

    func loadEffectiveConfigurationData(
        pluginID: String,
        schema: PluginConfigurationSchema?
    ) throws -> Data? {
        guard let schema else {
            return try load(pluginID: pluginID)
        }
        try validatePluginSchema(schema)
        let publicValues = try loadPublicValues(pluginID: pluginID)
        var secretValues = [String: String]()
        for field in schema.fields where field.kind == .secret {
            if let value = try loadSecret(pluginID: pluginID, fieldID: field.id) {
                secretValues[field.id] = value
            }
        }
        let effective = try schema.makeEffectiveValues(
            publicValues: publicValues,
            secretValues: secretValues
        )
        return try JSONEncoder().encode(PluginJSONValue.object(effective))
    }

    func save(
        _ submission: PluginConfigurationSubmission,
        pluginID: String,
        schema: PluginConfigurationSchema
    ) throws {
        try validatePluginSchema(schema)
        var existingSecrets = [String: String]()
        for field in schema.fields where field.kind == .secret {
            if let value = try loadSecret(pluginID: pluginID, fieldID: field.id) {
                existingSecrets[field.id] = value
            }
        }

        var nextSecrets = existingSecrets
        for field in schema.fields where field.kind == .secret {
            if submission.clearSecretIDs.contains(field.id) {
                nextSecrets.removeValue(forKey: field.id)
            } else if let value = submission.secretValues[field.id], !value.isEmpty {
                nextSecrets[field.id] = value
            }
        }
        let effective = try schema.makeEffectiveValues(
            publicValues: submission.publicValues,
            secretValues: nextSecrets
        )
        let publicValues = effective.filter { key, _ in
            schema.fields.first(where: { $0.id == key })?.kind != .secret
        }
        let publicData = try JSONEncoder().encode(PluginJSONValue.object(publicValues))

        do {
            for field in schema.fields where field.kind == .secret {
                if submission.clearSecretIDs.contains(field.id) {
                    try deleteSecret(pluginID: pluginID, fieldID: field.id)
                } else if let value = submission.secretValues[field.id], !value.isEmpty {
                    try saveSecret(value, pluginID: pluginID, fieldID: field.id)
                }
            }
        } catch {
            // Keep the public configuration untouched when a Keychain write
            // fails. Restore any earlier field updates before reporting the
            // failure so the next refresh cannot combine old public values
            // with a partially updated secret set.
            restoreSecrets(existingSecrets, schema: schema, pluginID: pluginID)
            throw PluginConfigurationError.secretPersistenceFailed
        }

        do {
            try save(publicData, pluginID: pluginID)
        } catch {
            // The public file was not committed, so restore the Keychain state
            // to keep the two stores aligned on a failed save.
            restoreSecrets(existingSecrets, schema: schema, pluginID: pluginID)
            throw error
        }
    }

    func removeConfiguration(
        pluginID: String,
        schema: PluginConfigurationSchema?
    ) throws {
        guard let schema else {
            try remove(pluginID: pluginID)
            return
        }
        try validatePluginSchema(schema)

        var existingSecrets = [String: String]()
        for field in schema.fields where field.kind == .secret {
            if let value = try loadSecret(pluginID: pluginID, fieldID: field.id) {
                existingSecrets[field.id] = value
            }
        }

        do {
            for field in schema.fields where field.kind == .secret {
                try deleteSecret(pluginID: pluginID, fieldID: field.id)
            }
        } catch {
            restoreSecrets(existingSecrets, schema: schema, pluginID: pluginID)
            throw PluginConfigurationError.secretPersistenceFailed
        }

        do {
            try remove(pluginID: pluginID)
        } catch {
            restoreSecrets(existingSecrets, schema: schema, pluginID: pluginID)
            throw error
        }
    }

    private func loadPublicValues(pluginID: String) throws -> [String: PluginJSONValue] {
        guard let data = try load(pluginID: pluginID) else { return [:] }
        let value: PluginJSONValue
        do {
            value = try JSONDecoder().decode(PluginJSONValue.self, from: data)
        } catch {
            throw PluginConfigurationError.invalidJSON
        }
        guard case let .object(values) = value else {
            throw PluginConfigurationError.invalidJSON
        }
        return values
    }

    private func validatePluginSchema(_ schema: PluginConfigurationSchema) throws {
        do {
            try schema.validate()
        } catch let error as PluginConfigurationSchemaError {
            throw error
        } catch {
            throw PluginConfigurationError.invalidJSON
        }
    }

    static func secretAccount(pluginID: String, fieldID: String) throws -> String {
        guard Self.isValidPluginIdentifier(pluginID), Self.isValidPluginIdentifier(fieldID) else {
            throw PluginConfigurationError.invalidPluginIdentifier
        }
        // Length prefixes keep the Keychain account unambiguous even though
        // both identifiers may contain dots.
        return String(pluginID.utf8.count)
            + ":"
            + pluginID
            + "|"
            + String(fieldID.utf8.count)
            + ":"
            + fieldID
    }

    private func secretAccount(pluginID: String, fieldID: String) throws -> String {
        try Self.secretAccount(pluginID: pluginID, fieldID: fieldID)
    }

    private func loadSecret(pluginID: String, fieldID: String) throws -> String? {
        let account = try secretAccount(pluginID: pluginID, fieldID: fieldID)
        guard let data = try secretStore.read(service: Self.secretService, account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw PluginConfigurationError.secretPersistenceFailed
        }
        return value
    }

    private func saveSecret(_ value: String, pluginID: String, fieldID: String) throws {
        guard !value.contains("\n"), !value.contains("\r") else {
            throw PluginConfigurationError.secretPersistenceFailed
        }
        let account = try secretAccount(pluginID: pluginID, fieldID: fieldID)
        try secretStore.write(Data(value.utf8), service: Self.secretService, account: account)
    }

    private func deleteSecret(pluginID: String, fieldID: String) throws {
        let account = try secretAccount(pluginID: pluginID, fieldID: fieldID)
        try secretStore.delete(service: Self.secretService, account: account)
    }

    private func restoreSecrets(
        _ values: [String: String],
        schema: PluginConfigurationSchema,
        pluginID: String
    ) {
        for field in schema.fields where field.kind == .secret {
            do {
                if let value = values[field.id] {
                    try saveSecret(value, pluginID: pluginID, fieldID: field.id)
                } else {
                    try deleteSecret(pluginID: pluginID, fieldID: field.id)
                }
            } catch {
                // Best effort: the original persistence error is more useful
                // than masking it with a rollback failure.
            }
        }
    }

    private func configurationURL(for pluginID: String) throws -> URL {
        guard Self.isValidPluginIdentifier(pluginID) else {
            throw PluginConfigurationError.invalidPluginIdentifier
        }
        return baseURL.appendingPathComponent("\(pluginID).json", isDirectory: false)
    }

    private func validateJSONDocument(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            throw PluginConfigurationError.invalidJSON
        }
    }

    private static func isValidPluginIdentifier(_ value: String) -> Bool {
        PluginIdentifier.isValid(value)
    }
}
