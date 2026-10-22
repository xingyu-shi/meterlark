import Foundation

enum BudgetMetricLevel: Equatable, Sendable {
    case disabled
    case noData
    case normal
    case uncertain
    case alert
}

struct BudgetMetric: Equatable, Sendable {
    let cost: Double?
    let limit: Double
    let updatedAt: Date?
    let unknownPricingModels: [String]
    let threshold: Double

    var level: BudgetMetricLevel {
        guard limit.isFinite, limit > 0 else { return .disabled }
        guard let cost, cost.isFinite else { return .noData }
        if cost >= limit * threshold { return .alert }
        return unknownPricingModels.isEmpty ? .normal : .uncertain
    }

    var isAlerting: Bool { level == .alert }

    /// Unknown-priced usage is orthogonal to the threshold state. A budget can
    /// be over its limit and still be understated because part of its usage is
    /// not priced.
    var hasUnknownPricing: Bool { !unknownPricingModels.isEmpty }

    var isUncertain: Bool { level == .uncertain }

    var progress: Double? {
        guard limit.isFinite, limit > 0, let cost, cost.isFinite else { return nil }
        return min(max(cost / limit, 0), 1)
    }
}

struct BudgetStatus: Equatable, Sendable {
    static let alertThreshold = MonitorSettings.defaultBudgetAlertThreshold

    let daily: BudgetMetric
    let monthly: BudgetMetric

    var isAlerting: Bool { daily.isAlerting || monthly.isAlerting }

    var hasUncertainPricing: Bool {
        daily.hasUnknownPricing || monthly.hasUnknownPricing
    }

    var needsAttention: Bool { isAlerting || hasUncertainPricing }

    var unknownPricingModels: [String] {
        Array(Set(daily.unknownPricingModels + monthly.unknownPricingModels)).sorted()
    }

    static func evaluate(
        snapshot: UsageSnapshot,
        monthlySnapshot: MonthlyBudgetSnapshot?,
        settings: MonitorSettings,
        now: Date,
        calendar: Calendar = .current
    ) -> BudgetStatus {
        let dailyUsage = snapshot.todayUsage(relativeTo: now)
        let currentMonth = MonthlyBudgetSnapshot.monthPeriod(for: now, calendar: calendar)
        let monthlyUsage = monthlySnapshot?.month == currentMonth && monthlySnapshot?.hasData == true
            ? monthlySnapshot
            : nil
        let monthlyResolution = MonthlyCostResolver.resolve(
            snapshot: snapshot,
            monthlySnapshot: monthlyUsage,
            now: now,
            calendar: calendar
        )
        let alertThreshold = MonitorSettings.validBudgetAlertThreshold(settings.budgetAlertThreshold)
        let monthlyUnknownPricingModels: [String]
        switch monthlyResolution?.source {
        case .liveUsage:
            monthlyUnknownPricingModels = snapshot.liveUnknownPricingModels
        case .realtimeProjection, .calibratedSnapshot:
            guard let monthlyUsage else {
                monthlyUnknownPricingModels = []
                break
            }
            guard monthlyUsage.pricingUpdatedAt == snapshot.pricingUpdatedAt,
                  monthlyUsage.customPricingRevision == snapshot.customPricingRevision,
                  monthlyUsage.modelCatalogRevision == snapshot.modelCatalogRevision else {
                monthlyUnknownPricingModels = monthlyUsage.pricingBasisPreserved
                    ? monthlyUsage.liveUnknownPricingModels
                    : []
                break
            }
            monthlyUnknownPricingModels = monthlyUsage.projectedUnknownPricingModels(
                using: snapshot,
                now: now,
                calendar: calendar
            )
        case nil:
            monthlyUnknownPricingModels = []
        }

        let currentDay = MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar)
        let dailyUnknownPricingModels: [String]
        if snapshot.dailyModels.isEmpty {
            // Legacy snapshots may not have per-day model rows. Preserve their
            // denormalized warning rather than claiming the day is complete.
            dailyUnknownPricingModels = dailyUsage == nil ? [] : snapshot.liveUnknownPricingModels
        } else {
            dailyUnknownPricingModels = Array(Set(snapshot.dailyModels
                .filter {
                    $0.period == currentDay
                        && $0.tokens.totalTokens > 0
                        && !$0.hasKnownPricing
                }
                .map(\.name))).sorted()
        }

