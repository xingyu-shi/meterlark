import Foundation

struct TokenTotals: Codable, Equatable, Sendable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0

    var totalTokens: Int64 {
        [inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens].reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    var hasRepresentableTotal: Bool {
        var total: Int64 = 0
        for value in [inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens] {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return false }
            total = sum
        }
        return true
    }

    static let zero = TokenTotals()

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
    }

    init() {}

    init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
    }

    static func +(lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: saturatingAdd(lhs.inputTokens, rhs.inputTokens),
            outputTokens: saturatingAdd(lhs.outputTokens, rhs.outputTokens),
            cacheCreationTokens: saturatingAdd(lhs.cacheCreationTokens, rhs.cacheCreationTokens),
            cacheReadTokens: saturatingAdd(lhs.cacheReadTokens, rhs.cacheReadTokens)
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    static func +=(lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs = lhs + rhs
    }
}

struct DailyUsage: Codable, Equatable, Identifiable, Sendable {
    let period: String
    var tokens: TokenTotals
    var estimatedCost: Double

    var id: String { period }
}

struct AgentUsage: Codable, Equatable, Identifiable, Sendable {
    let name: String
    var tokens: TokenTotals
    var estimatedCost: Double

    var id: String { name }
}

struct ModelUsage: Codable, Equatable, Identifiable, Sendable {
    let agent: String
    let name: String
    var tokens: TokenTotals
    var estimatedCost: Double
    var hasKnownPricing: Bool
    var pricingSource: ModelPricingSource
    var pricingProviderIDs: [String]
    var pricingTierThreshold: Int64?
    var pricingBackendThreshold: Int64?

    var id: String { "\(agent)::\(name)" }

    init(
        agent: String,
        name: String,
        tokens: TokenTotals,
        estimatedCost: Double,
        hasKnownPricing: Bool,
        pricingSource: ModelPricingSource? = nil,
        pricingProviderIDs: [String] = [],
        pricingTierThreshold: Int64? = nil,
        pricingBackendThreshold: Int64? = nil
    ) {
        self.agent = agent
        self.name = name
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.hasKnownPricing = hasKnownPricing
        self.pricingSource = pricingSource ?? (hasKnownPricing ? .ccusage : .unknown)
        self.pricingProviderIDs = PricingProviderIdentity.normalized(pricingProviderIDs)
        self.pricingTierThreshold = pricingTierThreshold
        self.pricingBackendThreshold = pricingBackendThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case agent, name, tokens, estimatedCost, hasKnownPricing, pricingSource, pricingProviderIDs, pricingTierThreshold, pricingBackendThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        name = try container.decode(String.self, forKey: .name)
        tokens = try container.decode(TokenTotals.self, forKey: .tokens)
        estimatedCost = try container.decode(Double.self, forKey: .estimatedCost)
        hasKnownPricing = try container.decodeIfPresent(Bool.self, forKey: .hasKnownPricing) ?? (estimatedCost > 0)
        pricingSource = try container.decodeIfPresent(ModelPricingSource.self, forKey: .pricingSource)
            ?? (hasKnownPricing ? .ccusage : .unknown)
        pricingProviderIDs = PricingProviderIdentity.normalized(
            try container.decodeIfPresent([String].self, forKey: .pricingProviderIDs) ?? []
        )
        pricingTierThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingTierThreshold)
        pricingBackendThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingBackendThreshold)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        try container.encode(name, forKey: .name)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(estimatedCost, forKey: .estimatedCost)
        try container.encode(hasKnownPricing, forKey: .hasKnownPricing)
        try container.encode(pricingSource, forKey: .pricingSource)
        try container.encode(pricingProviderIDs, forKey: .pricingProviderIDs)
        try container.encodeIfPresent(pricingTierThreshold, forKey: .pricingTierThreshold)
        try container.encodeIfPresent(pricingBackendThreshold, forKey: .pricingBackendThreshold)
    }
}

struct DailyModelUsage: Codable, Equatable, Identifiable, Sendable {
    let period: String
    let agent: String
    let name: String
    var tokens: TokenTotals
    var estimatedCost: Double
    var hasKnownPricing: Bool
    var pricingSource: ModelPricingSource
    var pricingProviderIDs: [String]
    var pricingTierThreshold: Int64?
    var pricingBackendThreshold: Int64?

    var id: String { "\(period)::\(agent)::\(name)" }

