import Foundation

enum ExternalPluginRegistryError: Error, Equatable, Sendable {
    case pluginNotInstalled
    case unsupportedTransport
    case pastedManifestRequiresHTTP
    case invalidPackage
    case invalidConfiguration
    case configurationSchemaUnavailable
}

extension ExternalPluginRegistryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .pluginNotInstalled:
            return "The external plugin is not installed."
        case .unsupportedTransport:
            return "Only stdio-json and http-json external plugins can be installed."
        case .pastedManifestRequiresHTTP:
            return "Paste installation supports http-json plugins. Install plugins with executable files from a package directory."
        case .invalidPackage:
            return "The external plugin package is invalid."
        case .invalidConfiguration:
            return "The external plugin configuration is invalid."
        case .configurationSchemaUnavailable:
            return "The external plugin does not declare a configuration schema."
        }
    }
}

struct ExternalPluginRecord: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let packageURL: URL
    let enabled: Bool
    let packageValidationMessage: String?
    let configurationValidationMessage: String?

    var id: String { manifest.id }
    /// The legacy combined message remains useful to callers, but a disabled
    /// package with missing configuration is intentionally presented as
    /// disabled rather than as an active runtime error.
    var validationMessage: String? {
        packageValidationMessage ?? (enabled ? configurationValidationMessage : nil)
    }
    var isPackageValid: Bool { packageValidationMessage == nil }
    var isConfigurationReady: Bool { configurationValidationMessage == nil }
    var isValid: Bool { isPackageValid && isConfigurationReady }
    var hasConfigurationSchema: Bool { manifest.configuration != nil }

    /// Invalid packages may remain enabled after an installed package is
    /// changed or becomes unreadable. The user must still be able to turn
    /// such a package off; only enabling an invalid, disabled package is
    /// prohibited.
    var canToggle: Bool { isPackageValid || enabled }
}

struct ExternalPluginDiscoveryResult: Equatable, Sendable {
    let plugins: [ExternalPluginRecord]
    let issues: [PluginDiscoveryIssue]
}

struct ExternalPluginRegistry {
    let catalog: PluginCatalog
    let validator: PluginPackageValidator
    let installer: PluginPackageInstaller
    let activationStore: PluginActivationStore
    let configurationStore: PluginConfigurationStore
    let authSessionRegistry: HTTPJSONAuthSessionRegistry
    let reservedPluginIDs: Set<String>

    init(
        catalog: PluginCatalog = PluginCatalog(),
        validator: PluginPackageValidator? = nil,
        installer: PluginPackageInstaller? = nil,
        activationStore: PluginActivationStore = PluginActivationStore(),
        configurationStore: PluginConfigurationStore = PluginConfigurationStore(),
        authSessionRegistry: HTTPJSONAuthSessionRegistry = HTTPJSONAuthSessionRegistry(),
        reservedPluginIDs: Set<String> = []
    ) {
        self.catalog = catalog
        self.validator = validator ?? PluginPackageValidator()
        self.installer = installer ?? PluginPackageInstaller()
        self.activationStore = activationStore
        self.configurationStore = configurationStore
        self.authSessionRegistry = authSessionRegistry
        self.reservedPluginIDs = reservedPluginIDs
    }

    var rootURL: URL { catalog.rootURL }

    func discover() -> [ExternalPluginRecord] {
        discoverResult().plugins
    }

