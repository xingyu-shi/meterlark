import Foundation

/// The single pricing record a presentation or resolver lookup needs after
/// custom and remote catalogs have been composed. Keeping the source/provider
/// metadata beside the canonical schedule prevents callers from rebuilding
/// precedence and provider-ambiguity rules independently.
struct PricingCatalogMatch: Equatable, Sendable {
    let schedule: CanonicalModelPricing
    let source: ModelPricingSource
    let providerIDs: [String]
    /// The identity used by the adapter/preparation maps. This may be a weak
    /// route alias, so it must not be reconstructed from the display name by a
    /// caller handling a wrapped usage model.
    let modelKey: String

    init(
        schedule: CanonicalModelPricing,
        source: ModelPricingSource,
        providerIDs: [String] = [],
        modelKey: String? = nil
    ) {
        self.schedule = schedule
        self.source = source
        self.providerIDs = PricingProviderIdentity.normalized(providerIDs)
        self.modelKey = modelKey ?? PricingModelIdentity.matchingKey(schedule.modelName)
    }
}

enum PricingCatalogLookupKind: String, Equatable, Sendable {
    case custom
    case remote
    case remoteMissing
    case remoteDisabled
    case remoteAmbiguous
    case remoteIncomplete
    case noSource
}

/// A complete per-model lookup result. `remoteMissing` and
/// `remoteDisabled` are safe to fall back to ccusage; ambiguity and
/// incompleteness are not. Keeping that distinction here makes the resolver,
/// annotation, status badge, and tests use the same decision.
struct PricingCatalogLookup: Equatable, Sendable {
    let kind: PricingCatalogLookupKind
    let modelKey: String?
    let match: PricingCatalogMatch?
    let providerIDs: [String]
    let missingRateComponents: [PricingRateComponent]
    let candidateModelNames: [String]

    var isKnownMatch: Bool { match != nil }

    var isCatalogGap: Bool {
        kind == .remoteAmbiguous || kind == .remoteIncomplete
    }
}

/// The immutable source inputs captured for one pricing execution.
///
/// A refresh must use one composition from start to finish. Keeping the
/// revisions, source entries, and composed catalog together prevents the
/// adapter, resolver, and presentation layer from independently rebuilding a
/// slightly different pricing view while a catalog or custom table is being
/// replaced.
struct PricingExecutionBasis: Equatable, Sendable {
    let customTable: CustomPricingTable
    let remoteCatalogEntries: [ModelCatalogEntry]
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    let composition: PricingCatalogComposition

    init(
        customTable: CustomPricingTable,
        remoteCatalogEntries: [ModelCatalogEntry] = [],
        modelCatalogRevision: String? = nil
    ) {
        self.customTable = customTable
        self.remoteCatalogEntries = remoteCatalogEntries.filter { $0.source == .remote }
        self.customPricingRevision = customTable.revision
        self.modelCatalogRevision = modelCatalogRevision
        self.composition = PricingCatalogComposition.make(
            customTable: customTable,
            remoteEntries: self.remoteCatalogEntries
        )
    }

    init(
        customTable: CustomPricingTable,
        remoteCatalogEntries: [ModelCatalogEntry],
        modelCatalogRevision: String?,
        composition: PricingCatalogComposition
    ) {
        self.customTable = customTable
        self.remoteCatalogEntries = remoteCatalogEntries.filter { $0.source == .remote }
        self.customPricingRevision = customTable.revision
        self.modelCatalogRevision = modelCatalogRevision
        self.composition = composition
    }

    func matches(
        customPricingRevision: String?,
        modelCatalogRevision: String?
    ) -> Bool {
        self.customPricingRevision == customPricingRevision
            && self.modelCatalogRevision == modelCatalogRevision
    }
}

/// The catalog used by one ccusage execution.
///
/// Custom entries win over remote entries for the same strong identity.
/// Remote model names are strong identities. Route/key/base-model/version
/// values are weak aliases and are evaluated independently; they never form a
/// transitive union. This is what prevents an unrelated `version` collision
/// from making an exact model name ambiguous.
struct PricingCatalogComposition: Equatable, Sendable {
    let catalog: CanonicalPricingCatalog
    let sourceByModelKey: [String: ModelPricingSource]
    let providerIDsByModelKey: [String: [String]]
    /// Maps a projected/backend model key back to the catalog's canonical
    /// model identity. A provider-qualified route can be a valid weak alias
    /// for pricing lookup, but it must reuse the canonical capability profile
    /// (for example the 272k profile of `gpt-5.6-sol`).
    let canonicalModelNameByModelKey: [String: String]
    /// Kept for compatibility with diagnostics and older callers. Resolver
    /// decisions now come from `lookup(for:)`, which also distinguishes
    /// disabled and incomplete records.
    let ambiguousRemoteModelKeys: Set<String>

