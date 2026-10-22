import Foundation

/// The reason a model row is known or unknown for one refresh. This is kept
/// in memory only: persisted snapshots already carry the resulting boolean
/// and source, while the reason is needed only to decide whether a candidate
/// may replace the trusted snapshot.
enum PricingAssessmentOutcome: String, Equatable, Hashable, Sendable {
    case knownFree
    case knownPaid
    case intentionalUnknown
    case unpricedZero
    case unsupportedCustomZero
}

enum PricingCatalogGapReason: String, Equatable, Hashable, Sendable {
    case ambiguous
    case incomplete
}

struct PricingAssessmentContext: Equatable, Sendable {
    private(set) var outcomesByModel: [String: Set<PricingAssessmentOutcome>]
    private(set) var catalogGapReasonsByModel: [String: Set<PricingCatalogGapReason>]

    static let empty = PricingAssessmentContext(
        outcomesByModel: [:],
        catalogGapReasonsByModel: [:]
    )

    init(
        outcomesByModel: [String: Set<PricingAssessmentOutcome>] = [:],
        catalogGapReasonsByModel: [String: Set<PricingCatalogGapReason>] = [:]
    ) {
        self.outcomesByModel = outcomesByModel
        self.catalogGapReasonsByModel = catalogGapReasonsByModel
    }

    mutating func record(
        modelName: String,
        outcome: PricingAssessmentOutcome,
        catalogGap: PricingCatalogGapReason? = nil
    ) {
        let key = PricingModelIdentity.matchingKey(modelName)
        outcomesByModel[key, default: []].insert(outcome)
        if let catalogGap {
            catalogGapReasonsByModel[key, default: []].insert(catalogGap)
        }
    }

    func outcomes(for modelName: String) -> Set<PricingAssessmentOutcome> {
        outcomesByModel[PricingModelIdentity.matchingKey(modelName)] ?? []
    }

    func catalogGapReasons(for modelName: String) -> Set<PricingCatalogGapReason> {
        catalogGapReasonsByModel[PricingModelIdentity.matchingKey(modelName)] ?? []
    }

    var catalogGapModelKeys: Set<String> {
        Set(catalogGapReasonsByModel.keys)
    }

    var hasCatalogGap: Bool {
        !catalogGapReasonsByModel.isEmpty
    }

    var hasUnsafeZero: Bool {
        outcomesByModel.values.contains { outcomes in
            outcomes.contains(.unpricedZero) || outcomes.contains(.unsupportedCustomZero)
        }
    }
}

/// The immutable pricing inputs captured by one usage/monthly refresh. The
/// generated-config preparation is intentionally paired with the table so a
/// worker cannot resolve a row with facts from a different generation.
struct PricingResolutionContext: Equatable, Sendable {
    let basis: PricingExecutionBasis
    let preparation: CcusagePricingPreparation

    var table: CustomPricingTable { basis.customTable }
    var remoteCatalogEntries: [ModelCatalogEntry] { basis.remoteCatalogEntries }
    var remoteCatalogRevision: String? { basis.modelCatalogRevision }
    var effectiveCatalog: PricingCatalogComposition { basis.composition }

    static let empty = PricingResolutionContext(
        table: .empty,
        preparation: .empty,
        remoteCatalogEntries: [],
        remoteCatalogRevision: nil
    )

    init(
        table: CustomPricingTable,
        preparation: CcusagePricingPreparation? = nil,
        remoteCatalogEntries: [ModelCatalogEntry] = [],
        remoteCatalogRevision: String? = nil
    ) {
        self.init(
            basis: PricingExecutionBasis(
                customTable: table,
                remoteCatalogEntries: remoteCatalogEntries,
                modelCatalogRevision: remoteCatalogRevision
            ),
            preparation: preparation
        )
    }

    init(
        basis: PricingExecutionBasis,
        preparation: CcusagePricingPreparation? = nil
    ) {
        self.basis = basis
        self.preparation = preparation
            ?? CcusagePricingAdapter.bundledV20.preparation(for: basis.composition)
    }
}

