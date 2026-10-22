import CryptoKit
import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case let .number(value) = self {
            return Double(String(describing: value))
        }
        return nil
    }

    var integerValue: Int64? {
        guard case let .number(value) = self else { return nil }
        let integer = NSDecimalNumber(decimal: value).int64Value
        return Decimal(integer) == value ? integer : nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var searchableText: String {
        switch self {
        case .null:
            return ""
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return NSDecimalNumber(decimal: value).stringValue
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.searchableText).joined(separator: " ")
        case let .object(values):
            return values
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value.searchableText)" }
                .joined(separator: " ")
        }
    }

    func merged(with incoming: JSONValue) -> JSONValue {
        guard case let .object(existing) = self,
              case let .object(incoming) = incoming else {
            return incoming
        }

        var result = existing
        for (key, value) in incoming {
            result[key] = result[key]?.merged(with: value) ?? value
        }
        return .object(result)
    }
}

struct ModelCatalogMetadata: Codable, Equatable, Sendable {
    var modelInfo: [String: JSONValue]
    var litellmParams: [String: JSONValue]

    static let empty = ModelCatalogMetadata(modelInfo: [:], litellmParams: [:])

    func merged(with incoming: ModelCatalogMetadata) -> ModelCatalogMetadata {
        ModelCatalogMetadata(
            modelInfo: mergeObjects(modelInfo, incoming.modelInfo),
            litellmParams: mergeObjects(litellmParams, incoming.litellmParams)
        )
    }

    private func mergeObjects(
        _ existing: [String: JSONValue],
        _ incoming: [String: JSONValue]
    ) -> [String: JSONValue] {
        var result = existing
        for (key, value) in incoming {
            result[key] = result[key]?.merged(with: value) ?? value
        }
        return result
    }

    func value(for key: String) -> JSONValue? {
        modelInfo[key]
    }

    func string(for key: String) -> String? {
        value(for: key)?.stringValue
    }

    func double(for key: String) -> Double? {
        value(for: key)?.doubleValue
    }

    func integer(for key: String) -> Int64? {
        value(for: key)?.integerValue
    }

    var searchableText: String {
        [modelInfo, litellmParams]
            .map { values in
                values.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value.searchableText)" }
                    .joined(separator: " ")
            }
            .joined(separator: " ")
    }
}

enum ModelCatalogEntrySource: String, Codable, Equatable, Sendable {
    case custom
    case remote
}

