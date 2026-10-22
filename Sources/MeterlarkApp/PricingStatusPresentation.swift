import Foundation

enum PricingStatusKind: String, Equatable, Sendable {
    case stale
    case approximate
    case unknown
    case mixed
}

enum PricingStatusReason: Equatable, Sendable {
    case customRatesIncomplete
    case catalogEntryMissing
    case catalogEntryDisabled
    case catalogEntriesAmbiguous
    case catalogRatesIncomplete
    case noPriceSource
}

enum PricingStatusRateComponent: String, CaseIterable, Equatable, Sendable {
    case input
    case output
    case cacheCreation
    case cacheRead
}

struct PricingStatusModel: Equatable, Identifiable, Sendable {
    let agent: String
    let name: String
    let source: ModelPricingSource
    let pricingProviderIDs: [String]
    let hasKnownPricing: Bool
    let pricingTierThreshold: Int64?
    let pricingBackendThreshold: Int64?
    let reason: PricingStatusReason?
    let missingRateComponents: [PricingStatusRateComponent]

    var id: String { "\(agent)::\(name)" }
}

struct PricingStatusPresentation: Equatable, Sendable {
    let kind: PricingStatusKind
    let models: [PricingStatusModel]
    let includesMixedSources: Bool

    static func make(
        snapshot: UsageSnapshot,
        unknownPricingModels: [String] = [],
        pricingIsStale: Bool = false,
        modelCatalogEntries: [ModelCatalogEntry] = [],
        pricingComposition: PricingCatalogComposition? = nil
    ) -> PricingStatusPresentation? {
        let usedModels = snapshot.models.filter { $0.tokens.totalTokens > 0 }
        let composition = pricingComposition ?? PricingCatalogComposition.make(
            customTable: .empty,
            remoteEntries: modelCatalogEntries
        )
        let hasRemoteCatalog = composition.hasRemoteCatalog
        let approximateModels = usedModels.filter { $0.pricingSource == .approximate }
        let unknownModels = usedModels.filter { !$0.hasKnownPricing }
        let usedModelNames = Set(usedModels.map { PricingModelIdentity.matchingKey($0.name) })
        let externalUnknownModels: [String] = Array(Set(unknownPricingModels.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !usedModelNames.contains(PricingModelIdentity.matchingKey(trimmed)) else {
                return nil
            }
            return trimmed
        })).sorted()
        let unknownStatusModels = unknownModels.map { model in
            let diagnosis = reason(for: model, composition: composition)
            return PricingStatusModel(
                agent: model.agent,
                name: model.name,
                source: model.pricingSource,
                pricingProviderIDs: model.pricingProviderIDs,
                hasKnownPricing: model.hasKnownPricing,
                pricingTierThreshold: model.pricingTierThreshold,
                pricingBackendThreshold: model.pricingBackendThreshold,
                reason: diagnosis.reason,
                missingRateComponents: diagnosis.missingRateComponents
            )
        } + externalUnknownModels.map {
            // A monthly-only unknown model has no current daily agent row. An
            // empty agent keeps the detail card honest instead of inventing a
            // provider name just to fill the second line.
            PricingStatusModel(
                agent: "",
                name: $0,
                source: .unknown,
                pricingProviderIDs: [],
                hasKnownPricing: false,
                pricingTierThreshold: nil,
                pricingBackendThreshold: nil,
                reason: hasRemoteCatalog ? .catalogEntryMissing : .noPriceSource,
                missingRateComponents: []
            )
        }
        let hasUnknown = !unknownStatusModels.isEmpty

        let kind: PricingStatusKind
        // Unknown pricing is a correctness problem, not merely a freshness
        // hint: those tokens are absent from the total and can understate a
        // budget. Keep it visible even while the catalog is also stale.
        if hasUnknown {
            kind = .unknown
        } else if pricingIsStale {
            kind = .stale
        } else if snapshot.pricingSource == .approximate || !approximateModels.isEmpty {
            kind = .approximate
        } else if snapshot.pricingSource == .mixed {
            kind = .mixed
        } else {
            return nil
        }