    init(
        period: String,
        agent: String,
        name: String,
        tokens: TokenTotals,
        estimatedCost: Double,
        hasKnownPricing: Bool,
        pricingSource: ModelPricingSource? = nil,
        pricingProviderIDs: [String] = [],
        pricingTierThreshold: Int64? = nil,
        pricingBackendThreshold: Int64? = nil
    ) {
        self.period = period
        self.agent = agent
        self.name = name
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.hasKnownPricing = hasKnownPricing
        self.pricingSource = pricingSource ?? (hasKnownPricing ? .ccusage : .unknown)
        self.pricingProviderIDs = PricingProviderIdentity.normalized(pricingProviderIDs)
        self.pricingTierThreshold = pricingTierThreshold
        self.pricingBackendThreshold = pricingBackendThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case period, agent, name, tokens, estimatedCost, hasKnownPricing, pricingSource, pricingProviderIDs, pricingTierThreshold, pricingBackendThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decode(String.self, forKey: .period)
        agent = try container.decode(String.self, forKey: .agent)
        name = try container.decode(String.self, forKey: .name)
        tokens = try container.decode(TokenTotals.self, forKey: .tokens)
        estimatedCost = try container.decode(Double.self, forKey: .estimatedCost)
        hasKnownPricing = try container.decodeIfPresent(Bool.self, forKey: .hasKnownPricing) ?? (estimatedCost > 0)
        pricingSource = try container.decodeIfPresent(ModelPricingSource.self, forKey: .pricingSource)
            ?? (hasKnownPricing ? .ccusage : .unknown)
        pricingProviderIDs = PricingProviderIdentity.normalized(
            try container.decodeIfPresent([String].self, forKey: .pricingProviderIDs) ?? []
        )
        pricingTierThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingTierThreshold)
        pricingBackendThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingBackendThreshold)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(period, forKey: .period)
        try container.encode(agent, forKey: .agent)
        try container.encode(name, forKey: .name)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(estimatedCost, forKey: .estimatedCost)
        try container.encode(hasKnownPricing, forKey: .hasKnownPricing)
        try container.encode(pricingSource, forKey: .pricingSource)
        try container.encode(pricingProviderIDs, forKey: .pricingProviderIDs)
        try container.encodeIfPresent(pricingTierThreshold, forKey: .pricingTierThreshold)
        try container.encodeIfPresent(pricingBackendThreshold, forKey: .pricingBackendThreshold)
    }
}

enum PricingSource: String, Codable, Sendable {
    case ccusage
    case custom
    case remote
    case mixed
    case approximate
    case unknown
}

enum ModelPricingSource: String, Codable, Sendable {
    case ccusage
    case custom
    case remote
    case mixed
    case approximate
    case unknown
}

enum PricingProviderIdentity {
    static func normalized(_ providerIDs: [String]) -> [String] {
        Array(Set(providerIDs.compactMap { providerID in
            let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
    }
}

struct UsageQueryScope: Codable, Equatable, Sendable {
    let since: String
    let until: String
    let timeZone: String
    let lookbackDays: Int
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    let schemaVersion: Int
    let generatedAt: Date
    let pricingUpdatedAt: Date?
    let queryScope: UsageQueryScope?
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    let days: [DailyUsage]
    let dailyModels: [DailyModelUsage]
    let agents: [AgentUsage]
    let models: [ModelUsage]
    let totalTokens: TokenTotals
    let estimatedCost: Double
    let unknownPricingModels: [String]
    let pricingSource: PricingSource

    static let empty = UsageSnapshot(
        schemaVersion: currentSchemaVersion,
        generatedAt: .distantPast,
        pricingUpdatedAt: nil,
        queryScope: nil,
        customPricingRevision: nil,
        modelCatalogRevision: nil,
        days: [],
        dailyModels: [],
        agents: [],
        models: [],
        totalTokens: .zero,
        estimatedCost: 0,
        unknownPricingModels: [],
        pricingSource: .unknown
    )

    var hasData: Bool { !days.isEmpty || !models.isEmpty }

    var todayUsage: DailyUsage? {
        todayUsage(relativeTo: Date())
    }

    func todayUsage(relativeTo now: Date) -> DailyUsage? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let today = formatter.string(from: now)
        return days.first(where: { $0.period == today })
    }

    var primaryTokens: TokenTotals {
        todayUsage?.tokens ?? .zero
    }

    var primaryEstimatedCost: Double {
        todayUsage?.estimatedCost ?? 0
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        pricingUpdatedAt: Date?,
        queryScope: UsageQueryScope? = nil,
        customPricingRevision: String? = nil,
        modelCatalogRevision: String? = nil,
        days: [DailyUsage],
        dailyModels: [DailyModelUsage] = [],
        agents: [AgentUsage],
        models: [ModelUsage],
        totalTokens: TokenTotals,
        estimatedCost: Double,
        unknownPricingModels: [String],
        pricingSource: PricingSource = .unknown
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.pricingUpdatedAt = pricingUpdatedAt
        self.queryScope = queryScope
        self.customPricingRevision = customPricingRevision
        self.modelCatalogRevision = modelCatalogRevision
        self.days = days
        self.dailyModels = dailyModels
        self.agents = agents
        self.models = models
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.unknownPricingModels = unknownPricingModels
        self.pricingSource = pricingSource
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, pricingUpdatedAt, queryScope, customPricingRevision, modelCatalogRevision, days, dailyModels, agents, models, totalTokens, estimatedCost, unknownPricingModels, pricingSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Snapshot schema version \(decodedSchemaVersion) is newer than supported version \(Self.currentSchemaVersion)."
            )
        }
        // Older snapshots are compatible with the additive pricing-source,
        // query-scope, and custom-pricing revision fields. Treat the decoded
        // result as migrated so the next atomic save writes the current schema.
        schemaVersion = Self.currentSchemaVersion
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        pricingUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .pricingUpdatedAt)
        queryScope = try container.decodeIfPresent(UsageQueryScope.self, forKey: .queryScope)
        customPricingRevision = try container.decodeIfPresent(String.self, forKey: .customPricingRevision)
        modelCatalogRevision = try container.decodeIfPresent(String.self, forKey: .modelCatalogRevision)
        days = try container.decodeIfPresent([DailyUsage].self, forKey: .days) ?? []
        dailyModels = try container.decodeIfPresent([DailyModelUsage].self, forKey: .dailyModels) ?? []
        agents = try container.decodeIfPresent([AgentUsage].self, forKey: .agents) ?? []
        models = try container.decodeIfPresent([ModelUsage].self, forKey: .models) ?? []
        totalTokens = try container.decodeIfPresent(TokenTotals.self, forKey: .totalTokens) ?? .zero
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        unknownPricingModels = try container.decodeIfPresent([String].self, forKey: .unknownPricingModels) ?? []
        pricingSource = try container.decodeIfPresent(PricingSource.self, forKey: .pricingSource)
            ?? (unknownPricingModels.isEmpty ? .ccusage : .unknown)
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidSchemaVersion
        case duplicateIdentifiers
        case invalidNumericValue