    private let customMatchesByKey: [String: PricingCatalogMatch]
    private let strongRemoteCandidatesByKey: [String: [ModelCatalogEntry]]
    private let weakRemoteCandidatesByKey: [String: [ModelCatalogEntry]]
    private let remoteLookupByKey: [String: PricingCatalogLookup]
    private let hasRemoteRecords: Bool

    var hasRemoteCatalog: Bool { hasRemoteRecords }

    static func make(
        customTable: CustomPricingTable,
        remoteEntries: [ModelCatalogEntry]
    ) -> PricingCatalogComposition {
        make(
            customCatalog: customTable.canonicalPricingCatalog,
            remoteEntries: remoteEntries
        )
    }

    static func make(
        customCatalog: CanonicalPricingCatalog,
        remoteEntries: [ModelCatalogEntry]
    ) -> PricingCatalogComposition {
        let projectedRemoteEntries = ModelCatalogEntry.deduplicated(remoteEntries)
            .filter { $0.source == .remote }
            .sorted(by: entryOrder)

        var customMatches: [String: PricingCatalogMatch] = [:]
        var modelsByKey: [String: CanonicalModelPricing] = [:]
        var sourceByKey: [String: ModelPricingSource] = [:]
        var providerIDsByKey: [String: [String]] = [:]
        var canonicalModelNameByKey: [String: String] = [:]

        for model in customCatalog.models {
            let key = PricingModelIdentity.matchingKey(model.modelName)
            guard !key.isEmpty else { continue }
            let match = PricingCatalogMatch(
                schedule: model,
                source: .custom,
                modelKey: key
            )
            customMatches[key] = match
            modelsByKey[key] = model
            sourceByKey[key] = .custom
            canonicalModelNameByKey[key] = model.modelName
        }

        var strongCandidates: [String: [ModelCatalogEntry]] = [:]
        var weakCandidates: [String: [ModelCatalogEntry]] = [:]
        var strongFingerprints: [String: Set<String>] = [:]
        var weakFingerprints: [String: Set<String>] = [:]
        for entry in projectedRemoteEntries {
            let fingerprint = entry.semanticRecordFingerprint
            let strongKeys = PricingModelIdentity.strongKeys(for: entry.modelName)
            for key in strongKeys {
                append(
                    entry,
                    fingerprint: fingerprint,
                    to: &strongCandidates[key, default: []],
                    fingerprints: &strongFingerprints[key, default: []]
                )
            }
            for key in weakAliasKeys(for: entry) {
                // A value that is also the entry's strong display identity is
                // not a weak edge. This matters for provider-specific names:
                // `gpt-5.6-sol-openai` must not be merged through its base
                // model merely because another record mentions that base.
                guard !strongKeys.contains(key) else { continue }
                append(
                    entry,
                    fingerprint: fingerprint,
                    to: &weakCandidates[key, default: []],
                    fingerprints: &weakFingerprints[key, default: []]
                )
            }
        }

        // Candidate arrays are immutable after composition. Sorting once here
        // avoids the old append-time sort and the repeated sort performed by
        // every lookup/evaluation.
        for key in strongCandidates.keys {
            strongCandidates[key]?.sort(by: entryOrder)
        }
        for key in weakCandidates.keys {
            weakCandidates[key]?.sort(by: entryOrder)
        }

        let allKeys = Set(strongCandidates.keys).union(weakCandidates.keys)
        var lookupByKey: [String: PricingCatalogLookup] = [:]
        for key in allKeys.sorted() {
            let primaryCandidates = candidates(
                for: key,
                strongCandidates: strongCandidates,
                weakCandidates: weakCandidates
            )
            lookupByKey[key] = evaluateRemote(
                key: key,
                candidates: primaryCandidates,
                equivalentWeakCandidates: equivalentWeakCandidates(
                    for: key,
                    primaryCandidates: primaryCandidates,
                    strongCandidates: strongCandidates,
                    weakCandidates: weakCandidates
                )
            )
        }

        // Only a safe remote lookup becomes an adapter model. In particular,
        // ambiguous/incomplete records are omitted from generated config so
        // ccusage cannot accidentally turn a diagnostic state into a price.
        for key in lookupByKey.keys.sorted() {
            guard customMatches[key] == nil,
                  let lookup = lookupByKey[key],
                  lookup.kind == .remote,
                  let match = lookup.match else {
                continue
            }
            let displayName = displayName(
                for: key,
                match: match,
                candidates: candidates(
                    for: key,
                    strongCandidates: strongCandidates,
                    weakCandidates: weakCandidates
                )
            )
            let schedule = model(named: displayName, from: match.schedule)
            modelsByKey[key] = schedule
            sourceByKey[key] = .remote
            providerIDsByKey[key] = match.providerIDs
            canonicalModelNameByKey[key] = match.schedule.modelName
        }

        let ambiguousKeys = Set(lookupByKey.compactMap { key, lookup in
            lookup.isCatalogGap ? key : nil
        })
        let models = modelsByKey.values.sorted {
            let lhs = $0.modelName.lowercased()
            let rhs = $1.modelName.lowercased()
            if lhs == rhs { return $0.modelName < $1.modelName }
            return lhs < rhs
        }

        return PricingCatalogComposition(
            catalog: CanonicalPricingCatalog(models: models),
            sourceByModelKey: sourceByKey,
            providerIDsByModelKey: providerIDsByKey,
            canonicalModelNameByModelKey: canonicalModelNameByKey,
            ambiguousRemoteModelKeys: ambiguousKeys,
            customMatchesByKey: customMatches,
            strongRemoteCandidatesByKey: strongCandidates,
            weakRemoteCandidatesByKey: weakCandidates,
            remoteLookupByKey: lookupByKey,
            hasRemoteRecords: !projectedRemoteEntries.isEmpty
        )
    }

