import CryptoKit
import Foundation

enum ModelCatalogDecodeError: Error, Equatable, Sendable {
    case invalidEnvelope
    case emptyCatalog
    case tooManyRecords
    case invalidRecord(Int, String)
    case duplicateIdentity(String)
    case invalidPrice(Int, String)
}

extension ModelCatalogDecodeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "The model catalog response is not a valid object envelope."
        case .emptyCatalog:
            return "The model catalog response does not contain any records."
        case .tooManyRecords:
            return "The model catalog contains too many records."
        case let .invalidRecord(index, detail):
            return "The model catalog record \(index) is invalid: \(detail)"
        case let .duplicateIdentity(identity):
            return "The model catalog contains duplicate record identity \(identity)."
        case let .invalidPrice(index, field):
            return "The model catalog record \(index) contains an invalid price field \(field)."
        }
    }
}

private struct JSONModelCatalogEnvelope: Decodable {
    let data: [JSONModelCatalogRecord]
}

private struct JSONModelCatalogRecord: Decodable {
    let modelName: String?
    let litellmParams: [String: JSONValue]?
    let modelInfo: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case litellmParams = "litellm_params"
        case modelInfo = "model_info"
    }
}

struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
    static let currentIdentitySchemaVersion = 3
    static let legacyIdentitySchemaVersion = 1
    /// The pricing normalization rules are part of the persisted diff
    /// contract. A parser change such as treating a remote null cache rate as
    /// free must establish a new baseline instead of being shown as a real
    /// provider price change.
    static let currentPricingSchemaVersion = 1
    static let legacyPricingSchemaVersion = 0

    let providerID: String
    let fetchedAt: Date
    let identitySchemaVersion: Int
    let pricingSchemaVersion: Int
    let revision: String
    let entries: [ModelCatalogEntry]

    init(
        providerID: String,
        fetchedAt: Date,
        entries: [ModelCatalogEntry],
        identitySchemaVersion: Int = Self.currentIdentitySchemaVersion,
        pricingSchemaVersion: Int = Self.currentPricingSchemaVersion
    ) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        self.identitySchemaVersion = identitySchemaVersion
        self.pricingSchemaVersion = pricingSchemaVersion
        self.entries = entries.sorted { lhs, rhs in
            if lhs.id == rhs.id { return lhs.modelName < rhs.modelName }
            return lhs.id < rhs.id
        }
        self.revision = Self.revision(
            providerID: providerID,
            identitySchemaVersion: identitySchemaVersion,
            pricingSchemaVersion: pricingSchemaVersion,
            entries: self.entries
        )
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case fetchedAt
        case identitySchemaVersion
        case pricingSchemaVersion
        case revision
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        identitySchemaVersion = try container.decodeIfPresent(Int.self, forKey: .identitySchemaVersion)
            ?? Self.legacyIdentitySchemaVersion
        pricingSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .pricingSchemaVersion)
            ?? Self.legacyPricingSchemaVersion
        let decodedEntries = try container.decode([ModelCatalogEntry].self, forKey: .entries)
        entries = decodedEntries.sorted { lhs, rhs in
            if lhs.id == rhs.id { return lhs.modelName < rhs.modelName }
            return lhs.id < rhs.id
        }
        _ = try container.decodeIfPresent(String.self, forKey: .revision)
        let computedRevision = Self.revision(
            providerID: providerID,
            identitySchemaVersion: identitySchemaVersion,
            pricingSchemaVersion: pricingSchemaVersion,
            entries: entries
        )
        revision = computedRevision
    }

    func encodedRevisionData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(ModelCatalogEntry.semanticRevisionProjection(entries))) ?? Data()
    }

    private static func revision(
        providerID: String,
        identitySchemaVersion: Int,
        pricingSchemaVersion: Int,
        entries: [ModelCatalogEntry]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct RevisionPayload: Encodable {
            let providerID: String
            let identitySchemaVersion: Int
            let pricingSchemaVersion: Int
            let entries: [ModelCatalogEntrySemanticRecord]
        }
        let data = (try? encoder.encode(RevisionPayload(
            providerID: providerID,
            identitySchemaVersion: identitySchemaVersion,
            pricingSchemaVersion: pricingSchemaVersion,
            entries: ModelCatalogEntry.semanticRevisionProjection(entries)
        ))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum JSONModelCatalogDecoder {
    static let maximumRecords = 10_000
    static let maximumModelNameUTF8Length = 256
    static let maximumRecordIdentityUTF8Length = 256
    static let maximumRouteUTF8Length = 1_024
    static let maximumMetadataKeyUTF8Length = 256
    static let maximumMetadataStringUTF8Length = 4_096
    static let maximumMetadataTextBytes = 64 * 1024
    static let maximumMetadataObjectMembers = 256
    static let maximumMetadataArrayItems = 256
    static let maximumMetadataDepth = 8

    static func decode(
        data: Data,
        providerID: String,
        fetchedAt: Date = Date()
    ) throws -> ModelCatalogSnapshot {
        let envelope: JSONModelCatalogEnvelope
        do {
            envelope = try JSONDecoder().decode(JSONModelCatalogEnvelope.self, from: data)
        } catch {
            throw ModelCatalogDecodeError.invalidEnvelope
        }
        guard !envelope.data.isEmpty else {
            throw ModelCatalogDecodeError.emptyCatalog
        }
        guard envelope.data.count <= maximumRecords else {
            throw ModelCatalogDecodeError.tooManyRecords
        }

        var byIdentity = [String: ModelCatalogEntry]()
        for (index, record) in envelope.data.enumerated() {
            let entry = try makeEntry(record, index: index, providerID: providerID)
            if let existing = byIdentity[entry.id] {
                guard existing == entry else {
                    throw ModelCatalogDecodeError.duplicateIdentity(entry.id)
                }
                continue
            }
            byIdentity[entry.id] = entry
        }

        return ModelCatalogSnapshot(
            providerID: providerID,
            fetchedAt: fetchedAt,
            entries: byIdentity.values.sorted {
                let lhs = $0.modelName.lowercased()
                let rhs = $1.modelName.lowercased()
                if lhs == rhs { return $0.id < $1.id }
                return lhs < rhs
            }
        )
    }

    private static func makeEntry(
        _ record: JSONModelCatalogRecord,
        index: Int,
        providerID: String
    ) throws -> ModelCatalogEntry {
        guard let modelName = record.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty else {
            throw ModelCatalogDecodeError.invalidRecord(index, "model_name is missing")
        }
        guard modelName.utf8.count <= maximumModelNameUTF8Length else {
            throw ModelCatalogDecodeError.invalidRecord(index, "model_name is too long")
        }
        guard let modelInfo = record.modelInfo,
              let identity = modelInfo["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty else {
            throw ModelCatalogDecodeError.invalidRecord(index, "model_info.id is missing")
        }
        guard identity.utf8.count <= maximumRecordIdentityUTF8Length else {
            throw ModelCatalogDecodeError.invalidRecord(index, "model_info.id is too long")
        }

        let params = record.litellmParams ?? [:]
        try validateMetadata(modelInfo, field: "model_info", index: index)
        try validateMetadata(params, field: "litellm_params", index: index)
        if let route = params["model"]?.stringValue {
            guard route.utf8.count <= maximumRouteUTF8Length else {
                throw ModelCatalogDecodeError.invalidRecord(index, "litellm_params.model is too long")
            }
        }
        let pricingSchedule = try makePricingSchedule(modelInfo, index: index)
        let pricing = CustomModelPricing(
            inputCostPerToken: pricingSchedule.base.input,
            outputCostPerToken: pricingSchedule.base.output,
            cacheCreationInputTokenCost: pricingSchedule.base.cacheCreation,
            cacheReadInputTokenCost: pricingSchedule.base.cacheRead
        )
        let pageDisplayData = modelInfo["page_display_data"]?.objectValue ?? [:]
        let enabled = modelInfo["enabled"]?.boolValue
            ?? pageDisplayData["enabled"]?.boolValue
        let mode = modelInfo["mode"]?.stringValue
        let stableID = stableID(
            providerID: providerID,
            recordIdentity: identity,
            modelName: modelName,
            route: params["model"]?.stringValue,
            mode: mode
        )
        let canonicalPricing = CanonicalModelPricing(
            modelName: modelName,
            base: pricingSchedule.base,
            tiers: pricingSchedule.tiers,
            maxInputTokens: modelInfo["max_input_tokens"]?.integerValue,
            fastMultiplier: modelInfo["fast_multiplier"]?.doubleValue
        )

        return ModelCatalogEntry(
            id: stableID,
            modelName: modelName,
            pricing: pricing,
            metadata: ModelCatalogMetadata(modelInfo: modelInfo, litellmParams: params),
            source: .remote,
            providerID: providerID,
            recordIdentity: identity,
            enabled: enabled,
            pricingSchedule: canonicalPricing
        )
    }

    private static func validateMetadata(
        _ values: [String: JSONValue],
        field: String,
        index: Int
    ) throws {
        var textBytes = 0

        func invalid(_ detail: String) -> ModelCatalogDecodeError {
            .invalidRecord(index, detail)
        }

        func addTextBytes(_ value: String, label: String) throws {
            guard value.utf8.count <= maximumMetadataStringUTF8Length else {
                throw invalid("\(label) is too long")
            }
            textBytes += value.utf8.count
            guard textBytes <= maximumMetadataTextBytes else {
                throw invalid("contains too much text")
            }
        }

        func walk(_ value: JSONValue, path: String, depth: Int) throws {
            guard depth <= maximumMetadataDepth else {
                throw invalid("\(path) is nested too deeply")
            }
            switch value {
            case .null, .bool, .number:
                return
            case let .string(string):
                try addTextBytes(string, label: path)
            case let .array(values):
                guard values.count <= maximumMetadataArrayItems else {
                    throw invalid("\(path) contains too many items")
                }
                for (offset, item) in values.enumerated() {
                    try walk(item, path: "\(path)[\(offset)]", depth: depth + 1)
                }
            case let .object(object):
                guard object.count <= maximumMetadataObjectMembers else {
                    throw invalid("\(path) contains too many fields")
                }
                for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                    guard key.utf8.count <= maximumMetadataKeyUTF8Length else {
                        throw invalid("\(path) contains an overlong field name")
                    }
                    try addTextBytes(key, label: "\(path).key")
                    try walk(item, path: "\(path).\(key)", depth: depth + 1)
                }
            }
        }

        guard values.count <= maximumMetadataObjectMembers else {
            throw invalid("contains too many fields")
        }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard key.utf8.count <= maximumMetadataKeyUTF8Length else {
                throw invalid("contains an overlong field name")
            }
            try addTextBytes(key, label: "\(field).key")
            try walk(value, path: "\(field).\(key)", depth: 1)
        }
    }

    private static func makePricingSchedule(
        _ modelInfo: [String: JSONValue],
        index: Int
    ) throws -> PricingSchedule {
        let base = PricingRates(
            input: try rate(modelInfo, key: "input_cost_per_token", index: index),
            output: try rate(modelInfo, key: "output_cost_per_token", index: index),
            cacheCreation: try rate(modelInfo, key: "cache_creation_input_token_cost", index: index),
            cacheRead: try rate(modelInfo, key: "cache_read_input_token_cost", index: index)
        ).normalizedForRemoteCatalog
        var tiersByThreshold = [Int64: PricingRates]()
        for key in modelInfo.keys.sorted() {
            guard let tier = parseTierField(key) else { continue }
            guard let value = modelInfo[key] else { continue }
            if value == .null {
                // Null input/output tier fields do not invent a tier. Null
                // cache fields are normalized to a free component below, so
                // the same rule is owned by PricingRates rather than this
                // decoder's individual field branches.
                continue
            }
            guard let rate = value.doubleValue, rate.isFinite, rate >= 0 else {
                throw ModelCatalogDecodeError.invalidPrice(index, key)
            }
            var rates = tiersByThreshold[tier.threshold] ?? .empty
            rates.set(rate, for: tier.component)
            tiersByThreshold[tier.threshold] = rates
        }
        let tiers = tiersByThreshold.keys.sorted().map { threshold in
            PricingTier(
                threshold: threshold,
                rates: (tiersByThreshold[threshold] ?? .empty).normalizedForRemoteCatalog
            )
        }
        return PricingSchedule(base: base, tiers: tiers)
    }

    private static func rate(
        _ values: [String: JSONValue],
        key: String,
        index: Int
    ) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        guard let rate = value.doubleValue, rate.isFinite, rate >= 0 else {
            throw ModelCatalogDecodeError.invalidPrice(index, key)
        }
        return rate
    }

    private struct PricingSchedule {
        let base: PricingRates
        let tiers: [PricingTier]
    }

    enum TierComponent {
        case input
        case output
        case cacheCreation
        case cacheRead
    }

    private struct TierField {
        let component: TierComponent
        let threshold: Int64
    }

    private static func parseTierField(_ field: String) -> TierField? {
        guard field.hasSuffix("_tokens") else { return nil }
        let stem = String(field.dropLast("_tokens".count))
        guard let marker = stem.range(of: "_above_", options: .backwards) else { return nil }
        let baseField = String(stem[..<marker.lowerBound])
        var numericPart = String(stem[marker.upperBound...])
        let unit: String
        if let last = numericPart.last, last == "k" || last == "K" || last == "m" || last == "M" {
            unit = String(last).lowercased()
            numericPart.removeLast()
        } else {
            unit = ""
        }
        guard var threshold = Int64(numericPart), threshold > 0 else { return nil }
        switch unit {
        case "k":
            guard threshold <= Int64.max / 1_000 else { return nil }
            threshold *= 1_000
        case "m":
            guard threshold <= Int64.max / 1_000_000 else { return nil }
            threshold *= 1_000_000
        case "":
            break
        default:
            return nil
        }
        let component: TierComponent
        switch baseField {
        case "input_cost_per_token": component = .input
        case "output_cost_per_token": component = .output
        case "cache_creation_input_token_cost": component = .cacheCreation
        case "cache_read_input_token_cost": component = .cacheRead
        default: return nil
        }
        return TierField(component: component, threshold: threshold)
    }

    private static func stableID(
        providerID: String,
        recordIdentity: String,
        modelName: String,
        route: String?,
        mode: String?
    ) -> String {
        let normalizedMode = mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let variant = normalizedMode.flatMap { $0.isEmpty ? nil : $0 } ?? "<unspecified>"
        let raw = [
            providerID,
            recordIdentity,
            modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            route?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            variant
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return "remote~\(providerID)~\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}

private extension PricingRates {
    mutating func set(_ rate: Double, for component: JSONModelCatalogDecoder.TierComponent) {
        switch component {
        case .input: input = rate
        case .output: output = rate
        case .cacheCreation: cacheCreation = rate
        case .cacheRead: cacheRead = rate
        }
    }
}

protocol ModelCatalogPluginProvider: Sendable {
    var manifest: PluginManifest { get }
    /// Implementations must honor task cancellation. The host cannot forcibly
    /// terminate an arbitrary in-process Swift task, so a provider that wraps
    /// a transport must also enforce its own request timeout.
    func fetchModelCatalog() async throws -> ModelCatalogSnapshot
}

/// The refresh task carries only value-semantic, Sendable outcomes across
/// the concurrent provider fetch boundary. Raw `Error` values are kept inside
/// the provider task and reduced to a bounded message before the batch is
/// committed on the main actor.
enum ModelCatalogFetchOutcome: Sendable {
    case success(ModelCatalogSnapshot)
    case failure(providerID: String, message: String)

    var providerID: String {
        switch self {
        case let .success(snapshot): return snapshot.providerID
        case let .failure(providerID, _): return providerID
        }
    }
}

enum ModelCatalogFetchBatch {
    /// The built-in HTTP transport has a matching upper bound. This host-level
    /// deadline also protects the coordinator when a third-party in-process
    /// provider ignores task cancellation.
    static let defaultProviderTimeout: TimeInterval = 60

    static func fetch(
        providers: [any ModelCatalogPluginProvider],
        providerTimeout: TimeInterval = Self.defaultProviderTimeout
    ) async -> [ModelCatalogFetchOutcome] {
        await withTaskGroup(of: ModelCatalogFetchOutcome.self, returning: [ModelCatalogFetchOutcome].self) { group in
            for provider in providers {
                group.addTask {
                    await fetchOne(provider: provider, timeout: providerTimeout)
                }
            }

            var outcomes: [ModelCatalogFetchOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { $0.providerID < $1.providerID }
        }
    }

    private static func fetchOne(
        provider: any ModelCatalogPluginProvider,
        timeout: TimeInterval
    ) async -> ModelCatalogFetchOutcome {
        let expectedProviderID = provider.manifest.id
        let race = ModelCatalogProviderFetchRace(providerID: expectedProviderID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(
                    provider: provider,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            race.cancel()
        }
    }

    fileprivate static func fetchAndValidate(
        provider: any ModelCatalogPluginProvider
    ) async -> ModelCatalogFetchOutcome {
        let expectedProviderID = provider.manifest.id
        do {
            try Task.checkCancellation()
            let snapshot = try await provider.fetchModelCatalog()
            try Task.checkCancellation()
            guard snapshot.providerID == expectedProviderID else {
                return .failure(
                    providerID: expectedProviderID,
                    message: "Model catalog provider identity did not match its manifest."
                )
            }
            guard !snapshot.entries.isEmpty,
                  snapshot.entries.allSatisfy({
                $0.source == .remote && $0.providerID == expectedProviderID
            }) else {
                return .failure(
                    providerID: expectedProviderID,
                    message: "Model catalog entries did not match their provider manifest."
                )
            }
            return .success(snapshot)
        } catch is CancellationError {
            return .failure(
                providerID: expectedProviderID,
                message: "Model catalog request was cancelled."
            )
        } catch {
            return .failure(
                providerID: expectedProviderID,
                message: error.localizedDescription
            )
        }
    }
}

/// Races a provider request against a host deadline without making the host
/// await a provider that violates the cancellation contract. The late task is
/// cancelled and its eventual result is ignored; the refresh request/generation
/// fences still protect the catalog commit path.
private final class ModelCatalogProviderFetchRace: @unchecked Sendable {
    private let lock = NSLock()
    private let providerID: String
    private var continuation: CheckedContinuation<ModelCatalogFetchOutcome, Never>?
    private var providerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(providerID: String) {
        self.providerID = providerID
    }

    func start(
        provider: any ModelCatalogPluginProvider,
        timeout: TimeInterval,
        continuation: CheckedContinuation<ModelCatalogFetchOutcome, Never>
    ) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: .failure(
                providerID: providerID,
                message: "Model catalog request was cancelled."
            ))
            return
        }
        self.continuation = continuation
        lock.unlock()

        let providerTask = Task.detached(priority: .utility) { [weak self] in
            let outcome = await ModelCatalogFetchBatch.fetchAndValidate(provider: provider)
            self?.finish(outcome)
        }
        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            let safeTimeout = timeout.isFinite && timeout > 0
                ? timeout
                : ModelCatalogFetchBatch.defaultProviderTimeout
            let nanoseconds = UInt64(min(safeTimeout, 60 * 60) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: max(nanoseconds, 1_000_000))
            } catch {
                return
            }
            self?.finish(.failure(
                providerID: self?.providerID ?? "unknown",
                message: "Model catalog request timed out."
            ))
        }

        lock.lock()
        if isFinished {
            lock.unlock()
            providerTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.providerTask = providerTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func cancel() {
        finish(.failure(
            providerID: providerID,
            message: "Model catalog request was cancelled."
        ))
    }

    private func finish(_ outcome: ModelCatalogFetchOutcome) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let providerTask = self.providerTask
        self.providerTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        providerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: outcome)
    }
}

