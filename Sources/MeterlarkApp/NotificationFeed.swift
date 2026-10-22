import CryptoKit
import Foundation

enum NotificationSourceKind: String, Codable, Equatable, Sendable {
    case internalSource = "internal"
    case hostModule = "host-module"
    case plugin
}

enum NotificationSeverity: String, Codable, Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

/// A namespaced, extensible event type. The feed stores the raw value rather
/// than a domain-specific enum so new providers do not require changes to the
/// notification persistence layer.
struct NotificationEventType: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static let modelAdded = Self("model-catalog.model-added")
    static let modelRemoved = Self("model-catalog.model-removed")
    static let modelEnabled = Self("model-catalog.model-enabled")
    static let modelDisabled = Self("model-catalog.model-disabled")
    static let pricingChanged = Self("model-catalog.pricing-changed")
    static let catalogUpdated = Self("model-catalog.catalog-updated")

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func migratingLegacyKind(_ rawValue: String) -> Self {
        switch rawValue {
        case "modelAdded": return .modelAdded
        case "modelRemoved": return .modelRemoved
        case "modelEnabled": return .modelEnabled
        case "modelDisabled": return .modelDisabled
        case "pricingChanged": return .pricingChanged
        default:
            let sanitized = rawValue.unicodeScalars
                .map { Self.allowedScalars.contains($0) ? String($0) : "_" }
                .joined()
            return Self("legacy.\(sanitized.isEmpty ? "unknown" : sanitized)")
        }
    }

    static func isValid(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128 else { return false }
        guard rawValue.split(separator: ".", omittingEmptySubsequences: false).count >= 2,
              rawValue.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return rawValue.unicodeScalars.allSatisfy(Self.allowedScalars.contains)
    }

    private static let allowedScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
}

/// Compatibility alias for callers that used the original model-catalog-only
/// name. The stored event itself is now typed by the extensible value above.
typealias NotificationEventKind = NotificationEventType