    func lookup(for modelName: String) -> PricingCatalogLookup {
        let strongKeys = PricingModelIdentity.strongKeys(for: modelName)

        // Custom precedence is evaluated before remote ambiguity. A local
        // override remains an explicit user decision even if the remote
        // catalog has two conflicting records for the same name.
        for key in strongKeys {
            if let match = customMatchesByKey[key] {
                return PricingCatalogLookup(
                    kind: .custom,
                    modelKey: key,
                    match: match,
                    providerIDs: [],
                    missingRateComponents: match.schedule.missingRequiredBaseRateComponents,
                    candidateModelNames: [match.schedule.modelName]
                )
            }
        }

        for key in strongKeys {
            if strongRemoteCandidatesByKey[key] != nil,
               let lookup = remoteLookupByKey[key] {
                return lookup
            }
        }

        let weakKeys = strongKeys.compactMap(PricingModelIdentity.weakAliasKey(for:))
        for key in weakKeys {
            guard strongRemoteCandidatesByKey[key] == nil,
                  weakRemoteCandidatesByKey[key] != nil,
                  let lookup = remoteLookupByKey[key] else {
                continue
            }
            return lookup
        }

        return PricingCatalogLookup(
            kind: hasRemoteRecords ? .remoteMissing : .noSource,
            modelKey: nil,
            match: nil,
            providerIDs: [],
            missingRateComponents: [],
            candidateModelNames: []
        )
    }

    func model(for modelName: String) -> CanonicalModelPricing? {
        lookup(for: modelName).match?.schedule
    }

    func match(for modelName: String) -> PricingCatalogMatch? {
        lookup(for: modelName).match
    }

    /// Returns the canonical source identity for a projected model name. This
    /// is intentionally resolved through the same lookup graph as pricing so
    /// adapters do not invent their own provider-prefix stripping rules.
    func canonicalModelName(forProjectedModelName modelName: String) -> String? {
        let lookup = lookup(for: modelName)
        guard let key = lookup.modelKey else { return nil }
        return canonicalModelNameByModelKey[key]
    }

    static func remoteEntryMatches(_ entry: ModelCatalogEntry, modelName: String) -> Bool {
        let requestedStrong = Set(PricingModelIdentity.strongKeys(for: modelName))
        let entryStrong = Set(PricingModelIdentity.strongKeys(for: entry.modelName))
        if !requestedStrong.isDisjoint(with: entryStrong) {
            return true
        }
        let requestedWeak = Set(requestedStrong.compactMap(PricingModelIdentity.weakAliasKey(for:)))
        return !requestedWeak.isDisjoint(with: Set(weakAliasKeys(for: entry)))
    }

