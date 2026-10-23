import Foundation

final class SnapshotStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseURL = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var snapshotURL: URL {
        baseURL.appendingPathComponent("snapshot.json")
    }

    func load() -> UsageSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            return nil
        }
        do {
            let snapshot = try decoder.decode(UsageSnapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch {
            quarantineUnreadableSnapshot()
            return nil
        }
    }

    func save(_ snapshot: UsageSnapshot) throws {
        try snapshot.validate()
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: [.atomic])
    }

    private func quarantineUnreadableSnapshot() {
        let timestamp = Int(Date().timeIntervalSince1970)
        var backupURL = baseURL.appendingPathComponent("snapshot.invalid-\(timestamp).json")
        if fileManager.fileExists(atPath: backupURL.path) {
            backupURL = baseURL.appendingPathComponent("snapshot.invalid-\(timestamp)-\(UUID().uuidString).json")
        }
        try? fileManager.moveItem(at: snapshotURL, to: backupURL)
    }
}

struct SourceFingerprint: Equatable, Codable, Sendable {
    let root: String
    let modificationTime: Date?
    let fileCount: Int
    let latestFileModificationTime: Date?
}

enum SourceFingerprintReader {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SourceFingerprint] {
        sourceRoots(home: home).compactMap(read(root:))
    }

    static func sourceRoots(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let codexHome = environment["CODEX_HOME"].flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        var roots: [URL] = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent(".amp", isDirectory: true),
            home.appendingPathComponent(".droid", isDirectory: true),
            home.appendingPathComponent(".codebuff", isDirectory: true),
            home.appendingPathComponent(".hermes", isDirectory: true),
            home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
            home.appendingPathComponent(".gemini", isDirectory: true),
            home.appendingPathComponent(".kimi", isDirectory: true),
            home.appendingPathComponent(".qwen", isDirectory: true),
            home.appendingPathComponent(".goose", isDirectory: true),
            home.appendingPathComponent(".openclaw", isDirectory: true),
            home.appendingPathComponent(".clawdbot", isDirectory: true),
            home.appendingPathComponent(".moltbot", isDirectory: true),
            home.appendingPathComponent(".moldbot", isDirectory: true),
            home.appendingPathComponent(".local/share/opencode", isDirectory: true),
            home.appendingPathComponent(".local/share/kilo", isDirectory: true),
            home.appendingPathComponent(".local/share/goose/sessions", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/goose/sessions", isDirectory: true)
        ]

        for key in ["AMP_DATA_DIR", "DROID_SESSIONS_DIR", "GEMINI_DATA_DIR", "KIMI_DATA_DIR", "COPILOT_OTEL_FILE_EXPORTER_PATH"] {
            if let value = environment[key], !value.isEmpty {
                roots.append(URL(fileURLWithPath: NSString(string: value).expandingTildeInPath))
            }
        }
        return Array(Set(roots))
    }

    private static func read(root: URL) -> SourceFingerprint? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
        let rootValues = try? root.resourceValues(forKeys: resourceKeys)
        var fileCount = 0
        var latestDate: Date?

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SourceFingerprint(
                root: root.path,
                modificationTime: rootValues?.contentModificationDate,
                fileCount: 0,
                latestFileModificationTime: nil
            )
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            fileCount += 1
            if let date = values.contentModificationDate, date > (latestDate ?? .distantPast) {
                latestDate = date
            }
        }

        return SourceFingerprint(
            root: root.path,
            modificationTime: rootValues?.contentModificationDate,
            fileCount: fileCount,
            latestFileModificationTime: latestDate
        )
    }
}
