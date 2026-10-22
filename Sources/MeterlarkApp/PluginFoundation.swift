import Foundation

enum PluginIdentifier {
    static let maximumUTF8Length = 128

    /// Plugin IDs are also used as directory and configuration-file
    /// components. Keep the manifest identity grammar aligned with that
    /// filesystem use instead of accepting path-like dot components.
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Length else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty }
    }
}

enum PluginManifestFileError: Error, Equatable, Sendable {
    case tooLarge
    case unreadable
}

enum PluginManifestLoader {
    static let maximumManifestBytes = 512 * 1024

    static func load(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> PluginManifest {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            throw PluginManifestFileError.unreadable
        }
        guard size.intValue <= maximumManifestBytes else {
            throw PluginManifestFileError.tooLarge
        }

        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maximumManifestBytes else {
                throw PluginManifestFileError.tooLarge
            }
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as PluginManifestFileError {
            throw error
        } catch {
            throw PluginManifestFileError.unreadable
        }
    }
}

enum PluginTransportKind: String, Codable, Equatable, Sendable {
    case metadataOnly = "metadata"
    case stdioJSON = "stdio-json"
    case httpJSON = "http-json"
}

enum PluginCapability: String, Codable, Equatable, Sendable {
    case dashboard
    case modelCatalog = "model-catalog"
}

enum PluginManifestValidationError: Error, Equatable, Sendable {
    case unsupportedManifestVersion(Int)
    case unsupportedProtocolVersion(Int)
    case invalidIdentifier
    case invalidDisplayName
    case invalidVersion
    case missingEntrypoint
    case invalidEntrypoint
    case unexpectedEntrypoint
    case invalidConfigurationSchema(String)
    case missingHTTPDefinition
    case missingDashboardDefinition
    case unexpectedHTTPDefinition
    case unexpectedDashboardDefinition
    case invalidCapabilities
    case missingCapabilityDefinition
    case tokenRefreshRequiresProtocolV2
    case missingTokenRefreshDefinition
    case invalidHTTPDefinition(String)
    case invalidDashboardDefinition(String)
}

extension PluginManifestValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedManifestVersion(version):
            return "Unsupported plugin manifest version: \(version)"
        case let .unsupportedProtocolVersion(version):
            return "Unsupported plugin protocol version: \(version)"
        case .invalidIdentifier:
            return "Plugin identifier must contain only letters, digits, '.', '_' or '-'."
        case .invalidDisplayName:
            return "Plugin display name must be a non-empty single-line value."
        case .invalidVersion:
            return "Plugin version must be a non-empty single-line value."
        case .missingEntrypoint:
            return "An external plugin transport requires an entrypoint."
        case .invalidEntrypoint:
            return "Plugin entrypoint must be a safe relative path inside the package."
        case .unexpectedEntrypoint:
            return "A metadata-only plugin must not declare an executable entrypoint."
        case let .invalidConfigurationSchema(detail):
            return "The plugin configuration schema is invalid: \(detail)"
        case .missingHTTPDefinition:
            return "An http-json plugin must declare an HTTP request definition."
        case .missingDashboardDefinition:
            return "An http-json plugin must declare a dashboard definition."
        case .unexpectedHTTPDefinition:
            return "Only an http-json plugin may declare an HTTP request definition."
        case .unexpectedDashboardDefinition:
            return "Only an http-json plugin may declare a dashboard definition."
        case .invalidCapabilities:
            return "Plugin capabilities must be unique and supported."
        case .missingCapabilityDefinition:
            return "An http-json plugin must declare a supported capability."
        case .tokenRefreshRequiresProtocolV2:
            return "Token refresh requires plugin protocol version 2."
        case .missingTokenRefreshDefinition:
            return "Plugin protocol version 2 requires a token-refresh definition."
        case let .invalidHTTPDefinition(detail):
            return "The plugin HTTP definition is invalid: \(detail)"
        case let .invalidDashboardDefinition(detail):
            return "The plugin dashboard definition is invalid: \(detail)"
        }
    }
}

struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentManifestVersion = 1
    static let minimumProtocolVersion = 1
    static let currentProtocolVersion = 2

    let manifestVersion: Int
    let id: String
    let displayNameText: PluginLocalizedText
    let version: String
    let protocolVersion: Int
    let transport: PluginTransportKind
    let capabilities: [PluginCapability]
    let entrypoint: String?
    let configuration: PluginConfigurationSchema?
    let http: PluginHTTPJSONDefinition?
    let dashboard: PluginDashboardTemplate?

    /// The legacy fallback remains available as `displayName` so existing host
    /// integrations do not need to change just because a manifest adds
    /// translations.
    var displayName: String { displayNameText.fallback }

    var supportsDashboard: Bool { capabilities.contains(.dashboard) }
    var supportsModelCatalog: Bool { capabilities.contains(.modelCatalog) }

    func localizedDisplayName(for language: AppLanguage) -> String {
        displayNameText.resolve(for: language)
    }

    init(
        manifestVersion: Int,
        id: String,
        displayName: String,
        version: String,
        protocolVersion: Int,
        transport: PluginTransportKind = .metadataOnly,
        capabilities: [PluginCapability]? = nil,
        entrypoint: String? = nil,
        configuration: PluginConfigurationSchema? = nil,
        http: PluginHTTPJSONDefinition? = nil,
        dashboard: PluginDashboardTemplate? = nil,
        localizedDisplayName: PluginLocalizedText? = nil
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.displayNameText = localizedDisplayName ?? PluginLocalizedText(displayName)
        self.version = version
        self.protocolVersion = protocolVersion
        self.transport = transport
        self.capabilities = capabilities
            ?? (transport == .metadataOnly ? [] : [.dashboard])
        self.entrypoint = entrypoint
        self.configuration = configuration
        self.http = http
        self.dashboard = dashboard
    }

    private enum CodingKeys: String, CodingKey {
        case manifestVersion
        case id
        case displayName
        case version
        case protocolVersion
        case transport
        case capabilities
        case entrypoint
        case configuration
        case http
        case dashboard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try container.decode(Int.self, forKey: .manifestVersion)
        id = try container.decode(String.self, forKey: .id)
        displayNameText = try container.decode(PluginLocalizedText.self, forKey: .displayName)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        transport = try container.decodeIfPresent(PluginTransportKind.self, forKey: .transport) ?? .metadataOnly
        entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
        configuration = try container.decodeIfPresent(PluginConfigurationSchema.self, forKey: .configuration)
        http = try container.decodeIfPresent(PluginHTTPJSONDefinition.self, forKey: .http)
        dashboard = try container.decodeIfPresent(PluginDashboardTemplate.self, forKey: .dashboard)
        capabilities = try container.decodeIfPresent([PluginCapability].self, forKey: .capabilities)
            ?? (transport == .metadataOnly ? [] : [.dashboard])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifestVersion, forKey: .manifestVersion)
        try container.encode(id, forKey: .id)
        try container.encode(displayNameText, forKey: .displayName)
        try container.encode(version, forKey: .version)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        if transport != .metadataOnly {
            try container.encode(transport, forKey: .transport)
        }
        if !capabilities.isEmpty {
            try container.encode(capabilities, forKey: .capabilities)
        }
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(http, forKey: .http)
        try container.encodeIfPresent(dashboard, forKey: .dashboard)
    }

    func validate(
        supportedManifestVersion: Int = Self.currentManifestVersion,
        supportedProtocolVersion: Int = Self.currentProtocolVersion
    ) throws {
        guard manifestVersion == supportedManifestVersion else {
            throw PluginManifestValidationError.unsupportedManifestVersion(manifestVersion)
        }
        guard (Self.minimumProtocolVersion...supportedProtocolVersion).contains(protocolVersion) else {
            throw PluginManifestValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard Self.isValidIdentifier(id) else {
            throw PluginManifestValidationError.invalidIdentifier
        }
        guard PluginLocalizedTextValidation.invalidPath(
            displayNameText,
            path: "displayName",
            maximumUTF8Length: 200,
            trimWhitespace: true
        ) == nil else {
            throw PluginManifestValidationError.invalidDisplayName
        }
        guard Self.isValidVersion(version) else {
            throw PluginManifestValidationError.invalidVersion
        }
        guard Set(capabilities).count == capabilities.count else {
            throw PluginManifestValidationError.invalidCapabilities
        }
        if let configuration {
            do {
                try configuration.validate()
            } catch {
                throw PluginManifestValidationError.invalidConfigurationSchema(
                    Self.safeConfigurationErrorMessage(error)
                )
            }
        }
        switch transport {
        case .metadataOnly:
            guard capabilities.isEmpty else {
                throw PluginManifestValidationError.invalidCapabilities
            }
            guard entrypoint == nil else {
                throw PluginManifestValidationError.unexpectedEntrypoint
            }
            guard http == nil else {
                throw PluginManifestValidationError.unexpectedHTTPDefinition
            }
            guard dashboard == nil else {
                throw PluginManifestValidationError.unexpectedDashboardDefinition
            }
        case .stdioJSON:
            guard capabilities == [.dashboard] else {
                throw PluginManifestValidationError.invalidCapabilities
            }
            guard let entrypoint else {
                throw PluginManifestValidationError.missingEntrypoint
            }
            guard Self.isValidEntrypoint(entrypoint) else {
                throw PluginManifestValidationError.invalidEntrypoint
            }
            guard http == nil else {
                throw PluginManifestValidationError.unexpectedHTTPDefinition
            }
            guard dashboard == nil else {
                throw PluginManifestValidationError.unexpectedDashboardDefinition
            }
        case .httpJSON:
            guard entrypoint == nil else {
                throw PluginManifestValidationError.unexpectedEntrypoint
            }
            guard let http else {
                throw PluginManifestValidationError.missingHTTPDefinition
            }
            guard !capabilities.isEmpty,
                  capabilities.allSatisfy({ $0 == .dashboard || $0 == .modelCatalog }) else {
                throw PluginManifestValidationError.invalidCapabilities
            }
            guard supportsDashboard || supportsModelCatalog else {
                throw PluginManifestValidationError.missingCapabilityDefinition
            }
            if supportsDashboard {
                guard dashboard != nil else {
                    throw PluginManifestValidationError.missingDashboardDefinition
                }
            } else {
                guard dashboard == nil else {
                    throw PluginManifestValidationError.invalidCapabilities
                }
            }
            if protocolVersion == 1, http.auth != nil {
                throw PluginManifestValidationError.tokenRefreshRequiresProtocolV2
            }
            if protocolVersion == 2, http.auth == nil {
                throw PluginManifestValidationError.missingTokenRefreshDefinition
            }
            do {
                try http.validate(configuration: configuration)
            } catch {
                throw PluginManifestValidationError.invalidHTTPDefinition(
                    Self.safeConfigurationErrorMessage(error)
                )
            }
            if supportsDashboard, let dashboard {
                do {
                    try dashboard.validate()
                } catch {
                    throw PluginManifestValidationError.invalidDashboardDefinition(
                        Self.safeConfigurationErrorMessage(error)
                    )
                }
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        PluginIdentifier.isValid(value)
    }

    private static func isValidVersion(_ value: String) -> Bool {
        guard isValidSingleLineText(value, maximumUTF8Length: 100) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isValidEntrypoint(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 256,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func isValidSingleLineText(_ value: String, maximumUTF8Length: Int) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumUTF8Length else {
            return false
        }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func safeConfigurationErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(message.prefix(240))
    }
}

enum PluginLocations {
    static func userPluginDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    static func bundledPluginDirectory(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let directory = resourceURL.appendingPathComponent("Plugins", isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return directory
    }
}

struct DiscoveredPlugin: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let packageURL: URL

    var id: String { manifest.id }
}

struct PluginDiscoveryIssue: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case rootUnavailable
        case missingManifest
        case symbolicLink
        case unreadableManifest
        case manifestTooLarge
        case invalidManifest
        case duplicateIdentifier
    }

    let kind: Kind
    let path: String
    let detail: String

    var id: String { "\(kind.rawValue):\(path)" }
}

struct PluginDiscoveryResult: Equatable, Sendable {
    let plugins: [DiscoveredPlugin]
    let issues: [PluginDiscoveryIssue]
}

struct PluginCatalog {
    private let fileManager: FileManager
    let rootURL: URL
    private let bundledRootURL: URL?

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        bundledRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? PluginLocations.userPluginDirectory(fileManager: fileManager)
        self.bundledRootURL = bundledRootURL
            ?? PluginLocations.bundledPluginDirectory(fileManager: fileManager)
    }

    func discover() -> PluginDiscoveryResult {
        var discoveredPlugins = [DiscoveredPlugin]()
        var issues = [PluginDiscoveryIssue]()

        for root in discoveryRootURLs {
            let result = discover(in: root)
            discoveredPlugins.append(contentsOf: result.plugins)
            issues.append(contentsOf: result.issues)
        }

        // User-installed packages intentionally take precedence over the
        // read-only copies bundled with the app. This lets an explicit local
        // update keep working across app upgrades without creating a duplicate
        // plugin record for the same manifest ID.
        var selectedPlugins = [String: DiscoveredPlugin]()
        for plugin in discoveredPlugins {
            selectedPlugins[plugin.id] = selectedPlugins[plugin.id] ?? plugin
        }

        return PluginDiscoveryResult(
            plugins: selectedPlugins.values.sorted { $0.id < $1.id },
            issues: issues.sorted {
                if $0.path == $1.path { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.path < $1.path
            }
        )
    }

    private var discoveryRootURLs: [URL] {
        var roots = [rootURL.standardizedFileURL]
        if let bundledRootURL = bundledRootURL?.standardizedFileURL,
           !roots.contains(bundledRootURL) {
            roots.append(bundledRootURL)
        }
        return roots
    }

    private func discover(in rootURL: URL) -> PluginDiscoveryResult {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return PluginDiscoveryResult(plugins: [], issues: [])
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return PluginDiscoveryResult(
                plugins: [],
                issues: [issue(.rootUnavailable, path: rootURL.path, detail: "Plugin root is not a directory.")]
            )
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).sorted { $0.path < $1.path }
        } catch {
            return PluginDiscoveryResult(
                plugins: [],
                issues: [issue(.rootUnavailable, path: rootURL.path, detail: error.localizedDescription)]
            )
        }

        var candidates = [DiscoveredPlugin]()
        var issues = [PluginDiscoveryIssue]()

        for entry in entries {
            guard !isSymbolicLink(entry) else {
                issues.append(issue(.symbolicLink, path: entry.path, detail: "Plugin package symlinks are not supported."))
                continue
            }

            var entryIsDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory), entryIsDirectory.boolValue else {
                continue
            }

            let manifestURL = entry.appendingPathComponent("plugin.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                issues.append(issue(.missingManifest, path: entry.path, detail: "plugin.json is missing."))
                continue
            }
            guard !isSymbolicLink(manifestURL) else {
                issues.append(issue(.symbolicLink, path: manifestURL.path, detail: "Manifest symlinks are not supported."))
                continue
            }

            let manifest: PluginManifest
            do {
                manifest = try PluginManifestLoader.load(from: manifestURL, fileManager: fileManager)
            } catch PluginManifestFileError.tooLarge {
                issues.append(issue(.manifestTooLarge, path: manifestURL.path, detail: "plugin.json exceeds the host manifest size limit."))
                continue
            } catch {
                issues.append(issue(.unreadableManifest, path: manifestURL.path, detail: "plugin.json could not be decoded."))
                continue
            }

            do {
                try manifest.validate()
            } catch {
                issues.append(issue(.invalidManifest, path: manifestURL.path, detail: error.localizedDescription))
                continue
            }

            candidates.append(DiscoveredPlugin(manifest: manifest, packageURL: entry))
        }

        let grouped = Dictionary(grouping: candidates, by: \.id)
        var plugins = [DiscoveredPlugin]()
        for candidatesForID in grouped.values {
            if candidatesForID.count == 1, let plugin = candidatesForID.first {
                plugins.append(plugin)
            } else {
                for plugin in candidatesForID {
                    issues.append(issue(
                        .duplicateIdentifier,
                        path: plugin.packageURL.path,
                        detail: "Plugin identifier '\(plugin.id)' is declared by multiple packages."
                    ))
                }
            }
        }

        return PluginDiscoveryResult(plugins: plugins.sorted { $0.id < $1.id }, issues: issues)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func issue(
        _ kind: PluginDiscoveryIssue.Kind,
        path: String,
        detail: String
    ) -> PluginDiscoveryIssue {
        PluginDiscoveryIssue(kind: kind, path: path, detail: detail)
    }
}
