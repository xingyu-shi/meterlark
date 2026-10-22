import Foundation

final class BudgetSnapshotStore: @unchecked Sendable {
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
        baseURL.appendingPathComponent("monthly-budget.json")
    }

    func load() -> MonthlyBudgetSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        do {
            let snapshot = try decoder.decode(MonthlyBudgetSnapshot.self, from: Data(contentsOf: snapshotURL))
            try snapshot.validate()
            return snapshot
        } catch {
            quarantineUnreadableSnapshot()
            return nil
        }
    }

    func save(_ snapshot: MonthlyBudgetSnapshot) throws {
        try snapshot.validate()
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: [.atomic])
    }

    private func quarantineUnreadableSnapshot() {
        let timestamp = Int(Date().timeIntervalSince1970)
        var backupURL = baseURL.appendingPathComponent("monthly-budget.invalid-\(timestamp).json")
        if fileManager.fileExists(atPath: backupURL.path) {
            backupURL = baseURL.appendingPathComponent("monthly-budget.invalid-\(timestamp)-\(UUID().uuidString).json")
        }
        try? fileManager.moveItem(at: snapshotURL, to: backupURL)
    }
}