struct ModelCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let modelName: String
    let pricing: CustomModelPricing
    let metadata: ModelCatalogMetadata
    let source: ModelCatalogEntrySource
    let providerID: String?
    let recordIdentity: String?
    let enabled: Bool?
    let pricingSchedule: CanonicalModelPricing?

    init(
        id: String,
        modelName: String,
        pricing: CustomModelPricing,
        metadata: ModelCatalogMetadata,
        source: ModelCatalogEntrySource = .custom,
        providerID: String? = nil,
        recordIdentity: String? = nil,
        enabled: Bool? = nil,
        pricingSchedule: CanonicalModelPricing? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.pricing = pricing
        self.metadata = metadata
        self.source = source
        self.providerID = providerID
        self.recordIdentity = recordIdentity
        self.enabled = enabled
        self.pricingSchedule = pricingSchedule
    }

    private var pageDisplayData: [String: JSONValue] {
        metadata.value(for: "page_display_data")?.objectValue ?? [:]
    }

    var provider: String? {
        metadata.string(for: "litellm_provider") ?? pageDisplayData["provider"]?.stringValue
    }

    var route: String? {
        metadata.litellmParams["model"]?.stringValue
    }

    var key: String? {
        metadata.string(for: "key")
    }

    var mode: String? {
        metadata.string(for: "mode")
    }

    var baseModel: String? {
        metadata.string(for: "base_model")
    }

    var description: String? {
        pageDisplayData["description"]?.stringValue ?? metadata.string(for: "description")
    }

    var version: String? {
        pageDisplayData["version"]?.stringValue
    }

    var modalities: [String] {
        let pageValues = pageDisplayData["modality"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !pageValues.isEmpty { return pageValues }
        return metadata.value(for: "modalities")?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    var maxInputTokens: Int64? { metadata.integer(for: "max_input_tokens") }
    var maxOutputTokens: Int64? { metadata.integer(for: "max_output_tokens") }
    var maxTokens: Int64? { metadata.integer(for: "max_tokens") }

    var capabilityKeys: [String] {
        [
            "supports_vision",
            "supports_function_calling",
            "supports_reasoning",
            "supports_prompt_caching",
            "supports_tool_choice",
            "supports_native_structured_output",
            "supports_pdf_input",
            "supports_audio_input",
            "supports_computer_use",
            "supports_web_search"
        ].filter { metadata.value(for: $0)?.boolValue == true }
    }

    func rateValue(for key: String) -> Double? {
        switch key {
        case "input_cost_per_token": return pricing.inputCostPerToken
        case "output_cost_per_token": return pricing.outputCostPerToken
        case "cache_creation_input_token_cost":
            return source == .remote ? (pricing.cacheCreationInputTokenCost ?? 0) : pricing.cacheCreationInputTokenCost
        case "cache_read_input_token_cost":
            return source == .remote ? (pricing.cacheReadInputTokenCost ?? 0) : pricing.cacheReadInputTokenCost
        default: return metadata.double(for: key)
        }
    }

    var searchableText: String {
        [
            modelName,
            provider,
            route,
            key,
            baseModel,
            source.rawValue,
            providerID,
            recordIdentity,
            metadata.searchableText
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

/// The identity fields that describe one provider billing record. Catalog
/// record IDs are deliberately absent: ExampleGateway/CCSwitch can regenerate those
/// IDs while keeping the model, route, and price unchanged.
struct ModelCatalogEntrySemanticIdentity: Codable, Equatable, Hashable, Sendable {
    let source: ModelCatalogEntrySource
    let providerID: String?
    let modelName: String
    let provider: String?
    let route: String?
    let key: String?
    let baseModel: String?
    let mode: String?
    let version: String?
}

/// A canonical record projection used by revisioning, duplicate suppression,
/// and change detection. It intentionally keeps descriptive metadata, but
/// removes transport/identity fields and rate fields duplicated by the
/// canonical pricing schedule.
struct ModelCatalogEntrySemanticRecord: Codable, Equatable, Sendable {
    let identity: ModelCatalogEntrySemanticIdentity
    let pricing: CustomModelPricing
    let metadata: ModelCatalogMetadata
    let enabled: Bool
    let pricingSchedule: CanonicalModelPricing?
}

extension ModelCatalogEntry {
    /// Removes only exact remote-record duplicates whose catalog identity is
    /// the sole difference. The raw snapshot remains untouched so record IDs
    /// and provenance are still available for diagnostics.
    static func deduplicated(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var fingerprints = Set<String>()
        let ordered = entries
            .map { (entry: $0, fingerprint: $0.semanticRecordFingerprint) }
            .sorted { lhs, rhs in
                if lhs.fingerprint != rhs.fingerprint {
                    return lhs.fingerprint < rhs.fingerprint
                }
                if lhs.entry.id != rhs.entry.id {
                    return lhs.entry.id < rhs.entry.id
                }
                return lhs.entry.modelName < rhs.entry.modelName
            }
        return ordered.compactMap { item in
            guard item.entry.source == .remote else { return item.entry }
            return fingerprints.insert(item.fingerprint).inserted ? item.entry : nil
        }
    }

    /// The model identity used for semantic catalog diffs. The normalization
    /// is limited to comparison keys; the raw display values remain available
    /// on the original entry for UI and diagnostics.
    var semanticIdentity: ModelCatalogEntrySemanticIdentity {
        ModelCatalogEntrySemanticIdentity(
            source: source,
            providerID: normalizedMetadataValue(providerID),
            modelName: PricingModelIdentity.matchingKey(modelName),
            provider: normalizedMetadataValue(provider),
            route: normalizedMetadataValue(route),
            key: normalizedMetadataValue(key),
            baseModel: normalizedMetadataValue(baseModel),
            mode: normalizedMetadataValue(mode),
            version: normalizedMetadataValue(version)
        )
    }

    /// The pricing-only portion of the semantic projection. It is separate
    /// from the full record so adding/removing an ID-only duplicate cannot
    /// look like a price change in ModelCatalogDiff.
    var semanticPricingFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = SemanticPricingPayload(
            pricing: normalizedRemotePricing(pricing),
            pricingSchedule: normalizedRemoteSchedule(pricingSchedule)
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return data.base64EncodedString()
    }

    var semanticRecord: ModelCatalogEntrySemanticRecord {
        ModelCatalogEntrySemanticRecord(
            identity: semanticIdentity,
            pricing: normalizedRemotePricing(pricing),
            metadata: semanticMetadata,
            enabled: enabled ?? true,
            pricingSchedule: normalizedRemoteSchedule(pricingSchedule)
        )
    }

    /// A stable, encoded semantic identity for event occurrence keys.
    var semanticIdentityKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(semanticIdentity)) ?? Data()).base64EncodedString()
    }

    var semanticRecordFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(semanticRecord)) ?? Data()).base64EncodedString()
    }

    private var semanticMetadata: ModelCatalogMetadata {
        var modelInfo = metadata.modelInfo
        // `model_info.id` is the provider record identity. Rate fields are
        // represented by `pricing`/`pricingSchedule`; removing them avoids a
        // false revision when a remote null cache field becomes numeric zero.
        modelInfo = modelInfo.filter { key, _ in !Self.isPricingMetadataKey(key) && key != "id" }
        return ModelCatalogMetadata(modelInfo: modelInfo, litellmParams: metadata.litellmParams)
    }

    private struct SemanticPricingPayload: Encodable {
        let pricing: CustomModelPricing
        let pricingSchedule: CanonicalModelPricing?
    }

    private static func isPricingMetadataKey(_ key: String) -> Bool {
        let baseKeys = [
            "input_cost_per_token",
            "output_cost_per_token",
            "cache_creation_input_token_cost",
            "cache_read_input_token_cost"
        ]
        if baseKeys.contains(key) { return true }
        return baseKeys.contains { key.hasPrefix($0 + "_above_") && key.hasSuffix("_tokens") }
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRemotePricing(_ value: CustomModelPricing) -> CustomModelPricing {
        guard source == .remote else { return value }
        return CustomModelPricing(
            inputCostPerToken: value.inputCostPerToken,
            outputCostPerToken: value.outputCostPerToken,
            cacheCreationInputTokenCost: value.cacheCreationInputTokenCost ?? 0,
            cacheReadInputTokenCost: value.cacheReadInputTokenCost ?? 0
        )
    }

    private func normalizedRemoteSchedule(_ value: CanonicalModelPricing?) -> CanonicalModelPricing? {
        guard source == .remote, let value else { return value }
        return CanonicalModelPricing(
            modelName: semanticIdentity.modelName,
            base: normalizedRemoteRates(value.base),
            tiers: value.tiers.map { tier in
                PricingTier(threshold: tier.threshold, rates: normalizedRemoteRates(tier.rates))
            },
            maxInputTokens: value.maxInputTokens,
            fastMultiplier: value.fastMultiplier
        )
    }

    private func normalizedRemoteRates(_ value: PricingRates) -> PricingRates {
        PricingRates(
            input: value.input,
            output: value.output,
            cacheCreation: value.cacheCreation ?? 0,
            cacheRead: value.cacheRead ?? 0
        )
    }

    static func semanticRevisionProjection(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntrySemanticRecord] {
        deduplicated(entries)
            .map(\.semanticRecord)
            .sorted { semanticRecordKey($0) < semanticRecordKey($1) }
    }

    private static func semanticRecordKey(_ record: ModelCatalogEntrySemanticRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(record)) ?? Data()).base64EncodedString()
    }
}