        return BudgetStatus(
            daily: BudgetMetric(
                cost: dailyUsage?.estimatedCost,
                limit: MonitorSettings.validCostLimit(settings.dailyCostLimit),
                updatedAt: dailyUsage == nil ? nil : snapshot.generatedAt,
                unknownPricingModels: dailyUnknownPricingModels,
                threshold: alertThreshold
            ),
            monthly: BudgetMetric(
                cost: monthlyResolution?.cost,
                limit: MonitorSettings.validCostLimit(settings.monthlyCostLimit),
                updatedAt: monthlyResolution?.updatedAt,
                unknownPricingModels: monthlyUnknownPricingModels,
                threshold: alertThreshold
            )
        )
    }
}

enum MonthlyCostResolutionSource: Equatable, Sendable {
    /// The usage query explicitly covers the current calendar month. This is
    /// the same total shown by the daily-usage section, so it is the preferred
    /// source when available.
    case liveUsage
    /// A whole-month calibration has been adjusted with the latest current-day
    /// usage snapshot.
    case realtimeProjection
    /// The last successful whole-month calibration is the only safe value
    /// available while the live usage query covers a shorter or older range.
    case calibratedSnapshot

    var diagnosticLabel: String {
        switch self {
        case .liveUsage: return "live-usage"
        case .realtimeProjection: return "realtime-projection"
        case .calibratedSnapshot: return "calibrated-snapshot"
        }
    }
}

struct MonthlyCostResolution: Equatable, Sendable {
    let cost: Double
    let updatedAt: Date
    let source: MonthlyCostResolutionSource
}

enum MonthlyCostResolver {
    static func resolve(
        snapshot: UsageSnapshot,
        monthlySnapshot: MonthlyBudgetSnapshot?,
        now: Date,
        calendar: Calendar = .current
    ) -> MonthlyCostResolution? {
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now, calendar: calendar)

        // When the live query already covers the whole calendar month, it is
        // the canonical value for both the budget row and the "本月" summary.
        // This also removes the otherwise unavoidable one-hour discrepancy
        // while the low-frequency monthly cache is catching up.
        if coversCurrentCalendarMonth(snapshot, month: month, now: now, calendar: calendar) {
            return MonthlyCostResolution(
                cost: snapshot.estimatedCost,
                updatedAt: snapshot.generatedAt,
                source: .liveUsage
            )
        }

        guard let monthlySnapshot,
              monthlySnapshot.month == month,
              monthlySnapshot.hasData,
              let cost = monthlySnapshot.projectedCost(using: snapshot, now: now, calendar: calendar) else {
            return nil
        }

        let usesRealtimeProjection = monthlySnapshot.usesRealtimeProjection(
            using: snapshot,
            now: now,
            calendar: calendar
        )
        return MonthlyCostResolution(
            cost: cost,
            updatedAt: usesRealtimeProjection ? snapshot.generatedAt : monthlySnapshot.generatedAt,
            source: usesRealtimeProjection ? .realtimeProjection : .calibratedSnapshot
        )
    }

    private static func coversCurrentCalendarMonth(
        _ snapshot: UsageSnapshot,
        month: String,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard snapshot.hasData,
              snapshot.generatedAt != .distantPast,
              let scope = snapshot.queryScope else {
            return false
        }

        return scope.lookbackDays == MonitorSettings.calendarMonthLookback
            && scope.since == "\(month)-01"
            && scope.until == MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar)
            && scope.timeZone == calendar.timeZone.identifier
    }
}