        var errorDescription: String? {
            switch self {
            case .invalidSchemaVersion: return "Snapshot schema version is invalid."
            case .duplicateIdentifiers: return "Snapshot contains duplicate usage identifiers."
            case .invalidNumericValue: return "Snapshot contains an invalid token or cost value."
            }
        }
    }

    func validate() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw ValidationError.invalidSchemaVersion
        }

        let dayIDs = days.map(\.id)
        let dailyModelIDs = dailyModels.map(\.id)
        let agentIDs = agents.map(\.id)
        let modelIDs = models.map(\.id)
        guard Set(dayIDs).count == dayIDs.count,
              Set(dailyModelIDs).count == dailyModelIDs.count,
              Set(agentIDs).count == agentIDs.count,
              Set(modelIDs).count == modelIDs.count else {
            throw ValidationError.duplicateIdentifiers
        }

        let tokenValues = days.flatMap { [$0.tokens.inputTokens, $0.tokens.outputTokens, $0.tokens.cacheCreationTokens, $0.tokens.cacheReadTokens] }
            + dailyModels.flatMap { [$0.tokens.inputTokens, $0.tokens.outputTokens, $0.tokens.cacheCreationTokens, $0.tokens.cacheReadTokens] }
            + agents.flatMap { [$0.tokens.inputTokens, $0.tokens.outputTokens, $0.tokens.cacheCreationTokens, $0.tokens.cacheReadTokens] }
            + models.flatMap { [$0.tokens.inputTokens, $0.tokens.outputTokens, $0.tokens.cacheCreationTokens, $0.tokens.cacheReadTokens] }
            + [totalTokens.inputTokens, totalTokens.outputTokens, totalTokens.cacheCreationTokens, totalTokens.cacheReadTokens]
        guard tokenValues.allSatisfy({ $0 >= 0 }) else { throw ValidationError.invalidNumericValue }
        let tokenTotals = days.map(\.tokens) + dailyModels.map(\.tokens) + agents.map(\.tokens) + models.map(\.tokens) + [totalTokens]
        guard tokenTotals.allSatisfy(\.hasRepresentableTotal) else { throw ValidationError.invalidNumericValue }

        let costs = days.map(\.estimatedCost) + agents.map(\.estimatedCost) + models.map(\.estimatedCost)
            + dailyModels.map(\.estimatedCost) + [estimatedCost]
        guard costs.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw ValidationError.invalidNumericValue }
    }

    var modelIdentitiesWithUsage: Set<String> {
        Set(models.compactMap { model in
            model.tokens.totalTokens > 0 ? Self.modelIdentity(agent: model.agent, name: model.name) : nil
        })
    }

    var unknownModelIdentities: Set<String> {
        Set(models.compactMap { model in
            guard model.tokens.totalTokens > 0, !model.hasKnownPricing else { return nil }
            return Self.modelIdentity(agent: model.agent, name: model.name)
        })
    }

    /// Recompute the warning from the current model rows instead of trusting
    /// the denormalized persisted list. The list is kept for backwards
    /// compatibility, but a row is the authoritative source after a refresh.
    var liveUnknownPricingModels: [String] {
        let usedModels = models.filter { $0.tokens.totalTokens > 0 }
        guard !usedModels.isEmpty else { return unknownPricingModels }
        return Array(Set(usedModels.compactMap { model in
            guard model.tokens.totalTokens > 0, !model.hasKnownPricing else { return nil }
            return model.name
        })).sorted()
    }

    func addedModelIdentities(comparedTo previous: UsageSnapshot) -> Set<String> {
        guard let queryScope, queryScope == previous.queryScope else { return [] }
        return modelIdentitiesWithUsage.subtracting(previous.modelIdentitiesWithUsage)
    }

    func newlyUnknownModelIdentities(comparedTo previous: UsageSnapshot) -> Set<String> {
        guard let queryScope, queryScope == previous.queryScope else { return [] }
        return unknownModelIdentities.subtracting(previous.unknownModelIdentities)
    }

    static func modelIdentity(agent: String, name: String) -> String {
        "\(normalizeIdentity(agent))::\(normalizeIdentity(name))"
    }

    private static func normalizeIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension UsageSnapshot {
    /// Updates usage while retaining the last trusted cost calculation.
    /// Offline ccusage output can have a different embedded pricing coverage,
    /// so it must not overwrite an online-priced snapshot.
    static func mergingUsage(
        _ candidate: UsageSnapshot,
        preservingPricingFrom previous: UsageSnapshot,
        pricingAssessment: PricingAssessmentContext = .empty
    ) -> UsageSnapshot {
        // A usage refresh may be offline, so the previous pricing is normally
        // the trusted basis. Once the custom table or remote catalog changes,
        // however, every old cost/source/tier belongs to a different basis and
        // must be discarded. Otherwise removing table A can resurrect A's
        // known pricing during the next usage refresh.
        let pricingBasisMatches = candidate.customPricingRevision == previous.customPricingRevision
            && candidate.modelCatalogRevision == previous.modelCatalogRevision
        let catalogGapModelKeys = pricingAssessment.catalogGapModelKeys
        let previousDays = Dictionary(uniqueKeysWithValues: previous.days.map { ($0.period, $0) })
        let previousAgents = Dictionary(uniqueKeysWithValues: previous.agents.map { ($0.name, $0) })
        let previousModels = Dictionary(uniqueKeysWithValues: previous.models.map { ($0.id, $0) })
        let previousDailyModels = Dictionary(uniqueKeysWithValues: previous.dailyModels.map { ($0.id, $0) })

        let dailyModels = candidate.dailyModels.map { model in
            let canPreserveOldPricing = pricingBasisMatches
                || catalogGapModelKeys.contains(PricingModelIdentity.matchingKey(model.name))
            let old = canPreserveOldPricing ? previousDailyModels[model.id] : nil
            let hasKnownPricing = model.hasKnownPricing || old?.hasKnownPricing == true
            let pricingSource: ModelPricingSource
            let pricingProviderIDs: [String]
            let pricingTierThreshold: Int64?
            let pricingBackendThreshold: Int64?
            if model.hasKnownPricing {
                pricingSource = model.pricingSource
                pricingProviderIDs = model.pricingSource == .remote || model.pricingSource == .mixed
                    ? model.pricingProviderIDs
                    : []
                pricingTierThreshold = model.pricingTierThreshold
                pricingBackendThreshold = model.pricingBackendThreshold
            } else if old?.hasKnownPricing == true {
                pricingSource = old?.pricingSource ?? .ccusage
                pricingProviderIDs = old?.pricingSource == .remote || old?.pricingSource == .mixed
                    ? (old?.pricingProviderIDs ?? [])
                    : []
                pricingTierThreshold = old?.pricingTierThreshold
                pricingBackendThreshold = old?.pricingBackendThreshold
            } else {
                pricingSource = .unknown
                pricingProviderIDs = []
                pricingTierThreshold = nil
                pricingBackendThreshold = nil
            }
            return DailyModelUsage(
                period: model.period,
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: model.hasKnownPricing ? model.estimatedCost : (old?.estimatedCost ?? 0),
                hasKnownPricing: hasKnownPricing,
                pricingSource: pricingSource,
                pricingProviderIDs: pricingProviderIDs,
                pricingTierThreshold: pricingTierThreshold,
                pricingBackendThreshold: pricingBackendThreshold
            )
        }

        let dailyModelsByPeriod = Dictionary(grouping: dailyModels, by: \.period)
        let dailyModelsByAgent = Dictionary(grouping: dailyModels, by: \.agent)
        let trustedCostByPeriod = dailyModelsByPeriod.mapValues { items in
            items.reduce(0) { $0 + ($1.hasKnownPricing ? $1.estimatedCost : 0) }
        }
        let trustedCostByAgent = dailyModelsByAgent.mapValues { items in
            items.reduce(0) { $0 + ($1.hasKnownPricing ? $1.estimatedCost : 0) }
        }
        let trustedCostByModel = Dictionary(grouping: dailyModels, by: { "\($0.agent)::\($0.name)" }).mapValues { items in
            items.reduce(0) { $0 + ($1.hasKnownPricing ? $1.estimatedCost : 0) }
        }
        let periodHasUnknownPricing = dailyModelsByPeriod.mapValues { items in
            items.contains { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }
        }
        let agentHasUnknownPricing = dailyModelsByAgent.mapValues { items in
            items.contains { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }
        }
        let previousPricedIDsByPeriod = Dictionary(
            grouping: pricingBasisMatches ? previous.dailyModels.filter(\.hasKnownPricing) : [],
            by: \.period
        ).mapValues { Set($0.map(\.id)) }
        let candidateIDsByPeriod = dailyModelsByPeriod.mapValues { Set($0.map(\.id)) }
        let periodMissingPreviouslyPricedModel = Dictionary(uniqueKeysWithValues: previousPricedIDsByPeriod.map { period, previousIDs in
            (period, !previousIDs.isSubset(of: candidateIDsByPeriod[period] ?? []))
        })
        let candidatePeriods = Set(candidate.dailyModels.map(\.period))
        let previousPricedIDsByAgent = Dictionary(
            grouping: pricingBasisMatches
                ? previous.dailyModels.filter { candidatePeriods.contains($0.period) && $0.hasKnownPricing }
                : [],
            by: \.agent
        ).mapValues { Set($0.map(\.id)) }
        let candidateIDsByAgent = dailyModelsByAgent.mapValues { Set($0.map(\.id)) }
        let agentMissingPreviouslyPricedModel = Dictionary(uniqueKeysWithValues: previousPricedIDsByAgent.map { agent, previousIDs in
            (agent, !previousIDs.isSubset(of: candidateIDsByAgent[agent] ?? []))
        })

        let days = candidate.days.map { day in
            let fallback = pricingBasisMatches ? (previousDays[day.period]?.estimatedCost ?? 0) : 0
            let hasCompleteBreakdown = dailyModelsByPeriod[day.period]?.isEmpty == false
                && periodHasUnknownPricing[day.period] != true
                && periodMissingPreviouslyPricedModel[day.period] != true
            let cost = hasCompleteBreakdown ? (trustedCostByPeriod[day.period] ?? fallback) : fallback
            return DailyUsage(period: day.period, tokens: day.tokens, estimatedCost: cost)
        }

        let agents = candidate.agents.map { agent in
            let fallback = pricingBasisMatches ? (previousAgents[agent.name]?.estimatedCost ?? 0) : 0
            let hasCompleteBreakdown = dailyModelsByAgent[agent.name]?.isEmpty == false
                && agentHasUnknownPricing[agent.name] != true
                && agentMissingPreviouslyPricedModel[agent.name] != true
            let cost = hasCompleteBreakdown ? (trustedCostByAgent[agent.name] ?? fallback) : fallback
            return AgentUsage(name: agent.name, tokens: agent.tokens, estimatedCost: cost)
        }

        let models = candidate.models.map { model in
            let key = "\(model.agent)::\(model.name)"
            let modelItems = dailyModels.filter { $0.agent == model.agent && $0.name == model.name }
            let isKnown = !modelItems.isEmpty && modelItems.allSatisfy(\.hasKnownPricing)
            let canPreserveOldPricing = pricingBasisMatches
                || catalogGapModelKeys.contains(PricingModelIdentity.matchingKey(model.name))
            let previousModel = canPreserveOldPricing ? previousModels[key] : nil
            let fallback = previousModel?.estimatedCost ?? 0
            let cost = isKnown ? (trustedCostByModel[key] ?? fallback) : fallback
            let pricingSource: ModelPricingSource
            let pricingProviderIDs: [String]
            let pricingTierThreshold: Int64?
            let pricingBackendThreshold: Int64?
            if isKnown {
                pricingSource = modelItems.first?.pricingSource ?? model.pricingSource
                pricingProviderIDs = pricingSource == .remote || pricingSource == .mixed
                    ? PricingProviderIdentity.normalized(modelItems.flatMap(\.pricingProviderIDs))
                    : []
                pricingTierThreshold = modelItems.compactMap(\.pricingTierThreshold).first
                pricingBackendThreshold = modelItems.compactMap(\.pricingBackendThreshold).first
            } else if previousModel?.hasKnownPricing == true {
                pricingSource = previousModel?.pricingSource ?? .ccusage
                pricingProviderIDs = pricingSource == .remote || pricingSource == .mixed
                    ? (previousModel?.pricingProviderIDs ?? [])
                    : []
                pricingTierThreshold = previousModel?.pricingTierThreshold
                pricingBackendThreshold = previousModel?.pricingBackendThreshold
            } else {
                pricingSource = .unknown
                pricingProviderIDs = []
                pricingTierThreshold = nil
                pricingBackendThreshold = nil
            }
            return ModelUsage(
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: cost,
                hasKnownPricing: isKnown,
                pricingSource: pricingSource,
                pricingProviderIDs: pricingProviderIDs,
                pricingTierThreshold: pricingTierThreshold,
                pricingBackendThreshold: pricingBackendThreshold
            )
        }

        let unknownModels = Set(models.filter { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }.map(\.name)).sorted()
        let estimatedCost = days.reduce(0) { $0 + $1.estimatedCost }
        let hasFinalModelUsage = models.contains { $0.tokens.totalTokens > 0 }
        let candidateHasUsage = candidate.totalTokens.totalTokens > 0
            || candidate.days.contains { $0.tokens.totalTokens > 0 }
            || candidate.dailyModels.contains { $0.tokens.totalTokens > 0 }
            || candidate.models.contains { $0.tokens.totalTokens > 0 }
        let emptyPricingFallback = candidateHasUsage && !hasFinalModelUsage
            ? (pricingBasisMatches ? previous.pricingSource : .unknown)
            : .unknown
        let pricingSource = PricingSourceAggregation.aggregate(
            for: models,
            emptyFallback: emptyPricingFallback
        )

        return UsageSnapshot(
            schemaVersion: max(candidate.schemaVersion, previous.schemaVersion),
            generatedAt: candidate.generatedAt,
            pricingUpdatedAt: previous.pricingUpdatedAt,
            queryScope: candidate.queryScope,
            customPricingRevision: candidate.customPricingRevision,
            modelCatalogRevision: candidate.modelCatalogRevision,
            days: days,
            dailyModels: dailyModels,
            agents: agents,
            models: models,
            totalTokens: candidate.totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: unknownModels,
            pricingSource: pricingSource
        )
    }
}