enum CustomPricingError: LocalizedError {
    case noEntries

    var errorDescription: String? {
        switch self {
        case .noEntries:
            return "The price list does not contain any model entries."
        }
    }
}

struct CustomPricingTable: Equatable, Sendable {
    private(set) var entries: [String: CustomModelPricing]
    private(set) var displayNames: [String: String]
    private(set) var metadata: [String: ModelCatalogMetadata]
    private let revisionValue: String?

    static let empty = CustomPricingTable(entries: [:])

    var modelCount: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var revision: String? { revisionValue }
    var modelCatalogEntries: [ModelCatalogEntry] {
        entries.keys.sorted().compactMap { key in
            guard let pricing = entries[key] else { return nil }
            return ModelCatalogEntry(
                id: key,
                modelName: displayNames[key] ?? key,
                pricing: pricing,
                metadata: metadata[key] ?? .empty
            )
        }
    }
    var modelNames: Set<String> { Set(entries.keys) }
    var modelNamesWithUsableRates: Set<String> {
        Set(entries.compactMap { key, pricing in
            pricing.hasUsableRate ? key : nil
        })
    }

    func modelNamesWithCompleteRates(in snapshot: UsageSnapshot) -> Set<String> {
        Set(snapshot.models.compactMap { model in
            guard let pricing = pricing(for: model.name),
                  pricing.hasCompleteRates(for: model.tokens) else { return nil }
            return Self.normalize(model.name)
        })
    }