    private init(
        catalog: CanonicalPricingCatalog,
        sourceByModelKey: [String: ModelPricingSource],
        providerIDsByModelKey: [String: [String]],
        canonicalModelNameByModelKey: [String: String],
        ambiguousRemoteModelKeys: Set<String>,
        customMatchesByKey: [String: PricingCatalogMatch],
        strongRemoteCandidatesByKey: [String: [ModelCatalogEntry]],
        weakRemoteCandidatesByKey: [String: [ModelCatalogEntry]],
        remoteLookupByKey: [String: PricingCatalogLookup],
        hasRemoteRecords: Bool
    ) {
        self.catalog = catalog
        self.sourceByModelKey = sourceByModelKey
        self.providerIDsByModelKey = providerIDsByModelKey
        self.canonicalModelNameByModelKey = canonicalModelNameByModelKey
        self.ambiguousRemoteModelKeys = ambiguousRemoteModelKeys
        self.customMatchesByKey = customMatchesByKey
        self.strongRemoteCandidatesByKey = strongRemoteCandidatesByKey
        self.weakRemoteCandidatesByKey = weakRemoteCandidatesByKey
        self.remoteLookupByKey = remoteLookupByKey
        self.hasRemoteRecords = hasRemoteRecords
    }

    private static func evaluateRemote(
        key: String,
        candidates: [ModelCatalogEntry],
        equivalentWeakCandidates: [ModelCatalogEntry] = []
    ) -> PricingCatalogLookup {
        let candidateNames = Array(Set(candidates.map(\.modelName))).sorted {
            let lhs = $0.lowercased()
            let rhs = $1.lowercased()
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        let enabled = candidates.filter { $0.enabled != false }
        guard !enabled.isEmpty else {
            return PricingCatalogLookup(
                kind: .remoteDisabled,
                modelKey: key,
                match: nil,
                providerIDs: PricingProviderIdentity.normalized(enabledProviderIDs(from: candidates)),
                missingRateComponents: [],
                candidateModelNames: candidateNames
            )
        }

        let providerIDs = PricingProviderIdentity.normalized(enabledProviderIDs(from: enabled))

        let schedules = enabled.compactMap(\.pricingSchedule)
        let missingBaseRates = schedules.flatMap(\.missingRequiredBaseRateComponents)
        guard schedules.count == enabled.count else {
            return PricingCatalogLookup(
                kind: .remoteIncomplete,
                modelKey: key,
                match: nil,
                providerIDs: providerIDs,
                missingRateComponents: missingBaseRates.isEmpty
                    ? [.input, .output]
                    : Array(Set(missingBaseRates)).sorted { $0.rawValue < $1.rawValue },
                candidateModelNames: candidateNames
            )
        }
        guard missingBaseRates.isEmpty else {
            return PricingCatalogLookup(
                kind: .remoteIncomplete,
                modelKey: key,
                match: nil,
                providerIDs: providerIDs,
                missingRateComponents: Array(Set(missingBaseRates)).sorted { $0.rawValue < $1.rawValue },
                candidateModelNames: candidateNames
            )
        }

        guard let first = schedules.first,
              schedules.dropFirst().allSatisfy({ PricingScheduleEquivalence.areEquivalent(first, $0) }) else {
            return PricingCatalogLookup(
                kind: .remoteAmbiguous,
                modelKey: key,
                match: nil,
                providerIDs: providerIDs,
                missingRateComponents: [],
                candidateModelNames: candidateNames
            )
        }

        let equivalentWeakProviderIDs = equivalentWeakCandidates.compactMap { entry -> String? in
            guard entry.enabled != false,
                  let schedule = entry.pricingSchedule,
                  schedule.missingRequiredBaseRateComponents.isEmpty,
                  PricingScheduleEquivalence.areEquivalent(first, schedule) else {
                return nil
            }
            return entry.providerID
        }
        let allProviderIDs = PricingProviderIdentity.normalized(
            providerIDs + equivalentWeakProviderIDs
        )

        return PricingCatalogLookup(
            kind: .remote,
            modelKey: key,
            match: PricingCatalogMatch(
                schedule: first,
                source: .remote,
                providerIDs: allProviderIDs,
                modelKey: key
            ),
            providerIDs: allProviderIDs,
            missingRateComponents: [],
            candidateModelNames: candidateNames
        )
    }

    private static func equivalentWeakCandidates(
        for key: String,
        primaryCandidates: [ModelCatalogEntry],
        strongCandidates: [String: [ModelCatalogEntry]],
        weakCandidates: [String: [ModelCatalogEntry]]
    ) -> [ModelCatalogEntry] {
        // Strong model names own pricing selection. A weak route/provider
        // alias may contribute provenance only when it describes the same
        // schedule; a different weak price must not make an exact model
        // ambiguous or silently change its billing identity.
        guard strongCandidates[key]?.isEmpty == false,
              let weak = weakCandidates[key],
              let first = primaryCandidates.first?.pricingSchedule else {
            return []
        }
        return weak.filter { entry in
            guard entry.enabled != false,
                  let schedule = entry.pricingSchedule,
                  schedule.missingRequiredBaseRateComponents.isEmpty else {
                return false
            }
            return PricingScheduleEquivalence.areEquivalent(first, schedule)
        }
    }

    private static func append(
        _ entry: ModelCatalogEntry,
        fingerprint: String,
        to entries: inout [ModelCatalogEntry],
        fingerprints: inout Set<String>
    ) {
        // A provider record ID is transport identity, not pricing identity.
        // Conversely, keeping only the ID would hide a same-ID price conflict
        // and turn an unsafe catalog into a seemingly deterministic one.
        guard fingerprints.insert(fingerprint).inserted else { return }
        entries.append(entry)
    }

    private static func enabledProviderIDs(from entries: [ModelCatalogEntry]) -> [String] {
        entries
            .filter { $0.enabled != false }
            .compactMap(\.providerID)
    }

    private static func entryOrder(_ lhs: ModelCatalogEntry, _ rhs: ModelCatalogEntry) -> Bool {
        let lhsName = lhs.modelName.lowercased()
        let rhsName = rhs.modelName.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return (lhs.providerID ?? "") < (rhs.providerID ?? "")
    }

    private static func candidates(
        for key: String,
        strongCandidates: [String: [ModelCatalogEntry]],
        weakCandidates: [String: [ModelCatalogEntry]]
    ) -> [ModelCatalogEntry] {
        // An exact model identity is authoritative for that lookup. Weak
        // metadata from another record must not turn an otherwise safe exact
        // match into an ambiguous one (for example, gpt-5.6-sol-openai must
        // not inherit the base-model candidates of gpt-5.6-sol).
        if let strong = strongCandidates[key], !strong.isEmpty {
            return strong
        }
        return weakCandidates[key] ?? []
    }

    private static func displayName(
        for key: String,
        match: PricingCatalogMatch,
        candidates: [ModelCatalogEntry]
    ) -> String {
        for entry in candidates {
            let values = [
                entry.modelName,
                entry.route,
                routeFinalSegment(entry.route),
                entry.key,
                entry.baseModel,
                entry.version,
                entry.provider.map { "\($0).\(entry.modelName)" },
                entry.provider.map { "\($0)/\(entry.modelName)" }
            ].compactMap { $0 }
            if let value = values.first(where: { PricingModelIdentity.weakAliasKey(for: $0) == key }) {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return match.schedule.modelName
    }

    private static func model(named name: String, from model: CanonicalModelPricing) -> CanonicalModelPricing {
        guard model.modelName != name else { return model }
        return CanonicalModelPricing(
            modelName: name,
            base: model.base,
            tiers: model.tiers,
            maxInputTokens: model.maxInputTokens,
            fastMultiplier: model.fastMultiplier
        )
    }

    private static func weakAliasKeys(for entry: ModelCatalogEntry) -> Set<String> {
        var values = [
            entry.route,
            routeFinalSegment(entry.route),
            entry.key,
            entry.baseModel,
            entry.version
        ].compactMap { $0 }

        // A provider-qualified alias is a weak, metadata-derived edge. It
        // lets a gateway report `openai.gpt-x` without making `gpt-x` and
        // `openai.gpt-x` the same strong billing identity globally.
        if let provider = entry.provider {
            values.append(entry.modelName)
            values.append("\(provider).\(entry.modelName)")
            values.append("\(provider)/\(entry.modelName)")
        }

        return values
            .compactMap(PricingModelIdentity.weakAliasKey(for:))
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private static func routeFinalSegment(_ route: String?) -> String? {
        guard let route else { return nil }
        return route
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)
    }
}