enum PricingRefreshPolicy {
    /// Accept a structurally complete report after the active custom pricing
    /// revision changed. The previous snapshot is not a pricing fallback or
    /// comparison baseline; it is used only as a safety reference to prevent
    /// an unpriced zero candidate from erasing a trusted priced result.
    static func acceptsAfterPricingRevisionChange(
        candidate: UsageSnapshot,
        previous: UsageSnapshot? = nil,
        pricingAssessment: PricingAssessmentContext = .empty,
        allowEmptyCandidate: Bool = false
    ) -> Bool {
        guard candidate.hasData || allowEmptyCandidate else { return false }
        guard hasReconciledBreakdown(candidate) else { return false }
        return acceptsSemanticCandidate(
            candidate: candidate,
            previous: previous,
            pricingAssessment: pricingAssessment
        )
    }

    static func accepts(
        candidate: UsageSnapshot,
        previous: UsageSnapshot,
        pricingAssessment: PricingAssessmentContext = .empty,
        allowEmptyCandidate: Bool = false
    ) -> Bool {
        guard candidate.hasData || allowEmptyCandidate else { return false }
        guard hasReconciledBreakdown(candidate) else { return false }
        guard previous.hasData else { return true }

        // A report with token data but no model breakdown cannot be safely
        // compared with the trusted per-model pricing snapshot. Keep the old
        // result even for a manual refresh; a missing breakdown is a malformed
        // or incomplete report, not a legitimate price change.
        if candidate.totalTokens.totalTokens > 0,
           !previous.dailyModels.isEmpty,
           candidate.dailyModels.isEmpty {
            return false
        }

        guard acceptsSemanticCandidate(
            candidate: candidate,
            previous: previous,
            pricingAssessment: pricingAssessment
        ) else { return false }

        // Usage is cumulative for a fixed query scope. A lower token total is
        // a strong signal that the report was incomplete; do not use the old
        // cost-ratio heuristic, because real rates can change by any amount.
        if candidate.hasData,
           candidate.queryScope == previous.queryScope,
           candidate.totalTokens.totalTokens < previous.totalTokens.totalTokens {
            return false
        }

        return true
    }