enum ModelCatalogProviderSelection {
    static func merging(
        base: [any ModelCatalogPluginProvider],
        external: [any ModelCatalogPluginProvider]
    ) -> [any ModelCatalogPluginProvider] {
        var providersByID = [String: any ModelCatalogPluginProvider]()
        // Built-in providers are part of the host's trusted contract. An
        // installed package may add a provider, but it must not silently
        // replace a built-in provider by reusing its manifest ID.
        for provider in base { providersByID[provider.manifest.id] = provider }
        for provider in external where providersByID[provider.manifest.id] == nil {
            providersByID[provider.manifest.id] = provider
        }
        return providersByID.values.sorted { $0.manifest.id < $1.manifest.id }
    }
}

struct HTTPJSONModelCatalogPluginProvider: ModelCatalogPluginProvider {
    static let maximumResponseBytes = 8 * 1024 * 1024

    let manifest: PluginManifest
    private let transport: HTTPJSONPluginProvider

    init(
        manifest: PluginManifest,
        configurationData: Data? = nil,
        maximumResponseBytes: Int = Self.maximumResponseBytes,
        send: HTTPJSONPluginProvider.RequestSender? = nil,
        credentialStore: (any PluginRefreshCredentialStore)? = nil,
        sessionRegistry: HTTPJSONAuthSessionRegistry = HTTPJSONAuthSessionRegistry(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard manifest.supportsModelCatalog else {
            throw HTTPJSONPluginError.unsupportedTransport
        }
        self.manifest = manifest
        self.transport = try HTTPJSONPluginProvider(
            manifest: manifest,
            configurationData: configurationData,
            maximumResponseBytes: maximumResponseBytes,
            send: send,
            credentialStore: credentialStore,
            sessionRegistry: sessionRegistry,
            nowProvider: nowProvider
        )
    }

    func fetchModelCatalog() async throws -> ModelCatalogSnapshot {
        let response = try await transport.fetchRawResponse()
        do {
            return try JSONModelCatalogDecoder.decode(
                data: response.data,
                providerID: manifest.id
            )
        } catch let error as ModelCatalogDecodeError {
            throw HTTPJSONPluginError.modelCatalogMappingFailed(error.localizedDescription)
        } catch {
            throw HTTPJSONPluginError.modelCatalogMappingFailed("The response could not be decoded.")
        }
    }
}

enum ModelCatalogSyncPhase: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case stale
    case failed
}