struct ResolvedPricing: Equatable, Sendable {
    let cost: Double
    let hasKnownPricing: Bool
    let source: ModelPricingSource
    let pricingProviderIDs: [String]
    let outcome: PricingAssessmentOutcome
    let catalogGap: PricingCatalogGapReason?
    let tierThreshold: Int64?
    let backendThreshold: Int64?

    init(
        cost: Double,
        hasKnownPricing: Bool,
        source: ModelPricingSource,
        pricingProviderIDs: [String] = [],
        outcome: PricingAssessmentOutcome,
        catalogGap: PricingCatalogGapReason? = nil,
        tierThreshold: Int64?,
        backendThreshold: Int64?
    ) {
        self.cost = cost
        self.hasKnownPricing = hasKnownPricing
        self.source = source
        self.pricingProviderIDs = PricingProviderIdentity.normalized(pricingProviderIDs)
        self.outcome = outcome
        self.catalogGap = catalogGap
        self.tierThreshold = tierThreshold
        self.backendThreshold = backendThreshold
    }
}

struct UsageSnapshotBuildResult: Equatable, Sendable {
    let snapshot: UsageSnapshot
    let pricingAssessment: PricingAssessmentContext
}

struct MonthlyBudgetBuildResult: Equatable, Sendable {
    let snapshot: MonthlyBudgetSnapshot
    let pricingAssessment: PricingAssessmentContext
}

/// Resolves a raw ccusage model row without using aggregate cost as a proxy
/// for provenance. In particular, a custom zero is known-free, while a zero
/// or unusable cost from an otherwise uncovered ccusage row is unpriced.
struct PricingResolver: Sendable {
    private let context: PricingResolutionContext

    init(context: PricingResolutionContext) {
        self.context = context
    }

    func resolve(
        modelName: String,
        tokens: TokenTotals,
        backendCost: Double?
    ) -> ResolvedPricing {
        let lookup = context.effectiveCatalog.lookup(for: modelName)
        switch lookup.kind {
        case .noSource, .remoteMissing, .remoteDisabled:
            return resolveCcusageCost(backendCost)
        case .remoteAmbiguous:
            return unresolvedRemotePricing(catalogGap: .ambiguous)
        case .remoteIncomplete:
            return unresolvedRemotePricing(catalogGap: .incomplete)
        case .remote:
            guard let match = lookup.match else {
                return unresolvedRemotePricing(catalogGap: .incomplete)
            }
            return resolveRemote(
                key: match.modelKey,
                model: match.schedule,
                providerIDs: match.providerIDs,
                tokens: tokens,
                backendCost: backendCost
            )
        case .custom:
            guard let match = lookup.match else {
                return ResolvedPricing(
                    cost: 0,
                    hasKnownPricing: false,
                    source: .unknown,
                    outcome: .intentionalUnknown,
                    tierThreshold: nil,
                    backendThreshold: nil
                )
            }
            return resolveCustom(
                key: match.modelKey,
                model: match.schedule,
                tokens: tokens,
                backendCost: backendCost
            )
        }
    }