    private static func acceptsSemanticCandidate(
        candidate: UsageSnapshot,
        previous: UsageSnapshot?,
        pricingAssessment: PricingAssessmentContext
    ) -> Bool {
        guard candidate.totalTokens.totalTokens > 0 else { return true }

        guard previous?.estimatedCost ?? 0 > 0,
              candidate.estimatedCost == 0 else { return true }

        // An explicit all-free table and an intentionally partial table are
        // legitimate zero-cost outcomes. A raw zero without custom coverage,
        // or a zero-bearing tier that could not be evaluated safely, is not a
        // valid replacement for a previously trusted priced snapshot.
        let usedModels = candidate.models.filter { $0.tokens.totalTokens > 0 }
        guard !pricingAssessment.outcomesByModel.isEmpty else {
            // Preserve the conservative legacy behavior for callers that do
            // not have the ephemeral resolver evidence.
            return false
        }
        let hasUnsafeZero = usedModels.contains { model in
            let outcomes = pricingAssessment.outcomes(for: model.name)
            return outcomes.contains(.unpricedZero) || outcomes.contains(.unsupportedCustomZero)
        }
        return !hasUnsafeZero
    }

    fileprivate static func hasReconciledBreakdown(_ snapshot: UsageSnapshot) -> Bool {
        guard snapshot.totalTokens.totalTokens == 0 || !snapshot.dailyModels.isEmpty else { return false }

        let dailyModelsByPeriod = Dictionary(grouping: snapshot.dailyModels, by: \.period)
        let dayPeriods = Set(snapshot.days.map(\.period))
        guard Set(dailyModelsByPeriod.keys).isSubset(of: dayPeriods) else { return false }

        for day in snapshot.days {
            let modelTokens = (dailyModelsByPeriod[day.period] ?? []).reduce(TokenTotals.zero) { $0 + $1.tokens }
            guard modelTokens == day.tokens else { return false }
        }

        for agent in snapshot.agents {
            let modelTokens = snapshot.dailyModels
                .filter { $0.agent == agent.name }
                .reduce(TokenTotals.zero) { $0 + $1.tokens }
            guard modelTokens == agent.tokens else { return false }
        }

        for model in snapshot.models {
            let modelTokens = snapshot.dailyModels
                .filter { $0.agent == model.agent && $0.name == model.name }
                .reduce(TokenTotals.zero) { $0 + $1.tokens }
            guard modelTokens == model.tokens else { return false }
        }

        return true
    }

}