struct MonthlyBudgetModel: Codable, Equatable, Identifiable, Sendable {
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
        case agent, name, tokens, estimatedCost, hasKnownPricing
        case pricingSource, pricingProviderIDs, pricingTierThreshold, pricingBackendThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        name = try container.decode(String.self, forKey: .name)
        tokens = try container.decode(TokenTotals.self, forKey: .tokens)
        estimatedCost = try container.decode(Double.self, forKey: .estimatedCost)
        hasKnownPricing = try container.decodeIfPresent(Bool.self, forKey: .hasKnownPricing)
            ?? (estimatedCost > 0)
        pricingSource = try container.decodeIfPresent(ModelPricingSource.self, forKey: .pricingSource)
            ?? (hasKnownPricing ? .ccusage : .unknown)
        pricingProviderIDs = PricingProviderIdentity.normalized(
            try container.decodeIfPresent([String].self, forKey: .pricingProviderIDs) ?? []
        )
        pricingTierThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingTierThreshold)
        pricingBackendThreshold = try container.decodeIfPresent(Int64.self, forKey: .pricingBackendThreshold)
    }
}

struct MonthlyBudgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let month: String
    let generatedAt: Date
    let pricingUpdatedAt: Date?
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    /// True when the last trusted monthly result is intentionally retained
    /// while the active catalog has an ambiguous or incomplete record. The
    /// snapshot remains displayable, but it must not be used as a current
    /// realtime projection or treated as a successful reconciliation.
    let pricingBasisPreserved: Bool
    let models: [MonthlyBudgetModel]
    let totalTokens: Int64
    let estimatedCost: Double
    let unknownPricingModels: [String]
    /// The full-month result includes the current day. These two fields let
    /// the UI replace that calibrated current-day value with the latest daily
    /// usage without rescanning the whole month on every refresh.
    let realtimeAnchorDay: String?
    let realtimeAnchorTodayCost: Double?

    var hasData: Bool {
        totalTokens > 0 || estimatedCost > 0 || !models.isEmpty
    }

    var hasRealtimeProjection: Bool {
        realtimeAnchorDay != nil && realtimeAnchorTodayCost != nil
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        month: String,
        generatedAt: Date,
        pricingUpdatedAt: Date?,
        customPricingRevision: String?,
        modelCatalogRevision: String? = nil,
        pricingBasisPreserved: Bool = false,
        models: [MonthlyBudgetModel],
        totalTokens: Int64,
        estimatedCost: Double,
        unknownPricingModels: [String],
        realtimeAnchorDay: String? = nil,
        realtimeAnchorTodayCost: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.month = month
        self.generatedAt = generatedAt
        self.pricingUpdatedAt = pricingUpdatedAt
        self.customPricingRevision = customPricingRevision
        self.modelCatalogRevision = modelCatalogRevision
        self.pricingBasisPreserved = pricingBasisPreserved
        self.models = models
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.unknownPricingModels = unknownPricingModels
        self.realtimeAnchorDay = realtimeAnchorDay
        self.realtimeAnchorTodayCost = realtimeAnchorTodayCost
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case month
        case generatedAt
        case pricingUpdatedAt
        case customPricingRevision
        case modelCatalogRevision
        case pricingBasisPreserved
        case models
        case totalTokens
        case estimatedCost
        case unknownPricingModels
        case realtimeAnchorDay
        case realtimeAnchorTodayCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Monthly budget snapshot schema version \(decodedSchemaVersion) is newer than supported version \(Self.currentSchemaVersion)."
            )
        }

        // Version 1 snapshots remain usable as last-known-good totals. They
        // do not have a realtime anchor, so MonitorStore schedules one
        // reconciliation before enabling the projection path.
        schemaVersion = Self.currentSchemaVersion
        month = try container.decode(String.self, forKey: .month)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        pricingUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .pricingUpdatedAt)
        customPricingRevision = try container.decodeIfPresent(String.self, forKey: .customPricingRevision)
        modelCatalogRevision = try container.decodeIfPresent(String.self, forKey: .modelCatalogRevision)
        pricingBasisPreserved = try container.decodeIfPresent(Bool.self, forKey: .pricingBasisPreserved) ?? false
        models = try container.decodeIfPresent([MonthlyBudgetModel].self, forKey: .models) ?? []
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        unknownPricingModels = try container.decodeIfPresent([String].self, forKey: .unknownPricingModels) ?? []
        realtimeAnchorDay = try container.decodeIfPresent(String.self, forKey: .realtimeAnchorDay)
        realtimeAnchorTodayCost = try container.decodeIfPresent(Double.self, forKey: .realtimeAnchorTodayCost)
    }

    func markingPricingBasisPreserved() -> MonthlyBudgetSnapshot {
        guard !pricingBasisPreserved else { return self }
        return MonthlyBudgetSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            month: month,
            generatedAt: generatedAt,
            pricingUpdatedAt: pricingUpdatedAt,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision,
            pricingBasisPreserved: true,
            models: models,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: unknownPricingModels,
            realtimeAnchorDay: realtimeAnchorDay,
            realtimeAnchorTodayCost: realtimeAnchorTodayCost
        )
    }

    static func monthPeriod(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    static func dayPeriod(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func projectedCost(
        using snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Double? {
        guard hasData,
              month == Self.monthPeriod(for: now, calendar: calendar) else {
            return nil
        }

        guard let projection = realtimeProjectionContext(using: snapshot, now: now, calendar: calendar) else {
            // This is also the safe migration fallback for a v1 snapshot. A
            // stale or pre-calibration usage snapshot must not replace the
            // calibrated total with a partial projection.
            return estimatedCost
        }

        let currentDayCost = snapshot.days
            .filter { $0.period == projection.currentDay }
            .reduce(0) { $0 + $1.estimatedCost }
        if projection.currentDay == projection.anchorDay {
            return max(0, estimatedCost - projection.anchorTodayCost + currentDayCost)
        }

        // Once the calendar day advances, the anchored day is part of the
        // historical total. Include every later day visible in the live daily
        // snapshot, then add the current day. The context guard above ensures
        // a scoped snapshot cannot skip an unobserved interval.
        let interveningCost = snapshot.days
            .filter { $0.period > projection.anchorDay && $0.period < projection.currentDay && $0.period.hasPrefix(month) }
            .reduce(0) { $0 + $1.estimatedCost }
        return max(0, estimatedCost + interveningCost + currentDayCost)
    }

    func usesRealtimeProjection(
        using snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard hasData,
              month == Self.monthPeriod(for: now, calendar: calendar) else {
            return false
        }
        return realtimeProjectionContext(using: snapshot, now: now, calendar: calendar) != nil
    }

    private func realtimeProjectionContext(
        using snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar
    ) -> (anchorDay: String, anchorTodayCost: Double, currentDay: String)? {
        guard let realtimeAnchorDay,
              let realtimeAnchorTodayCost,
              snapshot.hasData,
              !pricingBasisPreserved,
              snapshot.generatedAt >= generatedAt,
              // The calibrated total and the live day must use the same
              // pricing basis. A pricing refresh invalidates projection
              // until the low-frequency monthly reconciliation catches up.
              snapshot.pricingUpdatedAt == pricingUpdatedAt,
              snapshot.customPricingRevision == customPricingRevision,
              snapshot.modelCatalogRevision == modelCatalogRevision else {
            return nil
        }

        let currentDay = Self.dayPeriod(for: now, calendar: calendar)
        // A live snapshot from before midnight cannot safely replace the
        // calibrated current-day amount. Keep the full-month result until a
        // usage refresh covering today is available.
        if let snapshotUntil = snapshot.queryScope?.until {
            guard snapshot.queryScope?.timeZone == calendar.timeZone.identifier,
                  snapshotUntil == currentDay else { return nil }
        } else {
            // Legacy snapshots have no query scope. A historical row alone is
            // not proof that today's scan completed; require an explicit
            // current-day row before treating a missing row as zero usage. If
            // the calendar day has advanced, the legacy snapshot also cannot
            // prove that every day between the anchor and today was covered.
            guard currentDay == realtimeAnchorDay,
                  snapshot.days.contains(where: { $0.period == currentDay }) else {
                return nil
            }
        }
        guard currentDay >= realtimeAnchorDay else {
            return nil
        }
        if currentDay > realtimeAnchorDay,
           let snapshotScope = snapshot.queryScope {
            // A short lookback can otherwise skip days between the calibrated
            // anchor and today. Refusing that partial projection is safer than
            // silently undercounting the monthly budget; the next whole-month
            // reconciliation will repair the baseline.
            guard snapshotScope.since <= realtimeAnchorDay else {
                return nil
            }
        }
        return (realtimeAnchorDay, realtimeAnchorTodayCost, currentDay)
    }

    func projectedUnknownPricingModels(
        using snapshot: UsageSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> [String] {
        guard month == Self.monthPeriod(for: now, calendar: calendar) else {
            return liveUnknownPricingModels
        }
        guard realtimeProjectionContext(using: snapshot, now: now, calendar: calendar) != nil else {
            return liveUnknownPricingModels
        }
        let currentDay = Self.dayPeriod(for: now, calendar: calendar)
        let liveUnknownModels = snapshot.dailyModels
            .filter {
                $0.period >= (realtimeAnchorDay ?? currentDay)
                    && $0.period <= currentDay
                    && $0.period.hasPrefix(month + "-")
                    && !$0.hasKnownPricing
                    && $0.tokens.totalTokens > 0
            }
            .map(\.name)
        return Array(Set(liveUnknownPricingModels + liveUnknownModels)).sorted()
    }

    /// Recompute unknown pricing from the monthly model rows. The persisted
    /// array is a compatibility field and may describe an older pricing basis.
    var liveUnknownPricingModels: [String] {
        let usedModels = models.filter { $0.tokens.totalTokens > 0 }
        guard !usedModels.isEmpty else { return unknownPricingModels }
        return Array(Set(usedModels.compactMap { model in
            guard model.tokens.totalTokens > 0, !model.hasKnownPricing else { return nil }
            return model.name
        })).sorted()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isValidMonth(month),
              totalTokens >= 0,
              estimatedCost.isFinite,
              estimatedCost >= 0 else {
            throw ValidationError.invalidValue
        }

        guard (realtimeAnchorDay == nil) == (realtimeAnchorTodayCost == nil) else {
            throw ValidationError.invalidValue
        }
        if let realtimeAnchorDay,
           let realtimeAnchorTodayCost {
            guard Self.isValidDay(realtimeAnchorDay),
                  realtimeAnchorDay.hasPrefix(month + "-"),
                  realtimeAnchorTodayCost.isFinite,
                  realtimeAnchorTodayCost >= 0,
                  realtimeAnchorTodayCost <= estimatedCost else {
                throw ValidationError.invalidValue
            }
        }

        let identifiers = models.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw ValidationError.duplicateIdentifiers
        }

        let tokenValues = models.flatMap { [
            $0.tokens.inputTokens,
            $0.tokens.outputTokens,
            $0.tokens.cacheCreationTokens,
            $0.tokens.cacheReadTokens
        ] }
        guard tokenValues.allSatisfy({ $0 >= 0 }),
              models.allSatisfy({ $0.estimatedCost.isFinite && $0.estimatedCost >= 0 }) else {
            throw ValidationError.invalidValue
        }
        guard models.map(\.tokens).allSatisfy(\.hasRepresentableTotal) else {
            throw ValidationError.invalidValue
        }
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidValue
        case duplicateIdentifiers

        var errorDescription: String? {
            switch self {
            case .invalidValue: return "Monthly budget snapshot contains an invalid value."
            case .duplicateIdentifiers: return "Monthly budget snapshot contains duplicate models."
            }
        }
    }

    private static func isValidMonth(_ value: String) -> Bool {
        guard value.count == 7 else { return false }
        let characters = Array(value)
        guard characters[4] == "-",
              characters.enumerated().allSatisfy({ index, character in
                index == 4 || character.isNumber
            }) else {
            return false
        }
        guard let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[5..<7])) else {
            return false
        }
        return isValidDate(year: year, month: month, day: 1)
    }

    static func isValidDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let characters = Array(value)
        guard characters[4] == "-",
              characters[7] == "-",
              characters.enumerated().allSatisfy({ index, character in
                index == 4 || index == 7 || character.isNumber
            }) else {
            return false
        }
        guard let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[5..<7])),
              let day = Int(String(characters[8..<10])) else {
            return false
        }
        return isValidDate(year: year, month: month, day: day)
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        guard year > 0, (1...12).contains(month), day > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }
}