    func discoverResult() -> ExternalPluginDiscoveryResult {
        let catalogResult = catalog.discover()
        let plugins = catalogResult.plugins
            .filter {
                ($0.manifest.transport == .stdioJSON || $0.manifest.transport == .httpJSON)
                    && !reservedPluginIDs.contains($0.id)
            }
            .map { plugin in
                let enabled: Bool
                let activationError: Error?
                do {
                    enabled = try activationStore.isEnabled(pluginID: plugin.id)
                    activationError = nil
                } catch {
                    enabled = false
                    activationError = error
                }

                let packageMessage: String?
                let configurationMessage: String?
                if let activationError {
                    packageMessage = Self.safeMessage(for: activationError)
                    configurationMessage = nil
                } else {
                    packageMessage = packageValidationMessage(for: plugin)
                    configurationMessage = packageMessage == nil
                        ? configurationValidationMessage(for: plugin)
                        : nil
                }

                return ExternalPluginRecord(
                    manifest: plugin.manifest,
                    packageURL: plugin.packageURL,
                    enabled: enabled,
                    packageValidationMessage: packageMessage,
                    configurationValidationMessage: configurationMessage
                )
            }
            .sorted { $0.id < $1.id }

        return ExternalPluginDiscoveryResult(
            plugins: plugins,
            issues: catalogResult.issues
        )
    }

    func enabledProviders() -> [any DashboardPluginProvider] {
        enabledProviders(for: discover())
    }

    func enabledProviders(for records: [ExternalPluginRecord]) -> [any DashboardPluginProvider] {
        records.compactMap { record in
            guard record.enabled, record.isValid, record.manifest.supportsDashboard else { return nil }
            do {
                let configuration = try configurationStore.loadEffectiveConfigurationData(
                    pluginID: record.id,
                    schema: record.manifest.configuration
                )
                switch record.manifest.transport {
                case .stdioJSON:
                    return try StdioJSONPluginProvider(
                        manifest: record.manifest,
                        packageURL: record.packageURL,
                        configurationData: configuration
                    )
                case .httpJSON:
                    return try HTTPJSONPluginProvider(
                        manifest: record.manifest,
                        configurationData: configuration,
                        credentialStore: configurationStore.refreshCredentialStore,
                        sessionRegistry: authSessionRegistry
                    )
                case .metadataOnly:
                    return nil
                }
            } catch {
                return nil
            }
        }
    }

    func enabledModelCatalogProviders() -> [any ModelCatalogPluginProvider] {
        enabledModelCatalogProviders(for: discover())
    }

    func enabledModelCatalogProviders(
        for records: [ExternalPluginRecord]
    ) -> [any ModelCatalogPluginProvider] {
        records.compactMap { record in
            guard record.enabled, record.isValid, record.manifest.supportsModelCatalog else { return nil }
            do {
                let configuration = try configurationStore.loadEffectiveConfigurationData(
                    pluginID: record.id,
                    schema: record.manifest.configuration
                )
                guard record.manifest.transport == .httpJSON else { return nil }
                return try HTTPJSONModelCatalogPluginProvider(
                    manifest: record.manifest,
                    configurationData: configuration,
                    credentialStore: configurationStore.refreshCredentialStore,
                    sessionRegistry: authSessionRegistry
                )
            } catch {
                return nil
            }
        }
    }

    @discardableResult
    func install(from sourceURL: URL) throws -> ValidatedPluginPackage {
        let source = try validator.validate(packageURL: sourceURL)
        guard source.manifest.transport == .stdioJSON || source.manifest.transport == .httpJSON else {
            throw ExternalPluginRegistryError.unsupportedTransport
        }
        return try installer.install(from: sourceURL, into: rootURL)
    }

    @discardableResult
    func install(manifestJSON: String) throws -> ValidatedPluginPackage {
        guard manifestJSON.utf8.count <= PluginManifestLoader.maximumManifestBytes else {
            throw PluginPackageValidationError.manifestTooLarge
        }
        let data = Data(manifestJSON.utf8)
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginPackageValidationError.unreadableManifest
        }
        guard manifest.transport == .httpJSON else {
            throw ExternalPluginRegistryError.pastedManifestRequiresHTTP
        }