struct CCUsageResponse: Decodable {
    let daily: [CCUsageDailyRow]
    let monthly: [CCUsageMonthlyRow]
    let totals: CCUsageTotals?
    let hasDailySection: Bool

    private enum CodingKeys: String, CodingKey {
        case daily, monthly, totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDaily = try container.decodeIfPresent([CCUsageDailyRow].self, forKey: .daily)
        daily = decodedDaily ?? []
        hasDailySection = decodedDaily != nil
        monthly = try container.decodeIfPresent([CCUsageMonthlyRow].self, forKey: .monthly) ?? []
        totals = try container.decodeIfPresent(CCUsageTotals.self, forKey: .totals)
    }
}

struct CCUsageDailyRow: Decodable {
    let agent: String?
    let agents: [CCUsageAgentRow]?
    let period: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationTokens: Int64?
    let cacheReadTokens: Int64?
    let totalTokens: Int64?
    let totalCost: Double?
    let modelBreakdowns: [CCUsageModelRow]?
}

struct CCUsageMonthlyRow: Decodable {
    let agent: String?
    let agents: [CCUsageAgentRow]?
    let period: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationTokens: Int64?
    let cacheReadTokens: Int64?
    let totalTokens: Int64?
    let totalCost: Double?
    let modelBreakdowns: [CCUsageModelRow]?
}

struct CCUsageAgentRow: Decodable {
    let agent: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationTokens: Int64?
    let cacheReadTokens: Int64?
    let totalTokens: Int64?
    let totalCost: Double?
    let modelBreakdowns: [CCUsageModelRow]?
}

struct CCUsageModelRow: Decodable {
    let modelName: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationTokens: Int64?
    let cacheReadTokens: Int64?
    let totalTokens: Int64?
    let cost: Double?
}

struct CCUsageTotals: Decodable {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationTokens: Int64?
    let cacheReadTokens: Int64?
    let totalTokens: Int64?
    let totalCost: Double?
}

