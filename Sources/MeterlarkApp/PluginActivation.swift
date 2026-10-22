import Foundation

enum PluginActivationError: Error, Equatable, Sendable {
    case invalidPluginIdentifier
    case invalidState
    case symbolicLink
    case writeFailed
}

extension PluginActivationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPluginIdentifier:
            return "The plugin identifier is invalid."
        case .invalidState:
            return "The plugin activation state is invalid."
        case .symbolicLink:
            return "The plugin activation state must not be a symbolic link."
        case .writeFailed:
            return "The plugin activation state could not be saved."
        }
    }
}

struct PluginActivationStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("PluginActivations.json", isDirectory: false)
    }

    func isEnabled(pluginID: String) throws -> Bool {
        try validatePluginIdentifier(pluginID)
        return try load()[pluginID] ?? false
    }

    func setEnabled(_ enabled: Bool, pluginID: String) throws {
        try validatePluginIdentifier(pluginID)
        var state = try load()
        state[pluginID] = enabled
        try save(state)
    }

    func remove(pluginID: String) throws {
        try validatePluginIdentifier(pluginID)
        var state = try load()
        state.removeValue(forKey: pluginID)
        try save(state)
    }

    func load() throws -> [String: Bool] {
        if isSymbolicLink(fileURL) {
            throw PluginActivationError.symbolicLink
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        do {
            let state = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: fileURL))
            for pluginID in state.keys {
                try validatePluginIdentifier(pluginID)
            }
            return state
        } catch let error as PluginActivationError {
            throw error
        } catch {
            throw PluginActivationError.invalidState
        }
    }

    private func save(_ state: [String: Bool]) throws {
        for pluginID in state.keys {
            try validatePluginIdentifier(pluginID)
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if isSymbolicLink(fileURL) {
                throw PluginActivationError.symbolicLink
            }
            try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic])
        } catch let error as PluginActivationError {
            throw error
        } catch {
            throw PluginActivationError.writeFailed
        }
    }

    private func validatePluginIdentifier(_ value: String) throws {
        guard PluginIdentifier.isValid(value) else {
            throw PluginActivationError.invalidPluginIdentifier
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