        let fileManager = FileManager.default
        let packageURL = fileManager.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginPaste.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: packageURL) }
        try data.write(to: packageURL.appendingPathComponent("plugin.json"), options: .atomic)
        return try install(from: packageURL)
    }

    func setEnabled(_ enabled: Bool, pluginID: String) throws {
        guard let record = discover().first(where: { $0.id == pluginID }) else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        if enabled {
            guard record.isPackageValid else {
                throw ExternalPluginRegistryError.invalidPackage
            }
            guard record.isConfigurationReady else {
                throw ExternalPluginRegistryError.invalidConfiguration
            }
            do {
                _ = try configurationStore.loadEffectiveConfigurationData(
                    pluginID: record.id,
                    schema: record.manifest.configuration
                )
            } catch {
                throw ExternalPluginRegistryError.invalidConfiguration
            }
        }
        try activationStore.setEnabled(enabled, pluginID: record.id)
        if !enabled {
            // Disabling a plugin must also discard its in-memory access token
            // and fence any refresh that is still in flight.
            authSessionRegistry.invalidate(pluginID: record.id)
        }
    }

    func loadConfigurationDraft(pluginID: String) throws -> PluginConfigurationDraft {
        guard let record = discover().first(where: { $0.id == pluginID }) else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        guard let schema = record.manifest.configuration else {
            throw ExternalPluginRegistryError.configurationSchemaUnavailable
        }
        do {
            return try configurationStore.loadDraft(pluginID: pluginID, schema: schema)
        } catch {
            throw ExternalPluginRegistryError.invalidConfiguration
        }
    }

    func saveConfiguration(
        pluginID: String,
        submission: PluginConfigurationSubmission
    ) throws {
        guard let record = discover().first(where: { $0.id == pluginID }) else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        guard let schema = record.manifest.configuration else {
            throw ExternalPluginRegistryError.configurationSchemaUnavailable
        }
        do {
            try authSessionRegistry.withPluginFenced(pluginID: pluginID) {
                try configurationStore.save(submission, pluginID: pluginID, schema: schema)
            }
        } catch {
            throw ExternalPluginRegistryError.invalidConfiguration
        }
    }

    func resetConfiguration(pluginID: String) throws {
        guard let record = discover().first(where: { $0.id == pluginID }) else {
            throw ExternalPluginRegistryError.pluginNotInstalled
        }
        try authSessionRegistry.withPluginFenced(pluginID: pluginID) {
            try configurationStore.removeConfiguration(
                pluginID: pluginID,
                schema: record.manifest.configuration
            )
        }
    }

    private func packageValidationMessage(for plugin: DiscoveredPlugin) -> String? {
        do {
            _ = try validator.validate(packageURL: plugin.packageURL)
            return nil
        } catch {
            return Self.safeMessage(for: error)
        }
    }

    private func configurationValidationMessage(for plugin: DiscoveredPlugin) -> String? {
        do {
            let configuration = try configurationStore.loadEffectiveConfigurationData(
                pluginID: plugin.id,
                schema: plugin.manifest.configuration
            )
            try validateProviderConfiguration(
                for: plugin,
                configurationData: configuration
            )
            return nil
        } catch {
            return Self.safeMessage(for: error)
        }
    }

    private func validateProviderConfiguration(
        for plugin: DiscoveredPlugin,
        configurationData: Data?
    ) throws {
        switch plugin.manifest.transport {
        case .stdioJSON:
            _ = try StdioJSONPluginProvider(
                manifest: plugin.manifest,
                packageURL: plugin.packageURL,
                configurationData: configurationData
            )
        case .httpJSON:
            _ = try HTTPJSONPluginProvider(
                manifest: plugin.manifest,
                configurationData: configurationData,
                credentialStore: configurationStore.refreshCredentialStore,
                sessionRegistry: authSessionRegistry
            )
        case .metadataOnly:
            throw ExternalPluginRegistryError.unsupportedTransport
        }
    }

    private static func safeMessage(for error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(message.isEmpty ? "Plugin validation failed." : message.prefix(240))
    }
}
