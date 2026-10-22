import Foundation

/// Derives the snapshot-level pricing provenance from the model rows that are
/// actually being displayed. Callers provide the fallback for snapshots that
/// do not contain model usage, because those cases have different semantics
/// during a usage merge and a fresh pricing build.
enum PricingSourceAggregation {
    /// Combines provenance for one model that may occur in multiple usage
    /// rows. This is the single source of truth for mixed-provider/source
    /// semantics used by ordinary and monthly builders.
    static func combine(
        _ lhs: ModelPricingSource,
        _ rhs: ModelPricingSource
    ) -> ModelPricingSource {
        if lhs == .unknown || rhs == .unknown { return .unknown }
        if lhs == .mixed || rhs == .mixed { return .mixed }
        if lhs == .approximate || rhs == .approximate { return .approximate }
        if (lhs == .custom && rhs == .remote) || (lhs == .remote && rhs == .custom) {
            return .mixed
        }
        if lhs == .custom || rhs == .custom { return .custom }
        if lhs == .remote || rhs == .remote { return .remote }
        return .ccusage
    }

    static func providerIDs(
        _ lhs: [String],
        _ rhs: [String]
    ) -> [String] {
        PricingProviderIdentity.normalized(lhs + rhs)
    }

    static func mergedThreshold(
        _ lhs: Int64?,
        _ rhs: Int64?,
        source: ModelPricingSource
    ) -> Int64? {
        guard source != .mixed else { return nil }
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs == rhs ? lhs : nil
    }

    static func aggregate(
        for models: [ModelUsage],
        emptyFallback: PricingSource = .ccusage
    ) -> PricingSource {
        let used = models.filter { $0.tokens.totalTokens > 0 }
        guard !used.isEmpty else { return emptyFallback }

        let hasUnknown = used.contains { !$0.hasKnownPricing || $0.pricingSource == .unknown }
        let hasMixed = used.contains { $0.pricingSource == .mixed }
        let hasApproximate = used.contains { $0.pricingSource == .approximate }
        let hasCustom = used.contains { $0.pricingSource == .custom }
        let hasRemote = used.contains { $0.pricingSource == .remote }
        let hasCcusage = used.contains { $0.pricingSource == .ccusage }

        // An unknown row is a correctness warning: its usage is excluded from
        // the total, so it must not be hidden behind an approximate estimate.
        // Keep the existing `.mixed` provenance for other known/unknown source
        // combinations, but make approximate + unknown fail closed at the
        // snapshot level so the badge cannot advertise only "Approximate".
        if hasApproximate && hasUnknown { return .unknown }
        if hasApproximate { return .approximate }
        if hasMixed { return .mixed }
        if hasCustom && !hasUnknown && !hasCcusage && !hasRemote { return .custom }
        if hasRemote && !hasUnknown && !hasCustom && !hasCcusage { return .remote }
        if hasCustom || hasRemote { return .mixed }
        if hasUnknown { return .unknown }
        return .ccusage
    }
}
