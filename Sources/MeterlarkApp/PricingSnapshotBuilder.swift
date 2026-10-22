import Foundation

extension UsageSnapshotBuilder {
    /// Pricing-aware overload. The original overload remains available for
    /// decoding-only callers and legacy fixtures that intentionally model raw
    /// ccusage semantics.
    static func make(
        from response: CCUsageResponse,
        pricingUpdatedAt: Date?,
        queryScope: UsageQueryScope? = nil,
        pricingContext: PricingResolutionContext
    ) -> UsageSnapshot {
        makeResult(
            from: response,
            pricingUpdatedAt: pricingUpdatedAt,
            queryScope: queryScope,
            pricingContext: pricingContext
        ).snapshot
    }

    static func makeResult(
        from response: CCUsageResponse,
        pricingUpdatedAt: Date?,
        queryScope: UsageQueryScope? = nil,
        pricingContext: PricingResolutionContext
    ) -> UsageSnapshotBuildResult {
        let resolver = PricingResolver(context: pricingContext)
        var days: [DailyUsage] = []
        var dailyModels: [String: DailyModelUsage] = [:]
        var agents: [String: AgentUsage] = [:]
        var models: [String: ModelUsage] = [:]
        var assessment = PricingAssessmentContext.empty

        for row in response.daily {
            guard let period = row.period ?? (row.agent == "all" ? "Today" : nil) else { continue }
            let rowModels = row.agents?.flatMap { $0.modelBreakdowns ?? [] } ?? row.modelBreakdowns ?? []
            let resolvedRows = rowModels.map { modelRow in
                let tokens = Self.tokens(for: modelRow)
                let resolution = resolver.resolve(
                    modelName: modelRow.modelName ?? "",
                    tokens: tokens,
                    backendCost: modelRow.cost
                )
                if let modelName = modelRow.modelName, !modelName.isEmpty {
                    assessment.record(
                        modelName: modelName,
                        outcome: resolution.outcome,
                        catalogGap: resolution.catalogGap
                    )
                }
                return (modelRow, tokens, resolution)
            }
            let rowCost = resolvedRows.reduce(0) { partial, item in
                partial + (item.2.hasKnownPricing ? item.2.cost : 0)
            }
            let dayTokens = TokenTotals(
                inputTokens: row.inputTokens ?? 0,
                outputTokens: row.outputTokens ?? 0,
                cacheCreationTokens: row.cacheCreationTokens ?? 0,
                cacheReadTokens: row.cacheReadTokens ?? 0
            )
            days.append(DailyUsage(
                period: period,
                tokens: dayTokens,
                estimatedCost: rowModels.isEmpty ? max(0, row.totalCost ?? 0) : rowCost
            ))

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
                var agent = agents[agentName] ?? AgentUsage(
                    name: agentName,
                    tokens: .zero,
                    estimatedCost: 0
                )
                agent.tokens += TokenTotals(
                    inputTokens: agentRow.inputTokens ?? 0,
                    outputTokens: agentRow.outputTokens ?? 0,
                    cacheCreationTokens: agentRow.cacheCreationTokens ?? 0,
                    cacheReadTokens: agentRow.cacheReadTokens ?? 0
                )

                let agentModels = agentRow.modelBreakdowns ?? []
                for modelRow in agentModels {
                    guard let modelName = modelRow.modelName, !modelName.isEmpty else { continue }
                    let modelTokens = Self.tokens(for: modelRow)
                    let resolution = resolver.resolve(
                        modelName: modelName,
                        tokens: modelTokens,
                        backendCost: modelRow.cost
                    )
                    assessment.record(
                        modelName: modelName,
                        outcome: resolution.outcome,
                        catalogGap: resolution.catalogGap
                    )
                    if resolution.hasKnownPricing {
                        agent.estimatedCost += resolution.cost
                    }

                    let modelKey = "\(agentName)::\(modelName)"
                    var model = models[modelKey] ?? ModelUsage(
                        agent: agentName,
                        name: modelName,
                        tokens: .zero,
                        estimatedCost: 0,
                        hasKnownPricing: true
                    )
                    model.tokens += modelTokens
                    model.hasKnownPricing = model.hasKnownPricing && resolution.hasKnownPricing
                    if resolution.hasKnownPricing {
                        model.estimatedCost += resolution.cost
                        let source = PricingSourceAggregation.combine(
                            model.pricingSource,
                            resolution.source
                        )
                        model.pricingSource = source
                        model.pricingProviderIDs = source == .remote || source == .mixed
                            ? PricingSourceAggregation.providerIDs(model.pricingProviderIDs, resolution.pricingProviderIDs)
                            : []
                        model.pricingTierThreshold = PricingSourceAggregation.mergedThreshold(
                            model.pricingTierThreshold,
                            resolution.tierThreshold,
                            source: source
                        )
                        model.pricingBackendThreshold = PricingSourceAggregation.mergedThreshold(
                            model.pricingBackendThreshold,
                            resolution.backendThreshold,
                            source: source
                        )
                    } else {
                        model.pricingSource = .unknown
                        model.pricingProviderIDs = []
                        model.pricingTierThreshold = nil
                        model.pricingBackendThreshold = nil
                    }
                    models[modelKey] = model

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
                    dailyModel.hasKnownPricing = dailyModel.hasKnownPricing && resolution.hasKnownPricing
                    if resolution.hasKnownPricing {
                        dailyModel.estimatedCost += resolution.cost
                        let source = PricingSourceAggregation.combine(
                            dailyModel.pricingSource,
                            resolution.source
                        )
                        dailyModel.pricingSource = source
                        dailyModel.pricingProviderIDs = source == .remote || source == .mixed
                            ? PricingSourceAggregation.providerIDs(dailyModel.pricingProviderIDs, resolution.pricingProviderIDs)
                            : []
                        dailyModel.pricingTierThreshold = PricingSourceAggregation.mergedThreshold(
                            dailyModel.pricingTierThreshold,
                            resolution.tierThreshold,
                            source: source
                        )
                        dailyModel.pricingBackendThreshold = PricingSourceAggregation.mergedThreshold(
                            dailyModel.pricingBackendThreshold,
                            resolution.backendThreshold,
                            source: source
                        )
                    } else {
                        dailyModel.pricingSource = .unknown
                        dailyModel.pricingProviderIDs = []
                        dailyModel.pricingTierThreshold = nil
                        dailyModel.pricingBackendThreshold = nil
                    }
                    dailyModels[dailyKey] = dailyModel
                }
                agents[agentName] = agent
            }
        }