    init(entries: [String: CustomModelPricing]) {
        var normalized: [String: CustomModelPricing] = [:]
        var displayNames: [String: String] = [:]
        for (modelName, pricing) in entries {
            let displayName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalize(displayName)
            guard !key.isEmpty else { continue }
            normalized[key] = normalized[key]?.merging(pricing) ?? pricing
            displayNames[key] = displayNames[key] ?? displayName
        }
        self.init(normalizedEntries: normalized, displayNames: displayNames, metadata: [:])
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    init(data: Data) throws {
        let document = try JSONDecoder().decode(CustomPricingDocument.self, from: data)
        var parsed: [String: CustomModelPricing] = [:]
        var displayNames: [String: String] = [:]
        var parsedMetadata: [String: ModelCatalogMetadata] = [:]

        for record in document.data ?? [] {
            guard let modelName = record.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelName.isEmpty,
                  let modelInfo = record.modelInfo else { continue }
            let key = Self.normalize(modelName)
            let pricing = Self.pricing(from: modelInfo)
            parsed[key] = parsed[key]?.merging(pricing) ?? pricing
            displayNames[key] = displayNames[key] ?? modelName
            let metadata = ModelCatalogMetadata(
                modelInfo: modelInfo,
                litellmParams: record.litellmParams ?? [:]
            )
            parsedMetadata[key] = parsedMetadata[key]?.merged(with: metadata) ?? metadata
        }

        for (modelName, pricing) in document.pricingOverrides ?? [:] {
            let displayName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalize(displayName)
            guard !key.isEmpty else { continue }
            parsed[key] = parsed[key]?.merging(pricing) ?? pricing
            displayNames[key] = displayNames[key] ?? displayName
            let overrideMetadata = ModelCatalogMetadata(modelInfo: Self.metadata(from: pricing), litellmParams: [:])
            parsedMetadata[key] = parsedMetadata[key]?.merged(with: overrideMetadata) ?? overrideMetadata
        }

        guard !parsed.isEmpty else { throw CustomPricingError.noEntries }
        self.init(normalizedEntries: parsed, displayNames: displayNames, metadata: parsedMetadata)
    }

    func pricing(for modelName: String) -> CustomModelPricing? {
        entries[Self.normalize(modelName)]
            ?? entries[PricingModelIdentity.matchingKey(modelName)]
    }

    /// Imports prefer the incoming value for fields it explicitly provides.
    /// Missing fields and models remain available from the existing table.
    func merged(with incoming: CustomPricingTable) -> CustomPricingTable {
        var merged = entries
        var mergedDisplayNames = displayNames
        var mergedMetadata = metadata
        for (modelName, pricing) in incoming.entries {
            merged[modelName] = merged[modelName]?.merging(pricing) ?? pricing
            mergedDisplayNames[modelName] = incoming.displayNames[modelName] ?? mergedDisplayNames[modelName] ?? modelName
            if let incomingMetadata = incoming.metadata[modelName] {
                mergedMetadata[modelName] = mergedMetadata[modelName]?.merged(with: incomingMetadata) ?? incomingMetadata
            }
        }
        return CustomPricingTable(normalizedEntries: merged, displayNames: mergedDisplayNames, metadata: mergedMetadata)
    }

    /// Exports the canonical LiteLLM-compatible representation used for sharing.
    func encodedData() throws -> Data {
        try Self.canonicalData(entries: entries, displayNames: displayNames, metadata: metadata)
    }

    private static func canonicalData(
        entries: [String: CustomModelPricing],
        displayNames: [String: String],
        metadata: [String: ModelCatalogMetadata]
    ) throws -> Data {
        guard !entries.isEmpty else { throw CustomPricingError.noEntries }
        let records: [CustomPricingRecord] = entries.keys.sorted().compactMap { modelName -> CustomPricingRecord? in
            guard let pricing = entries[modelName] else { return nil }
            let modelMetadata = metadata[modelName] ?? .empty
            var modelInfo = modelMetadata.modelInfo
            Self.applyPricing(pricing, to: &modelInfo)
            return CustomPricingRecord(
                modelName: displayNames[modelName] ?? modelName,
                modelInfo: modelInfo,
                litellmParams: modelMetadata.litellmParams.isEmpty ? nil : modelMetadata.litellmParams
            )
        }
        let document = CustomPricingDocument(data: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    func write(to url: URL) throws {
        let data = try encodedData()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    private init(
        normalizedEntries: [String: CustomModelPricing],
        displayNames: [String: String],
        metadata: [String: ModelCatalogMetadata]
    ) {
        self.entries = normalizedEntries
        self.displayNames = displayNames
        self.metadata = metadata
        self.revisionValue = (try? Self.canonicalData(entries: normalizedEntries, displayNames: displayNames, metadata: metadata)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func pricing(from modelInfo: [String: JSONValue]) -> CustomModelPricing {
        func rate(_ key: String) -> Double? { modelInfo[key]?.doubleValue }
        return CustomModelPricing(
            inputCostPerToken: rate("input_cost_per_token"),
            outputCostPerToken: rate("output_cost_per_token"),
            cacheCreationInputTokenCost: rate("cache_creation_input_token_cost"),
            cacheReadInputTokenCost: rate("cache_read_input_token_cost")
        )
    }

    private static func applyPricing(_ pricing: CustomModelPricing, to modelInfo: inout [String: JSONValue]) {
        let values: [(String, Double?)] = [
            ("input_cost_per_token", pricing.inputCostPerToken),
            ("output_cost_per_token", pricing.outputCostPerToken),
            ("cache_creation_input_token_cost", pricing.cacheCreationInputTokenCost),
            ("cache_read_input_token_cost", pricing.cacheReadInputTokenCost)
        ]
        for (key, value) in values {
            if let value,
               let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) {
                // The four active pricing fields are authoritative. Imported
                // metadata may contain an older value (notably legacy
                // `pricingOverrides`), so it must not win during persistence.
                modelInfo[key] = .number(decimal)
            }
        }
    }

    private static func metadata(from pricing: CustomModelPricing) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        applyPricing(pricing, to: &values)
        return values
    }

    private static func normalize(_ modelName: String) -> String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct CustomModelPricing: Codable, Equatable, Sendable {
    let inputCostPerToken: Double?
    let outputCostPerToken: Double?
    let cacheCreationInputTokenCost: Double?
    let cacheReadInputTokenCost: Double?

    func merging(_ other: CustomModelPricing) -> CustomModelPricing {
        CustomModelPricing(
            inputCostPerToken: other.inputCostPerToken ?? inputCostPerToken,
            outputCostPerToken: other.outputCostPerToken ?? outputCostPerToken,
            cacheCreationInputTokenCost: other.cacheCreationInputTokenCost ?? cacheCreationInputTokenCost,
            cacheReadInputTokenCost: other.cacheReadInputTokenCost ?? cacheReadInputTokenCost
        )
    }

    func hasCompleteRates(for tokens: TokenTotals) -> Bool {
        (tokens.inputTokens <= 0 || isValidRate(inputCostPerToken))
            && (tokens.outputTokens <= 0 || isValidRate(outputCostPerToken))
            && (tokens.cacheCreationTokens <= 0 || isValidRate(cacheCreationInputTokenCost))
            && (tokens.cacheReadTokens <= 0 || isValidRate(cacheReadInputTokenCost))
    }

    func cost(for tokens: TokenTotals) -> Double {
        componentCost(tokens.inputTokens, rate: inputCostPerToken)
            + componentCost(tokens.outputTokens, rate: outputCostPerToken)
            + componentCost(tokens.cacheCreationTokens, rate: cacheCreationInputTokenCost)
            + componentCost(tokens.cacheReadTokens, rate: cacheReadInputTokenCost)
    }

    private func isValidRate(_ rate: Double?) -> Bool {
        guard let rate else { return false }
        return rate.isFinite && rate >= 0
    }

    private func componentCost(_ tokens: Int64, rate: Double?) -> Double {
        guard tokens > 0, let rate, rate.isFinite, rate >= 0 else { return 0 }
        return Double(tokens) * rate
    }

    fileprivate var hasUsableRate: Bool {
        [inputCostPerToken, outputCostPerToken, cacheCreationInputTokenCost, cacheReadInputTokenCost]
            .contains { rate in
                guard let rate else { return false }
                return rate.isFinite && rate >= 0
            }
    }

    private enum CodingKeys: String, CodingKey {
        case inputCostPerToken
        case outputCostPerToken
        case cacheCreationInputTokenCost
        case cacheReadInputTokenCost
        case inputCostPerTokenSnake = "input_cost_per_token"
        case outputCostPerTokenSnake = "output_cost_per_token"
        case cacheCreationInputTokenCostSnake = "cache_creation_input_token_cost"
        case cacheReadInputTokenCostSnake = "cache_read_input_token_cost"
    }

    init(
        inputCostPerToken: Double?,
        outputCostPerToken: Double?,
        cacheCreationInputTokenCost: Double?,
        cacheReadInputTokenCost: Double?
    ) {
        self.inputCostPerToken = inputCostPerToken
        self.outputCostPerToken = outputCostPerToken
        self.cacheCreationInputTokenCost = cacheCreationInputTokenCost
        self.cacheReadInputTokenCost = cacheReadInputTokenCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputCostPerToken = try container.decodeIfPresent(Double.self, forKey: .inputCostPerToken)
            ?? (try container.decodeIfPresent(Double.self, forKey: .inputCostPerTokenSnake))
        outputCostPerToken = try container.decodeIfPresent(Double.self, forKey: .outputCostPerToken)
            ?? (try container.decodeIfPresent(Double.self, forKey: .outputCostPerTokenSnake))
        cacheCreationInputTokenCost = try container.decodeIfPresent(Double.self, forKey: .cacheCreationInputTokenCost)
            ?? (try container.decodeIfPresent(Double.self, forKey: .cacheCreationInputTokenCostSnake))
        cacheReadInputTokenCost = try container.decodeIfPresent(Double.self, forKey: .cacheReadInputTokenCost)
            ?? (try container.decodeIfPresent(Double.self, forKey: .cacheReadInputTokenCostSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(inputCostPerToken, forKey: .inputCostPerTokenSnake)
        try container.encodeIfPresent(outputCostPerToken, forKey: .outputCostPerTokenSnake)
        try container.encodeIfPresent(cacheCreationInputTokenCost, forKey: .cacheCreationInputTokenCostSnake)
        try container.encodeIfPresent(cacheReadInputTokenCost, forKey: .cacheReadInputTokenCostSnake)
    }
}

private struct CustomPricingDocument: Codable {
    let data: [CustomPricingRecord]?
    let pricingOverrides: [String: CustomModelPricing]?

    init(data: [CustomPricingRecord]) {
        self.data = data
        self.pricingOverrides = nil
    }
}

private struct CustomPricingRecord: Codable {
    let modelName: String?
    let modelInfo: [String: JSONValue]?
    let litellmParams: [String: JSONValue]?

    init(
        modelName: String,
        modelInfo: [String: JSONValue],
        litellmParams: [String: JSONValue]? = nil
    ) {
        self.modelName = modelName
        self.modelInfo = modelInfo
        self.litellmParams = litellmParams
    }

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case modelInfo = "model_info"
        case litellmParams = "litellm_params"
    }
}

/// Legacy App-side calculator retained for migration/tests only. Production
/// refreshes use CcusagePricingAdapter and let ccusage calculate cost once;
/// do not call this from MonitorStore because it cannot represent tiered
/// pricing safely.
enum CustomPricingOverlay {
    static func apply(to snapshot: UsageSnapshot, table: CustomPricingTable) -> UsageSnapshot {
        guard !snapshot.dailyModels.isEmpty else { return snapshot }
        guard !table.isEmpty else {
            return replacingRevision(in: snapshot, with: nil)
        }

        var customMatches = 0
        let dailyModels = snapshot.dailyModels.map { model in
            guard let pricing = table.pricing(for: model.name),
                  pricing.hasCompleteRates(for: model.tokens) else {
                return model
            }
            customMatches += 1
            let cost = pricing.cost(for: model.tokens)
            return DailyModelUsage(
                period: model.period,
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: cost,
                hasKnownPricing: true,
                pricingSource: .custom
            )
        }

        let costsByPeriod = Dictionary(grouping: dailyModels, by: \.period).mapValues { items in
            items.reduce(0) { $0 + $1.estimatedCost }
        }
        let costsByAgent = Dictionary(grouping: dailyModels, by: \.agent).mapValues { items in
            items.reduce(0) { $0 + $1.estimatedCost }
        }
        let costsByModel = Dictionary(grouping: dailyModels, by: { "\($0.agent)::\($0.name)" }).mapValues { items in
            items.reduce(0) { $0 + $1.estimatedCost }
        }
        let pricingKnownByModel = Dictionary(grouping: dailyModels, by: { "\($0.agent)::\($0.name)" }).mapValues { items in
            !items.isEmpty && items.allSatisfy(\.hasKnownPricing)
        }

        let days = snapshot.days.map { day in
            guard let cost = costsByPeriod[day.period] else { return day }
            return DailyUsage(period: day.period, tokens: day.tokens, estimatedCost: cost)
        }
        let agents = snapshot.agents.map { agent in
            guard let cost = costsByAgent[agent.name] else { return agent }
            return AgentUsage(name: agent.name, tokens: agent.tokens, estimatedCost: cost)
        }
        let models = snapshot.models.map { model in
            let key = "\(model.agent)::\(model.name)"
            guard let cost = costsByModel[key] else { return model }
            return ModelUsage(
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: cost,
                hasKnownPricing: pricingKnownByModel[key] ?? model.hasKnownPricing,
                pricingSource: pricingKnownByModel[key] == true ? .custom : model.pricingSource
            )
        }
        let unknownModels = Set(models.filter { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }.map(\.name)).sorted()
        let customDailyModelIDs = Set(dailyModels.compactMap { model -> String? in
            guard model.tokens.totalTokens > 0,
                  table.pricing(for: model.name)?.hasCompleteRates(for: model.tokens) == true else { return nil }
            return model.id
        })
        let hasCustomUsage = !customDailyModelIDs.isEmpty
        let hasUnknownUsage = dailyModels.contains {
            $0.tokens.totalTokens > 0 && !customDailyModelIDs.contains($0.id) && !$0.hasKnownPricing
        }
        let hasCcusageUsage = dailyModels.contains {
            $0.tokens.totalTokens > 0 && !customDailyModelIDs.contains($0.id) && $0.hasKnownPricing
        }
        let pricingSource: PricingSource
        if customMatches == 0 {
            pricingSource = snapshot.pricingSource
        } else if hasCustomUsage && !hasUnknownUsage && !hasCcusageUsage {
            pricingSource = .custom
        } else if hasCustomUsage {
            pricingSource = .mixed
        } else if hasUnknownUsage {
            pricingSource = .unknown
        } else {
            pricingSource = snapshot.pricingSource
        }

        return UsageSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            pricingUpdatedAt: snapshot.pricingUpdatedAt,
            queryScope: snapshot.queryScope,
            customPricingRevision: table.revision,
            days: days,
            dailyModels: dailyModels,
            agents: agents,
            models: models,
            totalTokens: snapshot.totalTokens,
            estimatedCost: days.reduce(0) { $0 + $1.estimatedCost },
            unknownPricingModels: unknownModels,
            pricingSource: pricingSource
        )
    }

    private static func replacingRevision(in snapshot: UsageSnapshot, with revision: String?) -> UsageSnapshot {
        UsageSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            pricingUpdatedAt: snapshot.pricingUpdatedAt,
            queryScope: snapshot.queryScope,
            customPricingRevision: revision,
            days: snapshot.days,
            dailyModels: snapshot.dailyModels,
            agents: snapshot.agents,
            models: snapshot.models,
            totalTokens: snapshot.totalTokens,
            estimatedCost: snapshot.estimatedCost,
            unknownPricingModels: snapshot.unknownPricingModels,
            pricingSource: snapshot.pricingSource
        )
    }
}
