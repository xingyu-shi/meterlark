import Foundation

enum PluginPackageValidationError: Error, Equatable, Sendable {
    case packageNotFound
    case packageNotDirectory
    case symbolicLink(path: String)
    case missingManifest
    case manifestTooLarge
    case unreadableManifest
    case invalidManifest(String)
    case entrypointMissing
    case entrypointNotRegularFile
    case entrypointNotExecutable
    case entrypointOutsidePackage
}

extension PluginPackageValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .packageNotFound:
            return "The plugin package does not exist."
        case .packageNotDirectory:
            return "The plugin package is not a directory."
        case let .symbolicLink(path):
            return "Plugin packages must not contain symbolic links: \(path)"
        case .missingManifest:
            return "The plugin package does not contain plugin.json."
        case .manifestTooLarge:
            return "The plugin manifest is too large."
        case .unreadableManifest:
            return "The plugin manifest could not be read."
        case let .invalidManifest(detail):
            return "The plugin manifest is invalid: \(detail)"
        case .entrypointMissing:
            return "The external plugin entrypoint does not exist."
        case .entrypointNotRegularFile:
            return "The external plugin entrypoint is not a regular file."
        case .entrypointNotExecutable:
            return "The external plugin entrypoint is not executable."
        case .entrypointOutsidePackage:
            return "The external plugin entrypoint is outside its package."
        }
    }
}

struct ValidatedPluginPackage: Equatable, Sendable {
    let manifest: PluginManifest
    let packageURL: URL
}

struct PluginPackageValidator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func validate(packageURL: URL) throws -> ValidatedPluginPackage {
        let packageURL = packageURL.standardizedFileURL
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw PluginPackageValidationError.packageNotFound
        }
        guard !isSymbolicLink(packageURL) else {
            throw PluginPackageValidationError.symbolicLink(path: packageURL.path)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PluginPackageValidationError.packageNotDirectory
        }

        try rejectSymbolicLinksRecursively(in: packageURL)

        let manifestURL = packageURL.appendingPathComponent("plugin.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PluginPackageValidationError.missingManifest
        }
        guard !isSymbolicLink(manifestURL) else {
            throw PluginPackageValidationError.symbolicLink(path: manifestURL.path)
        }

        let manifest: PluginManifest
        do {
            manifest = try PluginManifestLoader.load(from: manifestURL, fileManager: fileManager)
        } catch PluginManifestFileError.tooLarge {
            throw PluginPackageValidationError.manifestTooLarge
        } catch {
            throw PluginPackageValidationError.unreadableManifest
        }

        do {
            try manifest.validate()
        } catch {
            throw PluginPackageValidationError.invalidManifest(error.localizedDescription)
        }

        if manifest.transport == .stdioJSON {
            try validateEntrypoint(manifest: manifest, packageURL: packageURL)
        }

        return ValidatedPluginPackage(manifest: manifest, packageURL: packageURL)
    }

    private func validateEntrypoint(manifest: PluginManifest, packageURL: URL) throws {
        guard let entrypoint = manifest.entrypoint else {
            throw PluginPackageValidationError.invalidManifest(
                PluginManifestValidationError.missingEntrypoint.localizedDescription
            )
        }

        let packagePath = packageURL.path
        let executableURL = packageURL
            .appendingPathComponent(entrypoint)
            .standardizedFileURL
        guard executableURL.path == packagePath
                || executableURL.path.hasPrefix(packagePath + "/") else {
            throw PluginPackageValidationError.entrypointOutsidePackage
        }
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw PluginPackageValidationError.entrypointMissing
        }
        guard !isSymbolicLink(executableURL) else {
            throw PluginPackageValidationError.symbolicLink(path: executableURL.path)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path)
        guard let type = attributes?[.type] as? FileAttributeType,
              type == .typeRegular else {
            throw PluginPackageValidationError.entrypointNotRegularFile
        }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw PluginPackageValidationError.entrypointNotExecutable
        }
    }

    private func rejectSymbolicLinksRecursively(in packageURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for case let itemURL as URL in enumerator {
            if isSymbolicLink(itemURL) {
                throw PluginPackageValidationError.symbolicLink(path: itemURL.path)
            }
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

enum PluginPackageInstallError: Error, Equatable, Sendable {
    case rootNotDirectory
    case rootIsSymbolicLink
    case copyFailed
    case replacementFailed
    case stagedPackageChanged
}

extension PluginPackageInstallError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .rootNotDirectory:
            return "The plugin installation directory is not a directory."
        case .rootIsSymbolicLink:
            return "The plugin installation directory must not be a symbolic link."
        case .copyFailed:
            return "The plugin package could not be staged."
        case .replacementFailed:
            return "The installed plugin could not be replaced atomically."
        case .stagedPackageChanged:
            return "The plugin package changed while it was being staged."
        }
    }
}

struct PluginPackageInstaller {
    private let fileManager: FileManager
    private let validator: PluginPackageValidator

    init(
        fileManager: FileManager = .default,
        validator: PluginPackageValidator? = nil
    ) {
        self.fileManager = fileManager
        self.validator = validator ?? PluginPackageValidator(fileManager: fileManager)
    }

    @discardableResult
    func install(
        from sourceURL: URL,
        into rootURL: URL
    ) throws -> ValidatedPluginPackage {
        let source = try validator.validate(packageURL: sourceURL)
        let rootURL = rootURL.standardizedFileURL
        try prepareRoot(rootURL)

        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        do {
            try fileManager.copyItem(at: source.packageURL, to: stagingURL)
        } catch {
            throw PluginPackageInstallError.copyFailed
        }

        let staged = try validator.validate(packageURL: stagingURL)
        guard staged.manifest == source.manifest else {
            throw PluginPackageInstallError.stagedPackageChanged
        }

        let destinationURL = rootURL.appendingPathComponent(
            staged.manifest.id,
            isDirectory: true
        )
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                guard !isSymbolicLink(destinationURL) else {
                    throw PluginPackageInstallError.replacementFailed
                }
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch let error as PluginPackageInstallError {
            throw error
        } catch {
            throw PluginPackageInstallError.replacementFailed
        }

        return ValidatedPluginPackage(
            manifest: staged.manifest,
            packageURL: destinationURL
        )
    }

    private func prepareRoot(_ rootURL: URL) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            guard !isSymbolicLink(rootURL) else {
                throw PluginPackageInstallError.rootIsSymbolicLink
            }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw PluginPackageInstallError.rootNotDirectory
            }
            return
        }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw PluginPackageInstallError.rootNotDirectory
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
