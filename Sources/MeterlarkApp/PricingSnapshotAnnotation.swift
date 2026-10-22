import Foundation

/// Adds provenance metadata after ccusage has calculated the complete cost.
/// It deliberately does not touch any cost field: tier selection and
/// aggregation belong to the pricing backend, not to a second App-side
/// calculator.
enum PricingSnapshotAnnotation {
    static func apply(
        to snapshot: UsageSnapshot,
        customPricingRevision: String?,
        appliedModelNames: Set<String>,
        approximateModelNames: Set<String> = [],
        selectedTierThresholds: [String: Int64] = [:],
        selectedBackendThresholds: [String: Int64] = [:],
        modelCatalogRevision: String? = nil,
        pricingComposition: PricingCatalogComposition? = nil
    ) -> UsageSnapshot {
        let normalizedAppliedNames = Set(appliedModelNames.map(normalize))
        let normalizedApproximateNames = Set(approximateModelNames.map(normalize))
        let normalizedSelectedThresholds = Dictionary(uniqueKeysWithValues: selectedTierThresholds.map { (normalize($0.key), $0.value) })
        let normalizedBackendThresholds = Dictionary(uniqueKeysWithValues: selectedBackendThresholds.map { (normalize($0.key), $0.value) })
        let models = snapshot.models.map { model in
            let metadata = pricingMetadata(
                for: model.name,
                existingSource: model.pricingSource,
                existingProviderIDs: model.pricingProviderIDs,
                hasKnownPricing: model.hasKnownPricing,
                appliedNames: normalizedAppliedNames,
                approximateNames: normalizedApproximateNames,
                pricingComposition: pricingComposition
            )
            let selectedThreshold = metadata.usesSchedule
                ? threshold(
                    for: model.name,
                    modelKey: metadata.modelKey,
                    values: normalizedSelectedThresholds
                )
                : nil
            let backendThreshold = metadata.usesSchedule
                ? threshold(
                    for: model.name,
                    modelKey: metadata.modelKey,
                    values: normalizedBackendThresholds
                )
                : nil
            return ModelUsage(
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: model.estimatedCost,
                hasKnownPricing: model.hasKnownPricing,
                pricingSource: metadata.source,
                pricingProviderIDs: metadata.providerIDs,
                pricingTierThreshold: selectedThreshold,
                pricingBackendThreshold: backendThreshold
            )
        }
        let dailyModels = snapshot.dailyModels.map { model in
            let metadata = pricingMetadata(
                for: model.name,
                existingSource: model.pricingSource,
                existingProviderIDs: model.pricingProviderIDs,
                hasKnownPricing: model.hasKnownPricing,
                appliedNames: normalizedAppliedNames,
                approximateNames: normalizedApproximateNames,
                pricingComposition: pricingComposition
            )
            let selectedThreshold = metadata.usesSchedule
                ? threshold(
                    for: model.name,
                    modelKey: metadata.modelKey,
                    values: normalizedSelectedThresholds
                )
                : nil
            let backendThreshold = metadata.usesSchedule
                ? threshold(
                    for: model.name,
                    modelKey: metadata.modelKey,
                    values: normalizedBackendThresholds
                )
                : nil
            return DailyModelUsage(
                period: model.period,
                agent: model.agent,
                name: model.name,
                tokens: model.tokens,
                estimatedCost: model.estimatedCost,
                hasKnownPricing: model.hasKnownPricing,
                pricingSource: metadata.source,
                pricingProviderIDs: metadata.providerIDs,
                pricingTierThreshold: selectedThreshold,
                pricingBackendThreshold: backendThreshold
            )
        }
        let pricingSource = PricingSourceAggregation.aggregate(
            for: models,
            emptyFallback: snapshot.pricingSource
        )

        return UsageSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            pricingUpdatedAt: snapshot.pricingUpdatedAt,
            queryScope: snapshot.queryScope,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision ?? snapshot.modelCatalogRevision,
            days: snapshot.days,
            dailyModels: dailyModels,
            agents: snapshot.agents,
            models: models,
            totalTokens: snapshot.totalTokens,
            estimatedCost: snapshot.estimatedCost,
            unknownPricingModels: snapshot.unknownPricingModels,
            pricingSource: pricingSource
        )
    }

    private struct PricingMetadata {
        let source: ModelPricingSource
        let providerIDs: [String]
        let modelKey: String

        var usesSchedule: Bool {
            source == .custom || source == .approximate || source == .remote
        }
    }

    private static func pricingMetadata(
        for modelName: String,
        existingSource: ModelPricingSource,
        existingProviderIDs: [String],
        hasKnownPricing: Bool,
        appliedNames: Set<String>,
        approximateNames: Set<String>,
        pricingComposition: PricingCatalogComposition?
    ) -> PricingMetadata {
        let normalizedName = normalize(modelName)
        guard hasKnownPricing else {
            return PricingMetadata(source: .unknown, providerIDs: [], modelKey: normalizedName)
        }

        guard let pricingComposition else {
            let source: ModelPricingSource
            if existingSource == .mixed {
                source = .mixed
            } else if existingSource == .remote {
                source = .remote
            } else if approximateNames.contains(normalizedName) {
                source = .approximate
            } else if appliedNames.contains(normalizedName) {
                source = .custom
            } else {
                source = .ccusage
            }
            let providerIDs = source == .remote || source == .mixed
                ? PricingProviderIdentity.normalized(existingProviderIDs)
                : []
            return PricingMetadata(source: source, providerIDs: providerIDs, modelKey: normalizedName)
        }

        let lookup = pricingComposition.lookup(for: modelName)
        let modelKey = lookup.modelKey ?? normalizedName
        let isApproximate = approximateNames.contains(normalizedName)
            || approximateNames.contains(modelKey)

        switch lookup.kind {
        case .custom:
            return PricingMetadata(
                source: isApproximate ? .approximate : .custom,
                providerIDs: [],
                modelKey: modelKey
            )
        case .remote:
            return PricingMetadata(
                source: existingSource == .mixed ? .mixed : .remote,
                providerIDs: existingSource == .mixed
                    ? PricingProviderIdentity.normalized(existingProviderIDs)
                    : PricingProviderIdentity.normalized(
                        lookup.providerIDs.isEmpty ? existingProviderIDs : lookup.providerIDs
                    ),
                modelKey: modelKey
            )
        case .remoteMissing, .remoteDisabled, .noSource:
            // The resolver falls back to the backend/ccusage price for these
            // states. Annotation must not turn that fallback into a custom or
            // remote label merely because a generated override happened to
            // contain a similarly named record.
            return PricingMetadata(source: .ccusage, providerIDs: [], modelKey: modelKey)
        case .remoteAmbiguous, .remoteIncomplete:
            // A correctly paired resolver already marks these rows unknown.
            // If a legacy runner supplied a known backend cost anyway, keep
            // its existing source rather than creating contradictory metadata;
            // the status diagnosis still exposes the catalog gap.
            let source = existingSource == .mixed ? .mixed : existingSource
            return PricingMetadata(
                source: source,
                providerIDs: source == .remote || source == .mixed
                    ? PricingProviderIdentity.normalized(existingProviderIDs)
                    : [],
                modelKey: modelKey
            )
        }
    }

    private static func threshold(
        for modelName: String,
        modelKey: String,
        values: [String: Int64]
    ) -> Int64? {
        values[modelKey] ?? values[normalize(modelName)]
    }

    private static func normalize(_ value: String) -> String {
        PricingModelIdentity.matchingKey(value)
    }
}