struct ModelCatalogProviderState: Codable, Equatable, Sendable {
    let providerID: String
    var trustedSnapshot: ModelCatalogSnapshot?
    var baselineRevision: String?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var isStale: Bool

    init(providerID: String) {
        self.providerID = providerID
        self.trustedSnapshot = nil
        self.baselineRevision = nil
        self.lastAttemptAt = nil
        self.lastSuccessAt = nil
        self.lastError = nil
        self.isStale = false
    }
}

struct ModelCatalogStatus: Equatable, Sendable {
    let phase: ModelCatalogSyncPhase
    let providerCount: Int
    let recordCount: Int
    let lastSuccessAt: Date?
    let lastError: String?
    let revision: String?

    static let empty = ModelCatalogStatus(
        phase: .idle,
        providerCount: 0,
        recordCount: 0,
        lastSuccessAt: nil,
        lastError: nil,
        revision: nil
    )
}

struct ModelCatalogStore: Sendable {
    static let maximumRetainedRecords = 20_000
    static let suspiciousCollapseMinimumRecords = 20

    private let fileURL: URL
    private(set) var providers: [String: ModelCatalogProviderState]

    var persistenceURL: URL { fileURL }

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("ModelCatalog.json", isDirectory: false)
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: ModelCatalogProviderState].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = [:]
        }
    }

    var entries: [ModelCatalogEntry] {
        entries(for: nil)
    }

    func entries(for providerIDs: Set<String>?) -> [ModelCatalogEntry] {
        let projected = providers.values
            .filter { providerIDs == nil || providerIDs?.contains($0.providerID) == true }
            .compactMap(\.trustedSnapshot)
            .flatMap(\.entries)

        return ModelCatalogEntry.deduplicated(projected)
            .sorted { lhs, rhs in
                let lhsName = lhs.modelName.lowercased()
                let rhsName = rhs.modelName.lowercased()
                if lhsName == rhsName { return lhs.id < rhs.id }
                return lhsName < rhsName
            }
    }

    var revision: String? {
        revision(for: nil)
    }

    func revision(for providerIDs: Set<String>?) -> String? {
        let values: [String] = providers.values.compactMap { state in
            guard providerIDs == nil || providerIDs?.contains(state.providerID) == true,
                  let snapshot = state.trustedSnapshot else { return nil }
            return "\(state.providerID):\(snapshot.revision)"
        }.sorted()
        guard !values.isEmpty else { return nil }
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The semantic catalog revision intentionally normalizes away provider
    /// record IDs and raw display casing/whitespace because those changes are
    /// not pricing or model-definition changes. The UI still renders those
    /// raw values and uses IDs as List identity, so keep an independent
    /// projection revision for invalidating the catalog view cache.
    func entryProjectionRevision(for providerIDs: Set<String>?) -> String? {
        let projectedEntries = entries(for: providerIDs)
        guard !projectedEntries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(projectedEntries) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var lastAttemptAt: Date? {
        lastAttemptAt(for: nil)
    }

    func lastAttemptAt(for providerIDs: Set<String>?) -> Date? {
        providers.values
            .filter { providerIDs == nil || providerIDs?.contains($0.providerID) == true }
            .compactMap(\.lastAttemptAt)
            .max()
    }

    /// A provider with no persisted state has never been reconciled in this
    /// installation. Scheduling must treat that as immediately due even when
    /// another active provider has a recent successful refresh.
    func hasUninitializedProvider(for providerIDs: Set<String>) -> Bool {
        providerIDs.contains { providers[$0] == nil }
    }

    /// Returns only the scheduling metadata needed by the watchdog. Keeping
    /// this separate from `status(for:)` is important: status also projects,
    /// de-duplicates, and sorts every retained catalog entry for the UI.
    func lastSuccessAt(for providerIDs: Set<String>?) -> Date? {
        providers.values
            .filter { providerIDs == nil || providerIDs?.contains($0.providerID) == true }
            .compactMap(\.lastSuccessAt)
            .max()
    }

    var status: ModelCatalogStatus {
        status(for: nil)
    }

    func status(for providerIDs: Set<String>?) -> ModelCatalogStatus {
        status(for: providerIDs, projectedEntries: nil)
    }

    private func status(
        for providerIDs: Set<String>?,
        projectedEntries: [ModelCatalogEntry]?
    ) -> ModelCatalogStatus {
        let states = providers.values
            .filter { providerIDs == nil || providerIDs?.contains($0.providerID) == true }
            .sorted { $0.providerID < $1.providerID }
        guard !states.isEmpty else { return .empty }
        let successful = states.compactMap(\.lastSuccessAt)
        let error = states.compactMap(\.lastError).first
        let phase: ModelCatalogSyncPhase
        if states.contains(where: { $0.isStale && $0.trustedSnapshot != nil }) {
            phase = .stale
        } else if states.allSatisfy({ $0.trustedSnapshot != nil }) {
            phase = .ready
        } else if error != nil {
            phase = .failed
        } else {
            phase = .idle
        }
        return ModelCatalogStatus(
            phase: phase,
            providerCount: states.count,
            recordCount: (projectedEntries ?? entries(for: providerIDs)).count,
            lastSuccessAt: successful.max(),
            lastError: error,
            revision: revision(for: providerIDs)
        )
    }

    mutating func markAttempt(providerID: String, at date: Date) {
        var state = providers[providerID] ?? ModelCatalogProviderState(providerID: providerID)
        state.lastAttemptAt = date
        providers[providerID] = state
    }

    mutating func applySuccess(
        _ snapshot: ModelCatalogSnapshot,
        at date: Date
    ) throws -> [NotificationFeedEvent] {
        guard snapshot.entries.count <= Self.maximumRetainedRecords else {
            throw ModelCatalogStoreError.suspiciousResponse
        }
        var state = providers[snapshot.providerID] ?? ModelCatalogProviderState(providerID: snapshot.providerID)
        if let old = state.trustedSnapshot,
           old.entries.count >= Self.suspiciousCollapseMinimumRecords,
           snapshot.entries.count * 2 < old.entries.count {
            throw ModelCatalogStoreError.suspiciousResponse
        }

        let events: [NotificationFeedEvent]
        if let old = state.trustedSnapshot,
           old.identitySchemaVersion != snapshot.identitySchemaVersion
               || old.pricingSchemaVersion != snapshot.pricingSchemaVersion {
            // Stable identity or pricing normalization changes are internal
            // migrations, not provider catalog changes. Replace the trusted
            // snapshot and establish a new baseline without emitting add,
            // remove, or false pricing-change events.
            state.baselineRevision = snapshot.revision
            events = []
        } else if state.baselineRevision == nil {
            state.baselineRevision = snapshot.revision
            events = []
        } else {
            events = ModelCatalogDiff.events(from: state.trustedSnapshot, to: snapshot, at: date)
        }
        state.trustedSnapshot = snapshot
        state.lastAttemptAt = date
        state.lastSuccessAt = date
        state.lastError = nil
        state.isStale = false
        providers[snapshot.providerID] = state
        return events
    }

    mutating func applyFailure(providerID: String, error: Error, at date: Date) {
        applyFailure(
            providerID: providerID,
            message: error.localizedDescription,
            at: date
        )
    }

    mutating func applyFailure(providerID: String, message: String, at date: Date) {
        var state = providers[providerID] ?? ModelCatalogProviderState(providerID: providerID)
        state.lastAttemptAt = date
        state.lastError = Self.safeMessage(message)
        state.isStale = state.trustedSnapshot != nil
        providers[providerID] = state
    }

    func save(fileManager: FileManager = .default) throws {
        try writeEncodedData(try encodedData(), fileManager: fileManager)
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(providers)
    }

    func writeEncodedData(
        _ data: Data,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func safeMessage(_ rawMessage: String) -> String {
        let message = rawMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((message.isEmpty ? "Model catalog refresh failed." : message).prefix(240))
    }
}

/// A synchronous fence closes the race between a main-actor provider
/// replacement and an already-enqueued persistence write. The lock is held
/// only for the atomic file operation, so invalidation cannot complete while a
/// stale generation is in the middle of writing.
final class ModelCatalogGenerationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidatedThrough = 0

    func invalidate(upTo generation: Int) {
        lock.lock()
        invalidatedThrough = max(invalidatedThrough, generation)
        lock.unlock()
    }

    func writeIfValid(
        generation: Int,
        data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation > invalidatedThrough else { return false }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return true
    }
}

/// A serial writer keeps catalog file I/O off the main actor while preserving
/// commit order when a provider configuration changes during a save.
actor ModelCatalogPersistence {
    private var committedGeneration = 0
    private let fence: ModelCatalogGenerationFence

    init(fence: ModelCatalogGenerationFence = ModelCatalogGenerationFence()) {
        self.fence = fence
    }

    /// Invalidation is deliberately nonisolated so the main actor can close
    /// the race before cancelling an old refresh task.
    nonisolated func invalidate(upTo generation: Int) {
        fence.invalidate(upTo: generation)
    }

    func save(
        _ data: Data,
        to url: URL,
        generation: Int,
        fileManager: FileManager = .default
    ) throws {
        // A cancelled provider generation may finish after its replacement.
        // Do not let its late disk write overwrite the newer snapshot.
        guard generation >= committedGeneration else { return }
        if try fence.writeIfValid(
            generation: generation,
            data: data,
            to: url,
            fileManager: fileManager
        ) {
            committedGeneration = generation
        }
    }
}

struct ModelCatalogPreparedBatch: Sendable {
    let store: ModelCatalogStore
    let entries: [ModelCatalogEntry]
    let status: ModelCatalogStatus
    let events: [NotificationFeedEvent]
    let encodedData: Data
}

extension ModelCatalogStore {
    /// Performs the expensive diff, projection, and JSON encoding on a worker
    /// value. The caller commits the returned value only after rechecking the
    /// provider-generation token on the main actor.
    static func prepareBatch(
        from base: ModelCatalogStore,
        providerIDs: [String],
        activeProviderIDs: Set<String>,
        outcomes: [ModelCatalogFetchOutcome],
        startedAt: Date,
        completedAt: Date
    ) throws -> ModelCatalogPreparedBatch {
        var store = base
        for providerID in providerIDs {
            try Task.checkCancellation()
            store.markAttempt(providerID: providerID, at: startedAt)
        }

        var events: [NotificationFeedEvent] = []
        for outcome in outcomes {
            try Task.checkCancellation()
            switch outcome {
            case let .success(snapshot):
                do {
                    events.append(contentsOf: try store.applySuccess(snapshot, at: completedAt))
                } catch {
                    // A suspicious response fails only this provider. Its
                    // previous trusted snapshot remains in the batch while
                    // other providers can still commit successfully.
                    store.applyFailure(
                        providerID: snapshot.providerID,
                        message: error.localizedDescription,
                        at: completedAt
                    )
                }
            case let .failure(providerID, message):
                store.applyFailure(
                    providerID: providerID,
                    message: message,
                    at: completedAt
                )
            }
        }

        try Task.checkCancellation()
        let projectedEntries = store.entries(for: activeProviderIDs)
        return ModelCatalogPreparedBatch(
            store: store,
            entries: projectedEntries,
            status: store.status(for: activeProviderIDs, projectedEntries: projectedEntries),
            events: ModelCatalogDiff.boundedNotificationBatch(events, at: completedAt),
            encodedData: try store.encodedData()
        )
    }
}

enum ModelCatalogStoreError: Error, Equatable, Sendable {
    case suspiciousResponse
}

extension ModelCatalogStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .suspiciousResponse:
            return "The model catalog response looked incomplete and was not trusted."
        }
    }
}

