import Foundation

enum CcusagePricingAdapterError: LocalizedError, Equatable {
    case noUsableOverrides

    var errorDescription: String? {
        switch self {
        case .noUsableOverrides:
            return "The custom price list contains no usable ccusage overrides."
        }
    }
}

struct CcusagePricingDiagnostic: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case multipleTiers
        case unsupportedThreshold
    }

    let modelName: String
    let reason: Reason
    let threshold: Int64?
}

struct CcusagePricingPreparation: Equatable, Sendable {
    let appliedModelNames: Set<String>
    let approximateModelNames: Set<String>
    let selectedTierThresholds: [String: Int64]
    let selectedBackendThresholds: [String: Int64]
    let diagnostics: [CcusagePricingDiagnostic]
    let hasOverrides: Bool
    let supportsExplicitZeroOverrides: Bool

    static let empty = CcusagePricingPreparation(
        appliedModelNames: [],
        approximateModelNames: [],
        selectedTierThresholds: [:],
        selectedBackendThresholds: [:],
        diagnostics: [],
        hasOverrides: false,
        supportsExplicitZeroOverrides: true
    )
}

/// Versioned facts about the target ccusage pricing interface. Keeping these
/// facts outside the translator makes the compatibility rule replaceable when
/// a newer ccusage accepts native LiteLLM tiers or exposes explicit thresholds.
struct CcusagePricingCapabilities: Equatable, Sendable {
    let defaultAlternateTierThreshold: Int64
    let modelAlternateTierThresholds: [String: Int64]
    let supportsExplicitZeroOverrides: Bool

    static let bundledV20 = CcusagePricingCapabilities(
        defaultAlternateTierThreshold: 200_000,
        modelAlternateTierThresholds: [
            "gpt-5.4": 272_000,
            "gpt-5.4-pro": 272_000,
            "gpt-5.5": 272_000,
            "gpt-5.5-pro": 272_000,
            "gpt-5.6": 272_000,
            "gpt-5.6-sol": 272_000,
            "gpt-5.6-terra": 272_000,
            "gpt-5.6-luna": 272_000,
            "gpt-6-astra": 272_000,
            "gpt-6-luna": 272_000,
            "gpt-6-luna@eu": 272_000,
            "gpt-6-sol": 272_000,
            "gpt-6-sol@eu": 272_000,
            "gpt-6.1-sol": 272_000,
            "gpt-6.1-sol@eu": 272_000
        ],
        // The pinned 20.0.32 native binary applies explicit zero rates,
        // including zero-bearing alternate tiers, when calculating cost.
        supportsExplicitZeroOverrides: true
    )

    func effectiveThreshold(for modelName: String, canonicalModelName: String? = nil) -> Int64 {
        let candidates = [canonicalModelName, modelName].compactMap { $0 }
        for candidate in candidates {
            if let threshold = modelAlternateTierThresholds[PricingModelIdentity.matchingKey(candidate)] {
                return threshold
            }
        }
        return defaultAlternateTierThreshold
    }

    private static func normalize(_ modelName: String) -> String {
        PricingModelIdentity.matchingKey(modelName)
    }
}

/// Translates the backend-neutral pricing schedule into the legacy config
/// shape supported by bundled ccusage 20.0.32.
///
/// This is intentionally the only place that knows that ccusage calls its
/// single alternate tier Above200kTokens. The canonical model retains the
/// actual source threshold (for example 272,000); this adapter selects the
/// closest source tier that the bundled backend can represent and records when
/// that selection is approximate.
struct CcusagePricingAdapter: Sendable {
    let capabilities: CcusagePricingCapabilities

    static let bundledV20 = CcusagePricingAdapter(capabilities: .bundledV20)

    init(capabilities: CcusagePricingCapabilities) {
        self.capabilities = capabilities
    }

    func prepare(
        catalog: CanonicalPricingCatalog,
        writeTo url: URL,
        fileManager: FileManager = .default
    ) throws -> CcusagePricingPreparation {
        let result = makeDocument(from: catalog, canonicalModelNames: [:])

        guard !result.overrides.isEmpty else {
            try? fileManager.removeItem(at: url)
            return CcusagePricingPreparation(
                appliedModelNames: [],
                approximateModelNames: [],
                selectedTierThresholds: [:],
                selectedBackendThresholds: [:],
                diagnostics: result.diagnostics,
                hasOverrides: false,
                supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CcusageConfigDocument(
            defaults: CcusageDefaults(pricingOverrides: result.overrides)
        ))
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])