    private func resolveCustom(
        key: String,
        model: CanonicalModelPricing,
        tokens: TokenTotals,
        backendCost: Double?
    ) -> ResolvedPricing {

        let selectedTier = selectedTier(for: key, in: model)
        let useTier = selectedTier != nil
            && (context.preparation.selectedBackendThresholds[key] ?? 0) < tokens.inputTokens
        let effectiveRates = useTier ? selectedTier?.rates ?? model.base : model.base
        let tierThreshold = selectedTier?.threshold
        let backendThreshold = context.preparation.selectedBackendThresholds[key]

        guard effectiveRates.hasCompleteRates(for: tokens) else {
            return ResolvedPricing(
                cost: 0,
                hasKnownPricing: false,
                source: .unknown,
                outcome: .intentionalUnknown,
                tierThreshold: nil,
                backendThreshold: nil
            )
        }

        let allUsedRatesAreZero = effectiveRates.isAllZero(for: tokens)
        if allUsedRatesAreZero {
            return ResolvedPricing(
                cost: 0,
                hasKnownPricing: true,
                source: customSource(for: key),
                outcome: .knownFree,
                tierThreshold: tierThreshold,
                backendThreshold: backendThreshold
            )
        }

        let containsUsedZero = effectiveRates.hasZeroRate(for: tokens)
        if useTier,
           containsUsedZero,
           !context.preparation.supportsExplicitZeroOverrides {
            return unresolvedCustomPricing(
                containsUsedZero: true,
                tierThreshold: tierThreshold,
                backendThreshold: backendThreshold
            )
        }
        if !useTier {
            // A no-tier row has an exact component calculation. It is also
            // the safe fallback when ccusage returns zero for a mixed base
            // schedule; no tier engine is being recreated here.
            if containsUsedZero, let exactCost = effectiveRates.cost(for: tokens) {
                return ResolvedPricing(
                    cost: exactCost,
                    hasKnownPricing: true,
                    source: customSource(for: key),
                    outcome: .knownPaid,
                    tierThreshold: tierThreshold,
                    backendThreshold: backendThreshold
                )
            }

            if let backendCost = usablePositiveCost(backendCost) {
                return ResolvedPricing(
                    cost: backendCost,
                    hasKnownPricing: true,
                    source: customSource(for: key),
                    outcome: .knownPaid,
                    tierThreshold: tierThreshold,
                    backendThreshold: backendThreshold
                )
            }

            if let exactCost = effectiveRates.cost(for: tokens), exactCost > 0 {
                return ResolvedPricing(
                    cost: exactCost,
                    hasKnownPricing: true,
                    source: customSource(for: key),
                    outcome: .knownPaid,
                    tierThreshold: tierThreshold,
                    backendThreshold: backendThreshold
                )
            }

            return unresolvedCustomPricing(
                containsUsedZero: containsUsedZero,
                tierThreshold: tierThreshold,
                backendThreshold: backendThreshold
            )
        }

        // Above the backend threshold, only the verified ccusage result can
        // account for its tier semantics. A zero result from a zero-bearing
        // tier cannot be reconstructed from the aggregate row, so fail
        // closed instead of guessing a tier cost.
        if let backendCost = usablePositiveCost(backendCost) {
            return ResolvedPricing(
                cost: backendCost,
                hasKnownPricing: true,
                source: customSource(for: key),
                outcome: .knownPaid,
                tierThreshold: tierThreshold,
                backendThreshold: backendThreshold
            )
        }

        return unresolvedCustomPricing(
            containsUsedZero: containsUsedZero,
            tierThreshold: tierThreshold,
            backendThreshold: backendThreshold
        )
    }

    private func resolveCcusageCost(_ backendCost: Double?) -> ResolvedPricing {
        guard let cost = usablePositiveCost(backendCost) else {
            return ResolvedPricing(
                cost: 0,
                hasKnownPricing: false,
                source: .unknown,
                outcome: .unpricedZero,
                tierThreshold: nil,
                backendThreshold: nil
            )
        }
        return ResolvedPricing(
            cost: cost,
            hasKnownPricing: true,
            source: .ccusage,
            outcome: .knownPaid,
            tierThreshold: nil,
            backendThreshold: nil
        )
    }