enum NotificationEventIdentity {
    static func make(
        sourceKind: NotificationSourceKind,
        sourceID: String,
        type: NotificationEventType,
        occurrenceKey: String
    ) -> String {
        let canonical = [
            sourceKind.rawValue,
            sourceID,
            type.rawValue,
            occurrenceKey
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum NotificationFeedStoreError: Error, Equatable, Sendable {
    case existingDataUnreadable
}

struct NotificationFeedEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceKind: NotificationSourceKind
    let sourceID: String
    let type: NotificationEventType
    let severity: NotificationSeverity
    let title: String
    let body: String
    let catalogChangeSummary: NotificationCatalogChangeSummary?
    let createdAt: Date
    var isRead: Bool
    var isDismissed: Bool

    init(
        id: String,
        sourceID: String,
        sourceKind: NotificationSourceKind = .internalSource,
        type: NotificationEventType,
        severity: NotificationSeverity = .info,
        title: String,
        body: String,
        catalogChangeSummary: NotificationCatalogChangeSummary? = nil,
        createdAt: Date,
        isRead: Bool,
        isDismissed: Bool
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.type = type
        self.severity = severity
        self.title = title
        self.body = body
        self.catalogChangeSummary = catalogChangeSummary
        self.createdAt = createdAt
        self.isRead = isRead
        self.isDismissed = isDismissed
    }

    /// Source/kind initializer retained for source compatibility with the
    /// first persisted feed implementation.
    init(
        id: String,
        source: String,
        kind: NotificationEventKind,
        title: String,
        body: String,
        catalogChangeSummary: NotificationCatalogChangeSummary? = nil,
        createdAt: Date,
        isRead: Bool,
        isDismissed: Bool
    ) {
        self.init(
            id: id,
            sourceID: source,
            sourceKind: .plugin,
            type: kind,
            title: title,
            body: body,
            catalogChangeSummary: catalogChangeSummary,
            createdAt: createdAt,
            isRead: isRead,
            isDismissed: isDismissed
        )
    }

    /// Legacy property aliases keep existing in-process callers source
    /// compatible while the persisted representation uses sourceID/type.
    var source: String { sourceID }
    var kind: NotificationEventKind { type }

    /// The store deduplicates within the source namespace. UI callers should
    /// use this key when multiple sources happen to choose the same raw id.
    var scopedID: String {
        "\(sourceKind.rawValue):\(sourceID):\(id)"
    }

    static func stableID(
        sourceKind: NotificationSourceKind,
        sourceID: String,
        type: NotificationEventType,
        occurrenceKey: String
    ) -> String {
        NotificationEventIdentity.make(
            sourceKind: sourceKind,
            sourceID: sourceID,
            type: type,
            occurrenceKey: occurrenceKey
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceKind
        case sourceID
        case source
        case type
        case kind
        case severity
        case title
        case body
        case catalogChangeSummary
        case createdAt
        case isRead
        case isDismissed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
            ?? container.decode(String.self, forKey: .source)
        sourceKind = try container.decodeIfPresent(NotificationSourceKind.self, forKey: .sourceKind)
            ?? .plugin

        if let currentType = try container.decodeIfPresent(NotificationEventType.self, forKey: .type) {
            type = currentType
        } else {
            let legacyKind = try container.decode(String.self, forKey: .kind)
            type = NotificationEventType.migratingLegacyKind(legacyKind)
        }
        severity = try container.decodeIfPresent(NotificationSeverity.self, forKey: .severity) ?? .info
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        catalogChangeSummary = try container.decodeIfPresent(
            NotificationCatalogChangeSummary.self,
            forKey: .catalogChangeSummary
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isDismissed = try container.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(type, forKey: .type)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(catalogChangeSummary, forKey: .catalogChangeSummary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isRead, forKey: .isRead)
        try container.encode(isDismissed, forKey: .isDismissed)
    }
}

struct NotificationCatalogChangeSummary: Codable, Equatable, Sendable {
    let added: Int
    let removed: Int
    let enabled: Int
    let disabled: Int
    let pricingChanged: Int

    var total: Int {
        added + removed + enabled + disabled + pricingChanged
    }
}

struct NotificationFeedStore {
    static let maximumEvents = 200
    static let maximumEventIDUTF8Length = 256
    static let maximumSourceIDUTF8Length = 256
    static let maximumEventTypeUTF8Length = 128
    static let maximumSourceUTF8Length = maximumSourceIDUTF8Length
    static let maximumTitleUTF8Length = 256
    static let maximumBodyUTF8Length = 4_096

    enum LoadState: Equatable, Sendable {
        case ready
        case invalidExistingData
    }

    private(set) var events: [NotificationFeedEvent]
    private(set) var loadState: LoadState
    private let fileURL: URL

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        let url = fileURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("NotificationFeed.json", isDirectory: false)
        self.fileURL = url
        self.events = []
        self.loadState = .ready

        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            loadState = .invalidExistingData
            return
        }
        do {
            let decoded = try JSONDecoder().decode([NotificationFeedEvent].self, from: data)
            events = Self.normalized(decoded)
        } catch {
            // Preserve an unreadable file. A later append/read transition must
            // never replace user data with an empty array.
            loadState = .invalidExistingData
        }
    }

    var visibleEvents: [NotificationFeedEvent] {
        events.filter { !$0.isDismissed }
    }

    var unreadCount: Int {
        visibleEvents.filter { !$0.isRead }.count
    }

    mutating func append(_ incoming: [NotificationFeedEvent], fileManager: FileManager = .default) {
        guard !incoming.isEmpty else { return }
        var existingKeys = Set(events.map(Self.deduplicationKey))
        for event in incoming where Self.isBounded(event) && existingKeys.insert(Self.deduplicationKey(event)).inserted {
            events.append(event)
        }
        events = Self.normalized(events)
        try? save(fileManager: fileManager)
    }

    mutating func markRead(_ identifier: String, fileManager: FileManager = .default) {
        guard let index = index(matching: identifier) else { return }
        events[index].isRead = true
        try? save(fileManager: fileManager)
    }

    mutating func markAllRead(fileManager: FileManager = .default) {
        for index in events.indices { events[index].isRead = true }
        try? save(fileManager: fileManager)
    }

    mutating func dismiss(_ identifier: String, fileManager: FileManager = .default) {
        guard let index = index(matching: identifier) else { return }
        events[index].isDismissed = true
        events = events.filter { !$0.isDismissed }
        try? save(fileManager: fileManager)
    }

    mutating func dismissAll(fileManager: FileManager = .default) {
        guard !events.isEmpty else { return }
        events.removeAll(keepingCapacity: true)
        try? save(fileManager: fileManager)
    }

    func save(fileManager: FileManager = .default) throws {
        guard loadState == .ready else {
            throw NotificationFeedStoreError.existingDataUnreadable
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(events).write(to: fileURL, options: [.atomic])
    }

    private func index(matching identifier: String) -> Int? {
        events.firstIndex { $0.scopedID == identifier || $0.id == identifier }
    }

    private static func normalized(_ events: [NotificationFeedEvent]) -> [NotificationFeedEvent] {
        var seen = Set<String>()
        return events
            .filter { isBounded($0) && seen.insert(deduplicationKey($0)).inserted }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.scopedID < $1.scopedID
            }
            .prefix(Self.maximumEvents)
            .map { $0 }
    }

    private static func deduplicationKey(_ event: NotificationFeedEvent) -> String {
        guard event.type == .pricingChanged else {
            return "event|\(event.scopedID)"
        }

        // A single full catalog response can contain several backend records
        // for the same displayed model and route. Those records may produce
        // distinct stable IDs, but identical cards are not useful as separate
        // unread notifications. Keep distinct pricing occurrences across
        // refresh times while collapsing an indistinguishable same-batch
        // presentation. This also repairs feeds written by older builds.
        let fields = [
            event.sourceKind.rawValue,
            event.sourceID,
            event.type.rawValue,
            event.severity.rawValue,
            event.title,
            event.body,
            String(event.createdAt.timeIntervalSinceReferenceDate.bitPattern)
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
        return "pricing-presentation|\(fields)"
    }

    private static func isBounded(_ event: NotificationFeedEvent) -> Bool {
        event.id.utf8.count <= maximumEventIDUTF8Length
            && event.sourceID.utf8.count <= maximumSourceIDUTF8Length
            && event.type.rawValue.utf8.count <= maximumEventTypeUTF8Length
            && NotificationEventType.isValid(event.type.rawValue)
            && event.title.utf8.count <= maximumTitleUTF8Length
            && event.body.utf8.count <= maximumBodyUTF8Length
    }
}

@MainActor
protocol NotificationFeedSink: AnyObject {
    func publish(_ events: [NotificationFeedEvent])
}

/// Main-actor adapter that owns the mutable store and exposes a small
/// publishing seam to future internal modules and plugin adapters. The store
/// itself remains a persistence/value type and knows nothing about UI.
@MainActor
final class NotificationFeedCoordinator: NotificationFeedSink {
    private var store: NotificationFeedStore

    init(store: NotificationFeedStore) {
        self.store = store
    }

    var visibleEvents: [NotificationFeedEvent] { store.visibleEvents }
    var unreadCount: Int { store.unreadCount }

    func publish(_ events: [NotificationFeedEvent]) {
        store.append(events)
    }

    func markRead(_ identifier: String) {
        store.markRead(identifier)
    }

    func markAllRead() {
        store.markAllRead()
    }

    func dismiss(_ identifier: String) {
        store.dismiss(identifier)
    }

    func dismissAll() {
        store.dismissAll()
    }
}