enum ModelCatalogDiff {
    static let maximumDetailedNotificationEvents = 24

    static func events(
        from old: ModelCatalogSnapshot?,
        to new: ModelCatalogSnapshot,
        at date: Date
    ) -> [NotificationFeedEvent] {
        let oldByIdentity = Dictionary(grouping: old?.entries ?? [], by: \.semanticIdentity)
        let newByIdentity = Dictionary(grouping: new.entries, by: \.semanticIdentity)
        var result = [NotificationFeedEvent]()

        let identities = Set(oldByIdentity.keys).union(newByIdentity.keys).sorted { lhs, rhs in
            semanticIdentityKey(lhs) < semanticIdentityKey(rhs)
        }
        for identity in identities {
            let oldEntries = oldByIdentity[identity] ?? []
            let newEntries = newByIdentity[identity] ?? []
            guard let entry = newEntries.first ?? oldEntries.first else { continue }

            if oldEntries.isEmpty {
                result.append(makeEvent(kind: .modelAdded, entry: entry, revision: new.revision, date: date))
                continue
            }
            if newEntries.isEmpty {
                result.append(makeEvent(kind: .modelRemoved, entry: entry, revision: new.revision, date: date))
                continue
            }

            let wasEnabled = oldEntries.contains { $0.enabled != false }
            let isEnabled = newEntries.contains { $0.enabled != false }
            if wasEnabled != isEnabled {
                let kind: NotificationEventKind = isEnabled ? .modelEnabled : .modelDisabled
                result.append(makeEvent(kind: kind, entry: entry, revision: new.revision, date: date))
            }

            let oldPricing = Set(oldEntries.map(\.semanticPricingFingerprint))
            let newPricing = Set(newEntries.map(\.semanticPricingFingerprint))
            if oldPricing != newPricing {
                result.append(makeEvent(kind: .pricingChanged, entry: entry, revision: new.revision, date: date))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// A large provider diff should not evict hundreds of unrelated unread
    /// notifications from the bounded feed. Keep a small deterministic sample
    /// and replace the remainder with one count summary per provider.
    static func boundedNotificationBatch(
        _ events: [NotificationFeedEvent],
        at date: Date
    ) -> [NotificationFeedEvent] {
        guard events.count > maximumDetailedNotificationEvents else { return events }

        let detailed = Array(events.prefix(maximumDetailedNotificationEvents))
        let omitted = events.dropFirst(maximumDetailedNotificationEvents)
        let grouped = Dictionary(grouping: omitted) { $0.sourceID }
        let stamp = String(date.timeIntervalSinceReferenceDate.bitPattern)
        let summaries = grouped.keys.sorted().map { sourceID in
            let providerEvents = grouped[sourceID] ?? []
            var counts: [String: Int] = [:]
            for event in providerEvents {
                counts[event.type.rawValue, default: 0] += 1
            }
            let summary = NotificationCatalogChangeSummary(
                added: counts[NotificationEventKind.modelAdded.rawValue] ?? 0,
                removed: counts[NotificationEventKind.modelRemoved.rawValue] ?? 0,
                enabled: counts[NotificationEventKind.modelEnabled.rawValue] ?? 0,
                disabled: counts[NotificationEventKind.modelDisabled.rawValue] ?? 0,
                pricingChanged: counts[NotificationEventKind.pricingChanged.rawValue] ?? 0
            )
            let breakdown = [
                (NotificationEventKind.modelAdded, "added"),
                (NotificationEventKind.modelRemoved, "removed"),
                (NotificationEventKind.modelEnabled, "enabled"),
                (NotificationEventKind.modelDisabled, "disabled"),
                (NotificationEventKind.pricingChanged, "pricing changed")
            ].compactMap { kind, label in
                guard let count = counts[kind.rawValue] else { return nil }
                return "\(label): \(count)"
            }.joined(separator: ", ")
            let eventID = NotificationFeedEvent.stableID(
                sourceKind: .plugin,
                sourceID: sourceID,
                type: .catalogUpdated,
                occurrenceKey: "catalog-batch|\(stamp)"
            )
            return NotificationFeedEvent(
                id: eventID,
                sourceID: sourceID,
                sourceKind: .plugin,
                type: .catalogUpdated,
                severity: .info,
                title: "Model catalog updated",
                body: "\(providerEvents.count) additional catalog changes (\(breakdown)).",
                catalogChangeSummary: summary,
                createdAt: date,
                isRead: false,
                isDismissed: false
            )
        }
        return detailed + summaries
    }

    private static func semanticIdentityKey(_ identity: ModelCatalogEntrySemanticIdentity) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(identity)) ?? Data()).base64EncodedString()
    }