        let totalTokens = days.reduce(TokenTotals.zero) { $0 + $1.tokens }
        let estimatedCost = days.reduce(0) { $0 + $1.estimatedCost }
        let unknownModels = Set(
            models.values
                .filter { !$0.hasKnownPricing && $0.tokens.totalTokens > 0 }
                .map(\.name)
        )
        let sortedModels = models.values.sorted { $0.estimatedCost > $1.estimatedCost }
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: pricingUpdatedAt,
            queryScope: queryScope,
            modelCatalogRevision: pricingContext.remoteCatalogRevision,
            days: days.sorted { $0.period < $1.period },
            dailyModels: dailyModels.values.sorted { $0.id < $1.id },
            agents: agents.values.sorted { $0.estimatedCost > $1.estimatedCost },
            models: sortedModels,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: unknownModels.sorted(),
            pricingSource: PricingSourceAggregation.aggregate(for: sortedModels)
        )
        return UsageSnapshotBuildResult(snapshot: snapshot, pricingAssessment: assessment)
    }

    static func makeMonthlyBudget(
        from response: CCUsageResponse,
        month: String,
        pricingUpdatedAt: Date?,
        customPricingRevision: String?,
        modelCatalogRevision: String? = nil,
        realtimeAnchorDay: String? = nil,
        pricingContext: PricingResolutionContext
    ) -> MonthlyBudgetSnapshot {
        makeMonthlyBudgetResult(
            from: response,
            month: month,
            pricingUpdatedAt: pricingUpdatedAt,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision,
            realtimeAnchorDay: realtimeAnchorDay,
            pricingContext: pricingContext
        ).snapshot
    }

    static func makeMonthlyBudgetResult(
        from response: CCUsageResponse,
        month: String,
        pricingUpdatedAt: Date?,
        customPricingRevision: String?,
        modelCatalogRevision: String? = nil,
        realtimeAnchorDay: String? = nil,
        pricingContext: PricingResolutionContext
    ) -> MonthlyBudgetBuildResult {
        let resolver = PricingResolver(context: pricingContext)
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
        var assessment = PricingAssessmentContext.empty

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
                Self.saturatingAdd(partial, Self.tokenTotal(for: agent))
            }

            let modelRows = agentRows.flatMap { agent in
                (agent.modelBreakdowns ?? []).map {
                    (agent: agent.agent ?? row.agent ?? "unknown", model: $0)
                }
            }
            if modelRows.isEmpty {
                fallbackCost += max(0, row.totalCost ?? 0)
                continue
            }

            sawModelBreakdown = true
            for (agentName, modelRow) in modelRows {
                guard let modelName = modelRow.modelName, !modelName.isEmpty else { continue }
                let key = "\(agentName)::\(modelName)"
                let modelTokens = Self.tokens(for: modelRow)
                let resolution = resolver.resolve(
                    modelName: modelName,
                    tokens: modelTokens,
                    backendCost: modelRow.cost
                )
                assessment.record(
                    modelName: modelName,
                    outcome: resolution.outcome,
                    catalogGap: resolution.catalogGap
                )
                var model = models[key] ?? MonthlyBudgetModel(
                    agent: agentName,
                    name: modelName,
                    tokens: .zero,
                    estimatedCost: 0,
                    hasKnownPricing: true
                )
                model.tokens += modelTokens
                model.hasKnownPricing = model.hasKnownPricing && resolution.hasKnownPricing
                if resolution.hasKnownPricing {
                    model.estimatedCost += resolution.cost
                    let source = PricingSourceAggregation.combine(
                        model.pricingSource,
                        resolution.source
                    )
                    model.pricingSource = source
                    model.pricingProviderIDs = source == .remote || source == .mixed
                        ? PricingSourceAggregation.providerIDs(model.pricingProviderIDs, resolution.pricingProviderIDs)
                        : []
                    model.pricingTierThreshold = PricingSourceAggregation.mergedThreshold(
                        model.pricingTierThreshold,
                        resolution.tierThreshold,
                        source: source
                    )
                    model.pricingBackendThreshold = PricingSourceAggregation.mergedThreshold(
                        model.pricingBackendThreshold,
                        resolution.backendThreshold,
                        source: source
                    )
                } else {
                    model.pricingSource = .unknown
                    model.pricingProviderIDs = []
                    model.pricingTierThreshold = nil
                    model.pricingBackendThreshold = nil
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
            sortedModels.reduce(0) { Self.saturatingAdd($0, $1.tokens.totalTokens) }
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
            let dailyCost = Self.dailyCost(
                for: realtimeAnchorDay,
                in: response.daily,
                resolver: resolver,
                assessment: &assessment
            )
            realtimeAnchorTodayCost = dailyCost <= estimatedCost ? dailyCost : nil
        } else {
            realtimeAnchorTodayCost = nil
        }
        let validRealtimeAnchorDay = realtimeAnchorTodayCost == nil ? nil : realtimeAnchorDay

        let snapshot = MonthlyBudgetSnapshot(
            month: month,
            generatedAt: Date(),
            pricingUpdatedAt: pricingUpdatedAt,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision,
            models: sortedModels,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            unknownPricingModels: Array(Set(unknownModels)).sorted(),
            realtimeAnchorDay: validRealtimeAnchorDay,
            realtimeAnchorTodayCost: realtimeAnchorTodayCost
        )
        return MonthlyBudgetBuildResult(snapshot: snapshot, pricingAssessment: assessment)
    }

    private static func dailyCost(
        for period: String,
        in rows: [CCUsageDailyRow],
        resolver: PricingResolver,
        assessment: inout PricingAssessmentContext
    ) -> Double {
        let matchingRows = rows.filter { $0.period == period }
        guard !matchingRows.isEmpty else { return 0 }
        let rowsToAggregate: [CCUsageDailyRow]
        if let aggregate = matchingRows.first(where: { $0.agent == "all" }) {
            rowsToAggregate = [aggregate]
        } else {
            rowsToAggregate = matchingRows
        }

        return rowsToAggregate.reduce(0) { partial, row in
            let modelRows: [CCUsageModelRow]
            if let agents = row.agents, !agents.isEmpty {
                modelRows = agents.flatMap { $0.modelBreakdowns ?? [] }
            } else {
                modelRows = row.modelBreakdowns ?? []
            }
            guard !modelRows.isEmpty else { return partial + max(0, row.totalCost ?? 0) }
            let knownCost = modelRows.reduce(0) { cost, modelRow in
                let modelName = modelRow.modelName ?? ""
                let resolution = resolver.resolve(
                    modelName: modelName,
                    tokens: tokens(for: modelRow),
                    backendCost: modelRow.cost
                )
                if !modelName.isEmpty {
                    assessment.record(
                        modelName: modelName,
                        outcome: resolution.outcome,
                        catalogGap: resolution.catalogGap
                    )
                }
                return cost + (resolution.hasKnownPricing ? resolution.cost : 0)
            }
            return partial + knownCost
        }
    }

    private static func tokens(for row: CCUsageModelRow) -> TokenTotals {
        TokenTotals(
            inputTokens: row.inputTokens ?? 0,
            outputTokens: row.outputTokens ?? 0,
            cacheCreationTokens: row.cacheCreationTokens ?? 0,
            cacheReadTokens: row.cacheReadTokens ?? 0
        )
    }

    private static func tokenTotal(for row: CCUsageAgentRow) -> Int64 {
        if let totalTokens = row.totalTokens, totalTokens >= 0 { return totalTokens }
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
