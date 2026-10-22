import Foundation

enum PricingModelIdentity {
    private static let knownDisplayWrappers = [
        "[pi] ",
        "[store] ",
        "[openclaw] ",
        "[grok] "
    ]

    /// Returns the exact model identity first, followed only by wrappers that
    /// are emitted by known agents. Provider prefixes such as `openai.` and
    /// `openai/` are intentionally not stripped: a gateway route can be a
    /// real billing identity rather than decoration.
    static func lookupKeys(for value: String) -> [String] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }

        let exactKey = matchingKey(normalized)
        var keys = exactKey.isEmpty ? [] : [exactKey]
        for wrapper in knownDisplayWrappers where normalized.hasPrefix(wrapper) {
            let unwrapped = String(normalized.dropFirst(wrapper.count))
            let key = matchingKey(unwrapped)
            if !key.isEmpty, !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    /// Strong identities are the names emitted by the usage source itself,
    /// plus the explicitly supported display wrappers. They are allowed to
    /// select one catalog record. Provider/gateway metadata is deliberately
    /// not part of this set: it is only a weak alias below.
    static func strongKeys(for value: String) -> [String] {
        lookupKeys(for: value)
    }

    /// Produces a weak lookup key for route/key/base-model metadata. Weak
    /// aliases are useful when a gateway reports `provider/model` while the
    /// catalog's display name is `model`, but they must never be transitively
    /// unioned with another weak alias.
    static func weakAliasKey(for value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .letters) != nil,
              !isISODate(normalized) else {
            return nil
        }
        let key = matchingKey(normalized)
        return key.isEmpty ? nil : key
    }

    /// A catalog `page_display_data.version` is often a release date. Dates
    /// are metadata, not model aliases, and must not merge every model
    /// released on the same day. Non-date versions may still be gateway model
    /// IDs, such as `openai.gpt-5.6-sol`.
    static func routeAliasKey(for value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !isISODate(normalized) else { return nil }
        let key = matchingKey(normalized)
        return key.isEmpty ? nil : key
    }

    private static func isISODate(_ value: String) -> Bool {
        let characters = Array(value)
        guard characters.count == 10,
              characters[4] == "-",
              characters[7] == "-" else {
            return false
        }
        return characters.enumerated().allSatisfy { index, character in
            [4, 7].contains(index) || character.isNumber
        }
    }

    static func matchingKey(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffixLength in [11, 9] {
            guard normalized.count > suffixLength else { continue }
            let start = normalized.index(normalized.endIndex, offsetBy: -suffixLength)
            let suffix = String(normalized[start...])
            let characters = Array(suffix)
            let valid: Bool
            if suffixLength == 11 {
                valid = characters.count == 11
                    && characters.first == "-"
                    && characters[5] == "-"
                    && characters[8] == "-"
                    && characters.enumerated().allSatisfy { index, character in
                        [0, 5, 8].contains(index) || character.isNumber
                    }
            } else {
                valid = characters.count == 9
                    && characters.first == "-"
                    && characters.dropFirst().allSatisfy(\.isNumber)
            }
            if valid {
                return String(normalized[..<start])
            }
        }
        return normalized
    }
}

/// The four token-priced components understood by LiteLLM-style pricing
/// records. Keeping this representation independent from ccusage's config
/// field names lets a backend adapter translate the same schedule to another
/// input format later.
struct PricingRates: Codable, Equatable, Sendable {
    var input: Double?
    var output: Double?
    var cacheCreation: Double?
    var cacheRead: Double?

    static let empty = PricingRates(
        input: nil,
        output: nil,
        cacheCreation: nil,
        cacheRead: nil
    )

    var hasAnyRate: Bool {
        [input, output, cacheCreation, cacheRead].contains { rate in
            guard let rate else { return false }
            return rate.isFinite && rate >= 0
        }
    }

    /// ExampleGateway requires input and output rates to be present. Cache rates are a
    /// separate optional contract: a missing cache rate means that cache
    /// tokens are not charged by that catalog.
    var hasRequiredInputOutputRates: Bool {
        isValid(input) && isValid(output)
    }

