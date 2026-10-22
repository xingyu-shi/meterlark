import Foundation

enum AppIdentity {
    static let bundleIdentifier = "com.xingyu.meterlark"
    static let dataDirectoryName = "Meterlark"
    static let preferencesPrefix = "Meterlark."
    static let pluginSecretService = bundleIdentifier + ".plugin"
}

/// Old product names live here solely to import existing local installations.
/// Migration copies data and never deletes the previous application directory.
enum LegacyDataMigration {
    static let bundleIdentifier = "com.xingyu.ccusage-monitor"
    static let dataDirectoryName = "CCUsageMonitor"
    static let preferencesPrefix = dataDirectoryName + "."
    static let pluginSecretService = bundleIdentifier + ".plugin"
    private static let completionKey = "Meterlark.legacyMigrationCompleted"

    static func prepare() throws {
        let defaults = UserDefaults.standard
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try migrate(
            defaults: defaults,
            legacyValues: defaults.persistentDomain(forName: bundleIdentifier) ?? [:],
            supportRoot: supportRoot
        )
    }

    static func migrate(
        defaults: UserDefaults,
        legacyValues: [String: Any],
        supportRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !defaults.bool(forKey: completionKey) else { return }
        let previousRoot = supportRoot.appendingPathComponent(dataDirectoryName, isDirectory: true)
        let currentRoot = supportRoot.appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)

        for directory in [previousRoot, currentRoot] where fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        if fileManager.fileExists(atPath: previousRoot.path),
           !fileManager.fileExists(atPath: currentRoot.path) {
            // Stage the whole copy so a failed import cannot leave a partial
            // destination that would be mistaken for a completed migration.
            let stagingRoot = supportRoot.appendingPathComponent(".meterlark-import-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: stagingRoot) }
            try fileManager.copyItem(at: previousRoot, to: stagingRoot)
            try fileManager.moveItem(at: stagingRoot, to: currentRoot)
        }

        for (key, value) in legacyValues where key.hasPrefix(preferencesPrefix) {
            let suffix = String(key.dropFirst(preferencesPrefix.count))
            let currentKey = AppIdentity.preferencesPrefix + suffix
            guard defaults.object(forKey: currentKey) == nil else { continue }
            if suffix == "launchAtLogin" {
                // Registration belongs to the old bundle; the user enables
                // login launch again after installing the renamed application.
                defaults.set(false, forKey: currentKey)
            } else if suffix == "customPricingPath", let path = value as? String,
                      path.hasPrefix(previousRoot.path + "/") {
                let migratedPath = currentRoot.path + String(path.dropFirst(previousRoot.path.count))
                defaults.set(
                    fileManager.fileExists(atPath: migratedPath) ? migratedPath : path,
                    forKey: currentKey
                )
            } else {
                defaults.set(value, forKey: currentKey)
            }
        }
        defaults.set(true, forKey: completionKey)
    }
}

/// Copy a requested credential on first read. Clearing a credential also
/// clears its legacy copy so it cannot reappear through migration fallback.
struct MigratingPluginSecretStore: PluginSecretStore {
    let base: any PluginSecretStore

    init(base: any PluginSecretStore = KeychainSecretStore()) {
        self.base = base
    }

    func read(service: String, account: String) throws -> Data? {
        if let current = try base.read(service: service, account: account) {
            return current
        }
        guard service == AppIdentity.pluginSecretService,
              let previous = try base.read(service: LegacyDataMigration.pluginSecretService, account: account) else {
            return nil
        }
        try base.write(previous, service: service, account: account)
        return previous
    }

    func write(_ data: Data, service: String, account: String) throws {
        try base.write(data, service: service, account: account)
    }

    func delete(service: String, account: String) throws {
        if service == AppIdentity.pluginSecretService {
            try base.delete(service: LegacyDataMigration.pluginSecretService, account: account)
        }
        try base.delete(service: service, account: account)
    }
}