        let detailModels: [PricingStatusModel]
        switch kind {
        case .stale:
            // Stale means the active pricing basis may no longer match the
            // displayed estimate. Known old prices are still affected, so
            // showing only unknown rows would leave the detail popover empty
            // for the most common catalog/revision change.
            detailModels = usedModels.map {
                PricingStatusModel(
                    agent: $0.agent,
                    name: $0.name,
                    source: $0.pricingSource,
                    pricingProviderIDs: $0.pricingProviderIDs,
                    hasKnownPricing: $0.hasKnownPricing,
                    pricingTierThreshold: $0.pricingTierThreshold,
                    pricingBackendThreshold: $0.pricingBackendThreshold,
                    reason: nil,
                    missingRateComponents: []
                )
            } + unknownStatusModels.filter { unknown in
                !usedModels.contains { used in
                    PricingModelIdentity.matchingKey(used.name)
                        == PricingModelIdentity.matchingKey(unknown.name)
                }
            }
        case .approximate:
            detailModels = approximateModels.map {
                PricingStatusModel(
                    agent: $0.agent,
                    name: $0.name,
                    source: $0.pricingSource,
                    pricingProviderIDs: $0.pricingProviderIDs,
                    hasKnownPricing: $0.hasKnownPricing,
                    pricingTierThreshold: $0.pricingTierThreshold,
                    pricingBackendThreshold: $0.pricingBackendThreshold,
                    reason: nil,
                    missingRateComponents: []
                )
            }
        case .unknown:
            // Include approximate rows as well. The unknown badge is the
            // highest-severity state, but users still need to know which
            // other models are estimates rather than exact prices.
            let approximateDetails = approximateModels.map {
                PricingStatusModel(
                    agent: $0.agent,
                    name: $0.name,
                    source: $0.pricingSource,
                    pricingProviderIDs: $0.pricingProviderIDs,
                    hasKnownPricing: $0.hasKnownPricing,
                    pricingTierThreshold: $0.pricingTierThreshold,
                    pricingBackendThreshold: $0.pricingBackendThreshold,
                    reason: nil,
                    missingRateComponents: []
                )
            }
            detailModels = unknownStatusModels + approximateDetails
        case .mixed:
            detailModels = usedModels.map {
                PricingStatusModel(
                    agent: $0.agent,
                    name: $0.name,
                    source: $0.pricingSource,
                    pricingProviderIDs: $0.pricingProviderIDs,
                    hasKnownPricing: $0.hasKnownPricing,
                    pricingTierThreshold: $0.pricingTierThreshold,
                    pricingBackendThreshold: $0.pricingBackendThreshold,
                    reason: nil,
                    missingRateComponents: []
                )
            }
        }

        let models = detailModels
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.agent.localizedCaseInsensitiveCompare($1.agent) == .orderedAscending
            }

        let sources = Set(usedModels.map { $0.pricingSource.rawValue })
        return PricingStatusPresentation(
            kind: kind,
            models: models,
            includesMixedSources: snapshot.pricingSource == .mixed || sources.count > 1
        )
    }

    private static func reason(
        for model: ModelUsage,
        composition: PricingCatalogComposition
    ) -> (reason: PricingStatusReason?, missingRateComponents: [PricingStatusRateComponent]) {
        guard !model.hasKnownPricing else { return (nil, []) }
        let lookup = composition.lookup(for: model.name)
        switch lookup.kind {
        case .custom:
            return (.customRatesIncomplete, [])
        case .remoteMissing, .noSource:
            return (lookup.kind == .remoteMissing ? .catalogEntryMissing : .noPriceSource, [])
        case .remoteDisabled:
            return (.catalogEntryDisabled, [])
        case .remoteAmbiguous:
            return (.catalogEntriesAmbiguous, [])
        case .remoteIncomplete:
            return (
                .catalogRatesIncomplete,
                lookup.missingRateComponents.compactMap {
                    PricingStatusRateComponent(rawValue: $0.rawValue)
                }
            )
        case .remote:
            // A complete catalog with an unusable backend zero is not a
            // catalog-shape error. The resolver intentionally leaves it
            // unknown, but the status card should not claim that the rates
            // themselves are incomplete.
            return (nil, [])
        }
    }
}