    /// Applies the remote catalog convention that an omitted/null cache rate
    /// represents a free cache component. Custom pricing does not use this
    /// helper and therefore keeps its stricter missing-rate semantics.
    var normalizedForRemoteCatalog: PricingRates {
        PricingRates(
            input: input,
            output: output,
            cacheCreation: cacheCreation ?? 0,
            cacheRead: cacheRead ?? 0
        )
    }

    func hasCompleteRates(for tokens: TokenTotals) -> Bool {
        (tokens.inputTokens <= 0 || isValid(input))
            && (tokens.outputTokens <= 0 || isValid(output))
            && (tokens.cacheCreationTokens <= 0 || isValid(cacheCreation))
            && (tokens.cacheReadTokens <= 0 || isValid(cacheRead))
    }

    func cost(for tokens: TokenTotals) -> Double? {
        guard hasCompleteRates(for: tokens) else { return nil }
        return componentCost(tokens.inputTokens, rate: input)
            + componentCost(tokens.outputTokens, rate: output)
            + componentCost(tokens.cacheCreationTokens, rate: cacheCreation)
            + componentCost(tokens.cacheReadTokens, rate: cacheRead)
    }

    func hasZeroRate(for tokens: TokenTotals) -> Bool {
        let usedRates: [(Int64, Double?)] = [
            (tokens.inputTokens, input),
            (tokens.outputTokens, output),
            (tokens.cacheCreationTokens, cacheCreation),
            (tokens.cacheReadTokens, cacheRead)
        ]
        return usedRates.contains { tokens, rate in
            tokens > 0 && rate == 0
        }
    }

    func isAllZero(for tokens: TokenTotals) -> Bool {
        let usedRates: [(Int64, Double?)] = [
            (tokens.inputTokens, input),
            (tokens.outputTokens, output),
            (tokens.cacheCreationTokens, cacheCreation),
            (tokens.cacheReadTokens, cacheRead)
        ]
        return usedRates.filter { $0.0 > 0 }.allSatisfy { $0.1 == 0 }
    }

    private func isValid(_ rate: Double?) -> Bool {
        guard let rate else { return false }
        return rate.isFinite && rate >= 0
    }

    private func componentCost(_ tokens: Int64, rate: Double?) -> Double {
        guard tokens > 0, let rate, rate.isFinite, rate >= 0 else { return 0 }
        return Double(tokens) * rate
    }

    func merging(_ incoming: PricingRates) -> PricingRates {
        PricingRates(
            input: incoming.input ?? input,
            output: incoming.output ?? output,
            cacheCreation: incoming.cacheCreation ?? cacheCreation,
            cacheRead: incoming.cacheRead ?? cacheRead
        )
    }
}

enum PricingRateComponent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case input
    case output
    case cacheCreation
    case cacheRead
}

struct PricingTier: Codable, Equatable, Sendable {
    /// The tier applies when the input context is greater than this value.
    let threshold: Int64
    let rates: PricingRates
}

struct CanonicalModelPricing: Codable, Equatable, Sendable {
    let modelName: String
    let base: PricingRates
    let tiers: [PricingTier]
    let maxInputTokens: Int64?
    let fastMultiplier: Double?

    /// A remote catalog explicitly describes every component as free. This
    /// is different from a missing ccusage price, whose zero result remains
    /// unknown.
    var scheduleIsExplicitlyFree: Bool {
        guard base.input == 0, base.output == 0 else { return false }
        return tiers.allSatisfy { tier in
            (tier.rates.input ?? 0) == 0
                && (tier.rates.output ?? 0) == 0
                && (tier.rates.cacheCreation ?? 0) == 0
                && (tier.rates.cacheRead ?? 0) == 0
        }
    }

    var missingRequiredBaseRateComponents: [PricingRateComponent] {
        [
            (PricingRateComponent.input, base.input),
            (PricingRateComponent.output, base.output)
        ].compactMap { component, rate in
            rate == nil ? component : nil
        }
    }
}

enum PricingScheduleEquivalence {
    /// Identity and descriptive metadata may differ across provider aliases,
    /// while the pricing calculation can still be exactly the same. Only the
    /// rates consumed by the resolver participate in ambiguity detection.
    static func areEquivalent(
        _ lhs: CanonicalModelPricing,
        _ rhs: CanonicalModelPricing
    ) -> Bool {
        lhs.base == rhs.base
            && lhs.tiers == rhs.tiers
            && lhs.maxInputTokens == rhs.maxInputTokens
            && lhs.fastMultiplier == rhs.fastMultiplier
    }
}