    private func resolveRemote(
        key: String,
        model: CanonicalModelPricing,
        providerIDs: [String],
        tokens: TokenTotals,
        backendCost: Double?
    ) -> ResolvedPricing {
        guard model.base.hasRequiredInputOutputRates else {
            return unresolvedRemotePricing(catalogGap: .incomplete)
        }

        let selectedTier = selectedTier(for: key, in: model)
        let backendThreshold = context.preparation.selectedBackendThresholds[key]

        // The canonical schedule, rather than a zero backend total alone,
        // proves that a completely free model is known-free. This is a
        // provenance decision, not a second tier calculation.
        if model.scheduleIsExplicitlyFree {
            return ResolvedPricing(
                cost: 0,
                hasKnownPricing: true,
                source: .remote,
                pricingProviderIDs: providerIDs,
                outcome: .knownFree,
                tierThreshold: selectedTier?.threshold,
                backendThreshold: backendThreshold
            )
        }

        // A positive backend result is authoritative. This is important even
        // for a flat schedule with a free cache component: recomputing it in
        // the app would silently create a second billing implementation and
        // can diverge from ccusage's rounding/attribution rules.
        if let cost = usablePositiveCost(backendCost) {
            return ResolvedPricing(
                cost: cost,
                hasKnownPricing: true,
                source: .remote,
                pricingProviderIDs: providerIDs,
                outcome: .knownPaid,
                tierThreshold: selectedTier?.threshold,
                backendThreshold: backendThreshold
            )
        }

        // A flat remote schedule can be resolved exactly when ccusage returns
        // zero. Component rates suffice without a tier boundary, and the
        // remote catalog decoder normalizes null cache rates to a free component.
        let flatRates = model.base.normalizedForRemoteCatalog
        if model.tiers.isEmpty,
           flatRates.hasZeroRate(for: tokens),
           let exactCost = flatRates.cost(for: tokens) {
            return ResolvedPricing(
                cost: exactCost,
                hasKnownPricing: true,
                source: .remote,
                pricingProviderIDs: providerIDs,
                outcome: exactCost == 0 ? .knownFree : .knownPaid,
                tierThreshold: nil,
                backendThreshold: backendThreshold
            )
        }

        // A zero backend result is not evidence of a free remote model: it
        // also means ccusage had no usable price entry. Accept zero only when
        // the active schedule itself proves that every used component is free.
        let usesTier = selectedTier != nil
            && (backendThreshold ?? Int64.max) < tokens.inputTokens
        let effectiveRates = (usesTier ? model.base.merging(selectedTier?.rates ?? .empty) : model.base)
            .normalizedForRemoteCatalog
        guard effectiveRates.hasCompleteRates(for: tokens),
              effectiveRates.isAllZero(for: tokens) else {
            // The catalog contains a usable paid schedule, but the backend
            // did not return a positive cost for this row. That is an
            // ordinary unresolved calculation, not evidence that the
            // provider stopped covering the model.
            return unresolvedRemotePricing(outcome: .intentionalUnknown)
        }

        return ResolvedPricing(
            cost: 0,
            hasKnownPricing: true,
            source: .remote,
            pricingProviderIDs: providerIDs,
            outcome: .knownFree,
            tierThreshold: selectedTier?.threshold,
            backendThreshold: backendThreshold
        )
    }

    private func unresolvedRemotePricing(
        outcome: PricingAssessmentOutcome = .intentionalUnknown,
        catalogGap: PricingCatalogGapReason? = nil
    ) -> ResolvedPricing {
        ResolvedPricing(
            cost: 0,
            hasKnownPricing: false,
            source: .unknown,
            outcome: outcome,
            catalogGap: catalogGap,
            tierThreshold: nil,
            backendThreshold: nil
        )
    }

    private func unresolvedCustomPricing(
        containsUsedZero: Bool,
        tierThreshold: Int64?,
        backendThreshold: Int64?
    ) -> ResolvedPricing {
        ResolvedPricing(
            cost: 0,
            hasKnownPricing: false,
            source: .unknown,
            outcome: containsUsedZero ? .unsupportedCustomZero : .intentionalUnknown,
            tierThreshold: nil,
            backendThreshold: nil
        )
    }

    private func customSource(for key: String) -> ModelPricingSource {
        context.preparation.approximateModelNames.contains(key) ? .approximate : .custom
    }

    private func selectedTier(for key: String, in model: CanonicalModelPricing) -> PricingTier? {
        guard let threshold = context.preparation.selectedTierThresholds[key] else { return nil }
        return model.tiers.first(where: { $0.threshold == threshold })
    }

    private func usablePositiveCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

}