        return CcusagePricingPreparation(
            appliedModelNames: Set(result.overrides.keys.map(Self.normalize)),
            approximateModelNames: result.approximateModelNames,
            selectedTierThresholds: result.selectedTierThresholds,
            selectedBackendThresholds: result.selectedBackendThresholds,
            diagnostics: result.diagnostics,
            hasOverrides: true,
            supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
        )
    }

    func prepare(
        composition: PricingCatalogComposition,
        writeTo url: URL,
        fileManager: FileManager = .default
    ) throws -> CcusagePricingPreparation {
        let result = makeDocument(
            from: composition.catalog,
            canonicalModelNames: canonicalModelNames(for: composition)
        )

        guard !result.overrides.isEmpty else {
            try? fileManager.removeItem(at: url)
            return CcusagePricingPreparation(
                appliedModelNames: [],
                approximateModelNames: [],
                selectedTierThresholds: [:],
                selectedBackendThresholds: [:],
                diagnostics: result.diagnostics,
                hasOverrides: false,
                supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CcusageConfigDocument(
            defaults: CcusageDefaults(pricingOverrides: result.overrides)
        ))
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])

        return CcusagePricingPreparation(
            appliedModelNames: Set(result.overrides.keys.map(Self.normalize)),
            approximateModelNames: result.approximateModelNames,
            selectedTierThresholds: result.selectedTierThresholds,
            selectedBackendThresholds: result.selectedBackendThresholds,
            diagnostics: result.diagnostics,
            hasOverrides: true,
            supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
        )
    }

    /// Returns the same execution facts as `prepare` without writing a
    /// generated config. Builders use this when they need to resolve a
    /// synthetic response in isolation, while MonitorStore uses the facts
    /// returned by the file-writing path.
    func preparation(for catalog: CanonicalPricingCatalog) -> CcusagePricingPreparation {
        let result = makeDocument(from: catalog, canonicalModelNames: [:])
        return CcusagePricingPreparation(
            appliedModelNames: Set(result.overrides.keys.map(Self.normalize)),
            approximateModelNames: result.approximateModelNames,
            selectedTierThresholds: result.selectedTierThresholds,
            selectedBackendThresholds: result.selectedBackendThresholds,
            diagnostics: result.diagnostics,
            hasOverrides: !result.overrides.isEmpty,
            supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
        )
    }

    func preparation(for composition: PricingCatalogComposition) -> CcusagePricingPreparation {
        let result = makeDocument(
            from: composition.catalog,
            canonicalModelNames: canonicalModelNames(for: composition)
        )
        return CcusagePricingPreparation(
            appliedModelNames: Set(result.overrides.keys.map(Self.normalize)),
            approximateModelNames: result.approximateModelNames,
            selectedTierThresholds: result.selectedTierThresholds,
            selectedBackendThresholds: result.selectedBackendThresholds,
            diagnostics: result.diagnostics,
            hasOverrides: !result.overrides.isEmpty,
            supportsExplicitZeroOverrides: capabilities.supportsExplicitZeroOverrides
        )
    }

    /// Builds a document without touching disk so the translation remains
    /// deterministic and straightforward to test.
    func data(for catalog: CanonicalPricingCatalog) throws -> Data {
        let result = makeDocument(from: catalog, canonicalModelNames: [:])
        guard !result.overrides.isEmpty else {
            throw CcusagePricingAdapterError.noUsableOverrides
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CcusageConfigDocument(
            defaults: CcusageDefaults(pricingOverrides: result.overrides)
        ))
    }

    func data(for composition: PricingCatalogComposition) throws -> Data {
        let result = makeDocument(
            from: composition.catalog,
            canonicalModelNames: canonicalModelNames(for: composition)
        )
        guard !result.overrides.isEmpty else {
            throw CcusagePricingAdapterError.noUsableOverrides
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CcusageConfigDocument(
            defaults: CcusageDefaults(pricingOverrides: result.overrides)
        ))
    }

    private func makeDocument(
        from catalog: CanonicalPricingCatalog,
        canonicalModelNames: [String: String]
    ) -> (
        overrides: [String: CcusagePricingOverride],
        approximateModelNames: Set<String>,
        selectedTierThresholds: [String: Int64],
        selectedBackendThresholds: [String: Int64],
        diagnostics: [CcusagePricingDiagnostic]
    ) {
        var overrides: [String: CcusagePricingOverride] = [:]
        var approximateModelNames: Set<String> = []
        var selectedTierThresholds: [String: Int64] = [:]
        var selectedBackendThresholds: [String: Int64] = [:]
        var diagnostics: [CcusagePricingDiagnostic] = []

        for model in catalog.models {
            guard let override = makeOverride(
                for: model,
                canonicalModelName: canonicalModelNames[Self.normalize(model.modelName)],
                approximateModelNames: &approximateModelNames,
                selectedTierThresholds: &selectedTierThresholds,
                selectedBackendThresholds: &selectedBackendThresholds,
                diagnostics: &diagnostics
            ) else { continue }
            overrides[model.modelName] = override
        }

        return (
            overrides,
            approximateModelNames,
            selectedTierThresholds,
            selectedBackendThresholds,
            diagnostics.sorted { $0.modelName < $1.modelName }
        )
    }

    private func makeOverride(
        for model: CanonicalModelPricing,
        canonicalModelName: String?,
        approximateModelNames: inout Set<String>,
        selectedTierThresholds: inout [String: Int64],
        selectedBackendThresholds: inout [String: Int64],
        diagnostics: inout [CcusagePricingDiagnostic]
    ) -> CcusagePricingOverride? {
        let base = model.base
        // Keep invalid-but-recognized tiers in selection. The generated
        // config omits their unusable fields, while PricingResolver still
        // sees the effective boundary and can fail closed instead of
        // silently inheriting base rates above it.
        let tiers = model.tiers

        let targetThreshold = capabilities.effectiveThreshold(
            for: model.modelName,
            canonicalModelName: canonicalModelName
        )
        let tier = selectTier(from: tiers, targetThreshold: targetThreshold)
        if let tier {
            selectedTierThresholds[Self.normalize(model.modelName)] = tier.threshold
            selectedBackendThresholds[Self.normalize(model.modelName)] = targetThreshold
            let isApproximate = tiers.count > 1 || tier.threshold != targetThreshold
            if isApproximate {
                approximateModelNames.insert(Self.normalize(model.modelName))
                diagnostics.append(CcusagePricingDiagnostic(
                    modelName: model.modelName,
                    reason: tiers.count > 1 ? .multipleTiers : .unsupportedThreshold,
                    threshold: tier.threshold
                ))
            }
        }

        let override = CcusagePricingOverride(
            input: usableRate(base.input),
            output: usableRate(base.output),
            cacheCreation: usableRate(base.cacheCreation),
            cacheRead: usableRate(base.cacheRead),
            inputAbove: usableRate(tier?.rates.input),
            outputAbove: usableRate(tier?.rates.output),
            cacheCreationAbove: usableRate(tier?.rates.cacheCreation),
            cacheReadAbove: usableRate(tier?.rates.cacheRead),
            maxInputTokens: usableLimit(model.maxInputTokens),
            fastMultiplier: usableMultiplier(model.fastMultiplier)
        )
        return override.hasAnyValue ? override : nil
    }

    private func selectTier(from tiers: [PricingTier], targetThreshold: Int64) -> PricingTier? {
        tiers.min { lhs, rhs in
            let lhsDistance = distance(lhs.threshold, targetThreshold)
            let rhsDistance = distance(rhs.threshold, targetThreshold)
            if lhsDistance == rhsDistance {
                return lhs.threshold < rhs.threshold
            }
            return lhsDistance < rhsDistance
        }
    }

    private func distance(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private func usableRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func usableLimit(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func usableMultiplier(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalize(_ modelName: String) -> String {
        PricingModelIdentity.matchingKey(modelName)
    }

    private func canonicalModelNames(for composition: PricingCatalogComposition) -> [String: String] {
        Dictionary(uniqueKeysWithValues: composition.catalog.models.compactMap { model in
            guard let canonical = composition.canonicalModelName(forProjectedModelName: model.modelName) else {
                return nil
            }
            return (Self.normalize(model.modelName), canonical)
        })
    }
}

private struct CcusageConfigDocument: Encodable {
    let defaults: CcusageDefaults
}

private struct CcusageDefaults: Encodable {
    let pricingOverrides: [String: CcusagePricingOverride]

    private enum CodingKeys: String, CodingKey {
        case pricingOverrides
    }
}

private struct CcusagePricingOverride: Encodable, Equatable {
    let input: Double?
    let output: Double?
    let cacheCreation: Double?
    let cacheRead: Double?
    let inputAbove: Double?
    let outputAbove: Double?
    let cacheCreationAbove: Double?
    let cacheReadAbove: Double?
    let maxInputTokens: Int64?
    let fastMultiplier: Double?

    var hasAnyValue: Bool {
        input != nil
            || output != nil
            || cacheCreation != nil
            || cacheRead != nil
            || inputAbove != nil
            || outputAbove != nil
            || cacheCreationAbove != nil
            || cacheReadAbove != nil
            || maxInputTokens != nil
            || fastMultiplier != nil
    }

    private enum CodingKeys: String, CodingKey {
        case input = "inputCostPerToken"
        case output = "outputCostPerToken"
        case cacheCreation = "cacheCreationInputTokenCost"
        case cacheRead = "cacheReadInputTokenCost"
        case inputAbove = "inputCostPerTokenAbove200kTokens"
        case outputAbove = "outputCostPerTokenAbove200kTokens"
        case cacheCreationAbove = "cacheCreationInputTokenCostAbove200kTokens"
        case cacheReadAbove = "cacheReadInputTokenCostAbove200kTokens"
        case maxInputTokens
        case fastMultiplier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(input, forKey: .input)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(cacheCreation, forKey: .cacheCreation)
        try container.encodeIfPresent(cacheRead, forKey: .cacheRead)
        try container.encodeIfPresent(inputAbove, forKey: .inputAbove)
        try container.encodeIfPresent(outputAbove, forKey: .outputAbove)
        try container.encodeIfPresent(cacheCreationAbove, forKey: .cacheCreationAbove)
        try container.encodeIfPresent(cacheReadAbove, forKey: .cacheReadAbove)
        try container.encodeIfPresent(maxInputTokens, forKey: .maxInputTokens)
        try container.encodeIfPresent(fastMultiplier, forKey: .fastMultiplier)
    }
}