struct CanonicalPricingCatalog: Codable, Equatable, Sendable {
    let models: [CanonicalModelPricing]

    static let empty = CanonicalPricingCatalog(models: [])
}

private enum CanonicalTierComponent {
    case input
    case output
    case cacheCreation
    case cacheRead
}

extension CustomPricingTable {
    /// Converts the imported LiteLLM-shaped table into a backend-neutral
    /// pricing schedule. Unknown metadata is preserved by CustomPricingTable,
    /// but only recognized rate fields become cost-bearing tiers here.
    var canonicalPricingCatalog: CanonicalPricingCatalog {
        let models = entries.keys.sorted().compactMap { key -> CanonicalModelPricing? in
            guard let pricing = entries[key] else { return nil }
            let modelInfo = metadata[key]?.modelInfo ?? [:]
            var tiersByThreshold: [Int64: PricingRates] = [:]
            var invalidTierThresholds: Set<Int64> = []

            for (field, value) in modelInfo {
                guard let tierField = Self.tierField(field), tierField.threshold > 0 else { continue }

                // LiteLLM-shaped provider records commonly emit the complete
                // set of possible tier fields with JSON null placeholders.
                // A threshold whose fields are all null is absent, not an
                // invalid tier. Keep invalid-but-present values fail-closed,
                // but do not manufacture empty tiers from schema placeholders.
                if case .null = value { continue }

                guard let rate = value.doubleValue, rate.isFinite, rate >= 0 else {
                    invalidTierThresholds.insert(tierField.threshold)
                    continue
                }

                var rates = tiersByThreshold[tierField.threshold] ?? .empty
                rates.set(rate, for: tierField.component)
                tiersByThreshold[tierField.threshold] = rates
            }

            let tierThresholds = Set(tiersByThreshold.keys).union(invalidTierThresholds)
            let tiers = tierThresholds
                .compactMap { threshold -> PricingTier? in
                    let rates = tiersByThreshold[threshold] ?? .empty
                    guard rates.hasAnyRate || invalidTierThresholds.contains(threshold) else { return nil }
                    return PricingTier(
                        threshold: threshold,
                        rates: rates
                    )
                }
                .sorted { $0.threshold < $1.threshold }

            return CanonicalModelPricing(
                modelName: displayNames[key] ?? key,
                base: PricingRates(
                    input: pricing.inputCostPerToken,
                    output: pricing.outputCostPerToken,
                    cacheCreation: pricing.cacheCreationInputTokenCost,
                    cacheRead: pricing.cacheReadInputTokenCost
                ),
                tiers: tiers,
                maxInputTokens: metadata[key]?.integer(for: "max_input_tokens"),
                fastMultiplier: metadata[key]?.double(for: "fast_multiplier")
            )
        }

        return CanonicalPricingCatalog(models: models)
    }

    private struct TierField {
        let component: CanonicalTierComponent
        let threshold: Int64
    }

    private static func tierField(_ field: String) -> TierField? {
        // LiteLLM uses fields such as
        // input_cost_per_token_above_272k_tokens. Parsing the numeric suffix
        // makes this work for future thresholds without adding one case per
        // provider or model family. Priority-specific fields intentionally do
        // not match because this app currently reports standard pricing.
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
        guard var threshold = Int64(numericPart) else { return nil }
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

        let component: CanonicalTierComponent
        switch baseField {
        case "input_cost_per_token": component = .input
        case "output_cost_per_token": component = .output
        case "cache_creation_input_token_cost": component = .cacheCreation
        case "cache_read_input_token_cost": component = .cacheRead
        default: return nil
        }
        return TierField(component: component, threshold: threshold)
    }
}

private extension PricingRates {
    mutating func set(_ rate: Double, for component: CanonicalTierComponent) {
        switch component {
        case .input: input = rate
        case .output: output = rate
        case .cacheCreation: cacheCreation = rate
        case .cacheRead: cacheRead = rate
        }
    }
}