enum UsageSnapshotBuilder {
    static func make(
        from response: CCUsageResponse,
        pricingUpdatedAt: Date?,
        queryScope: UsageQueryScope? = nil
    ) -> UsageSnapshot {
        var days: [DailyUsage] = []
        var dailyModels: [String: DailyModelUsage] = [:]
        var agents: [String: AgentUsage] = [:]
        var models: [String: ModelUsage] = [:]
        var unknownModels = Set<String>()

        for row in response.daily {
            guard let period = row.period ?? (row.agent == "all" ? "Today" : nil) else { continue }
            let rowTokens = TokenTotals(
                inputTokens: row.inputTokens ?? 0,
                outputTokens: row.outputTokens ?? 0,
                cacheCreationTokens: row.cacheCreationTokens ?? 0,
                cacheReadTokens: row.cacheReadTokens ?? 0
            )
            let rowModels = row.agents?.flatMap { $0.modelBreakdowns ?? [] } ?? row.modelBreakdowns ?? []
            let knownRowCost = rowModels.compactMap(knownCost).reduce(0, +)
            let dayCost = rowModels.isEmpty ? (row.totalCost ?? 0) : knownRowCost
            days.append(DailyUsage(period: period, tokens: rowTokens, estimatedCost: dayCost))

            let agentRows = row.agents ?? [CCUsageAgentRow(
                agent: row.agent,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheCreationTokens: row.cacheCreationTokens,
                cacheReadTokens: row.cacheReadTokens,
                totalTokens: row.totalTokens,
                totalCost: row.totalCost,
                modelBreakdowns: row.modelBreakdowns
            )]

            for agentRow in agentRows {
                let agentName = agentRow.agent ?? row.agent ?? "unknown"
                var agentUsage = agents[agentName] ?? AgentUsage(name: agentName, tokens: .zero, estimatedCost: 0)
                agentUsage.tokens += TokenTotals(
                    inputTokens: agentRow.inputTokens ?? 0,
                    outputTokens: agentRow.outputTokens ?? 0,
                    cacheCreationTokens: agentRow.cacheCreationTokens ?? 0,
                    cacheReadTokens: agentRow.cacheReadTokens ?? 0
                )
                let agentModels = agentRow.modelBreakdowns ?? []
                agentUsage.estimatedCost += agentModels.compactMap(knownCost).reduce(0, +)
                agents[agentName] = agentUsage

                for modelRow in agentModels {
                    guard let modelName = modelRow.modelName, !modelName.isEmpty else { continue }
                    let key = "\(agentName)::\(modelName)"
                    var modelUsage = models[key] ?? ModelUsage(
                        agent: agentName,
                        name: modelName,
                        tokens: .zero,
                        estimatedCost: 0,
                        hasKnownPricing: true
                    )
                    let modelTokens = TokenTotals(
                        inputTokens: modelRow.inputTokens ?? 0,
                        outputTokens: modelRow.outputTokens ?? 0,
                        cacheCreationTokens: modelRow.cacheCreationTokens ?? 0,
                        cacheReadTokens: modelRow.cacheReadTokens ?? 0
                    )
                    modelUsage.tokens += modelTokens
                    let rowHasKnownPricing = modelTokens.totalTokens == 0 || knownCost(modelRow) != nil
                    modelUsage.hasKnownPricing = modelUsage.hasKnownPricing && rowHasKnownPricing
                    if let cost = knownCost(modelRow) {
                        modelUsage.estimatedCost += cost
                    }
                    modelUsage.pricingSource = modelUsage.hasKnownPricing ? .ccusage : .unknown
                    modelUsage.pricingTierThreshold = nil
                    models[key] = modelUsage

                    let dailyKey = "\(period)::\(agentName)::\(modelName)"
                    var dailyModel = dailyModels[dailyKey] ?? DailyModelUsage(
                        period: period,
                        agent: agentName,
                        name: modelName,
                        tokens: .zero,
                        estimatedCost: 0,
                        hasKnownPricing: true
                    )
                    dailyModel.tokens += modelTokens
                    dailyModel.hasKnownPricing = dailyModel.hasKnownPricing && rowHasKnownPricing
                    if let cost = knownCost(modelRow) {
                        dailyModel.estimatedCost += cost
                    }
                    dailyModel.pricingSource = dailyModel.hasKnownPricing ? .ccusage : .unknown
                    dailyModel.pricingTierThreshold = nil
                    dailyModels[dailyKey] = dailyModel
                }
            }
        }

        let totalTokens = days.reduce(TokenTotals.zero) { $0 + $1.tokens }
        // `days` is the canonical displayed range. It also carries the
        // top-level ccusage cost when a response has no model breakdown, so
        // deriving the total from models would make the budget row disagree
        // with the chart for otherwise valid responses.
        let estimatedCost = days.reduce(0) { $0 + $1.estimatedCost }

        unknownModels = Set(models.values.filter { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }.map(\.name))

        let pricingSource: PricingSource = unknownModels.isEmpty ? .ccusage : .unknown

        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: pricingUpdatedAt,
            queryScope: queryScope,
            days: days.sorted { $0.period < $1.period },
            dailyModels: dailyModels.values.sorted { $0.id < $1.id },
            agents: agents.values.sorted { $0.estimatedCost > $1.estimatedCost },
            models: models.values.sorted { $0.estimatedCost > $1.estimatedCost },
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: unknownModels.sorted(),
            pricingSource: pricingSource
        )
    }

    static func makeMonthlyBudget(
        from response: CCUsageResponse,
        month: String,
        pricingUpdatedAt: Date?,
        customPricingRevision: String?,
        realtimeAnchorDay: String? = nil
    ) -> MonthlyBudgetSnapshot {
        let matchingRows = response.monthly.filter { $0.period == month }
        let rows: [CCUsageMonthlyRow]
        if let aggregate = matchingRows.first(where: { $0.agent == "all" }) {
            rows = [aggregate]
        } else {
            rows = matchingRows
        }

        var models: [String: MonthlyBudgetModel] = [:]
        var explicitTotalTokens: Int64?
        var fallbackTotalTokens: Int64 = 0
        var fallbackCost = 0.0
        var sawModelBreakdown = false

        for row in rows {
            if let totalTokens = row.totalTokens, totalTokens >= 0 {
                explicitTotalTokens = max(explicitTotalTokens ?? 0, totalTokens)
            }

            let fallbackAgent = CCUsageAgentRow(
                agent: row.agent,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheCreationTokens: row.cacheCreationTokens,
                cacheReadTokens: row.cacheReadTokens,
                totalTokens: row.totalTokens,
                totalCost: row.totalCost,
                modelBreakdowns: row.modelBreakdowns
            )
            let agentRows = row.agents?.isEmpty == false ? row.agents! : [fallbackAgent]
            fallbackTotalTokens += agentRows.reduce(0) { partial, agent in
                saturatingAdd(partial, tokenTotal(for: agent))
            }

            let modelRows = agentRows.flatMap { agent in
                (agent.modelBreakdowns ?? []).map { (agent: agent.agent ?? row.agent ?? "unknown", model: $0) }
            }
            if modelRows.isEmpty {
                fallbackCost += max(0, row.totalCost ?? 0)
                continue
            }

            sawModelBreakdown = true
            for (agentName, modelRow) in modelRows {
                guard let modelName = modelRow.modelName, !modelName.isEmpty else { continue }
                let key = "\(agentName)::\(modelName)"
                var model = models[key] ?? MonthlyBudgetModel(
                    agent: agentName,
                    name: modelName,
                    tokens: .zero,
                    estimatedCost: 0,
                    hasKnownPricing: true
                )
                let modelTokens = TokenTotals(
                    inputTokens: modelRow.inputTokens ?? 0,
                    outputTokens: modelRow.outputTokens ?? 0,
                    cacheCreationTokens: modelRow.cacheCreationTokens ?? 0,
                    cacheReadTokens: modelRow.cacheReadTokens ?? 0
                )
                model.tokens += modelTokens
                let known = modelTokens.totalTokens == 0 || knownCost(modelRow) != nil
                model.hasKnownPricing = model.hasKnownPricing && known
                if let cost = knownCost(modelRow) {
                    model.estimatedCost += cost
                }
                models[key] = model
            }
        }

        let sortedModels = models.values.sorted { $0.id < $1.id }
        let estimatedCost = sawModelBreakdown
            ? sortedModels.reduce(0) { $0 + $1.estimatedCost }
            : fallbackCost
        let totalTokens = explicitTotalTokens ?? max(
            fallbackTotalTokens,
            sortedModels.reduce(0) { saturatingAdd($0, $1.tokens.totalTokens) }
        )
        let unknownModels = sortedModels
            .filter { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }
            .map(\.name)

        let realtimeAnchorTodayCost: Double?
        if response.hasDailySection,
           let realtimeAnchorDay,
           MonthlyBudgetSnapshot.isValidDay(realtimeAnchorDay),
           realtimeAnchorDay.hasPrefix(month + "-"),
           response.daily.contains(where: { $0.period == realtimeAnchorDay }) {
            // An empty daily array is not evidence that today's usage is zero:
            // the section may be partial or omitted by an older ccusage build.
            // Require an explicit row before enabling the projection path.
            let dailyCost = dailyCost(for: realtimeAnchorDay, in: response.daily)
            realtimeAnchorTodayCost = dailyCost <= estimatedCost ? dailyCost : nil
        } else {
            realtimeAnchorTodayCost = nil
        }
        let validRealtimeAnchorDay = realtimeAnchorTodayCost == nil ? nil : realtimeAnchorDay

        return MonthlyBudgetSnapshot(
            month: month,
            generatedAt: Date(),
            pricingUpdatedAt: pricingUpdatedAt,
            customPricingRevision: customPricingRevision,
            models: sortedModels,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: Array(Set(unknownModels)).sorted(),
            realtimeAnchorDay: validRealtimeAnchorDay,
            realtimeAnchorTodayCost: realtimeAnchorTodayCost
        )
    }

    private static func dailyCost(for period: String, in rows: [CCUsageDailyRow]) -> Double {
        let matchingRows = rows.filter { $0.period == period }
        guard !matchingRows.isEmpty else { return 0 }

        let rowsToAggregate: [CCUsageDailyRow]
        if let aggregate = matchingRows.first(where: { $0.agent == "all" }) {
            rowsToAggregate = [aggregate]
        } else {
            rowsToAggregate = matchingRows
        }

        return rowsToAggregate.reduce(0) { partial, row in
            let rowModels: [CCUsageModelRow]
            if let agents = row.agents, !agents.isEmpty {
                rowModels = agents.flatMap { $0.modelBreakdowns ?? [] }
            } else {
                rowModels = row.modelBreakdowns ?? []
            }
            let knownRowCost = rowModels.compactMap(knownCost).reduce(0, +)
            let cost = rowModels.isEmpty ? max(0, row.totalCost ?? 0) : knownRowCost
            return partial + cost
        }
    }

    private static func knownCost(_ row: CCUsageModelRow) -> Double? {
        guard let cost = row.cost, cost > 0 else { return nil }
        return cost
    }

    private static func tokenTotal(for row: CCUsageAgentRow) -> Int64 {
        if let totalTokens = row.totalTokens, totalTokens >= 0 {
            return totalTokens
        }
        return TokenTotals(
            inputTokens: row.inputTokens ?? 0,
            outputTokens: row.outputTokens ?? 0,
            cacheCreationTokens: row.cacheCreationTokens ?? 0,
            cacheReadTokens: row.cacheReadTokens ?? 0
        ).totalTokens
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