    private static func makeEvent(
        kind: NotificationEventKind,
        entry: ModelCatalogEntry,
        revision: String,
        date: Date
    ) -> NotificationFeedEvent {
        let label: String
        switch kind.rawValue {
        case NotificationEventKind.modelAdded.rawValue: label = "Model added"
        case NotificationEventKind.modelRemoved.rawValue: label = "Model removed"
        case NotificationEventKind.modelEnabled.rawValue: label = "Model enabled"
        case NotificationEventKind.modelDisabled.rawValue: label = "Model disabled"
        case NotificationEventKind.pricingChanged.rawValue: label = "Model pricing changed"
        default: label = "Model catalog changed"
        }
        let source = entry.providerID ?? entry.source.rawValue
        let eventID = NotificationFeedEvent.stableID(
            sourceKind: .plugin,
            sourceID: source,
            type: kind,
            occurrenceKey: "\(entry.semanticIdentityKey)|\(revision)"
        )
        let route = entry.route.map { " · \($0)" } ?? ""
        return NotificationFeedEvent(
            id: eventID,
            sourceID: source,
            sourceKind: .plugin,
            type: kind,
            title: label,
            body: "\(entry.modelName)\(route)",
            createdAt: date,
            isRead: false,
            isDismissed: false
        )
    }
}
