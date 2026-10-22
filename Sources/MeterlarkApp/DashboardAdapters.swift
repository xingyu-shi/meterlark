import Foundation

enum DashboardAdapters {
    static func summaryGrid(snapshot: UsageSnapshot, copy: L10n) -> MetricGridModel {
        let tokens = snapshot.primaryTokens
        let cache = tokens.cacheReadTokens
        let tiles = [
            MetricTileModel(
                id: "today",
                header: DashboardText(copy.today),
                primary: .integer(
                    value: tokens.totalTokens,
                    display: DashboardText(
                        NumberFormat.compact(tokens.totalTokens),
                        accessibilityText: NumberFormat.grouped(tokens.totalTokens)
                    )
                ),
                detail: DashboardText(cache > 0 ? "\(NumberFormat.compact(cache)) \(copy.cacheShort)" : copy.allSources)
            ),
            MetricTileModel(
                id: "input",
                header: DashboardText(copy.input),
                primary: .integer(
                    value: tokens.inputTokens,
                    display: DashboardText(
                        NumberFormat.compact(tokens.inputTokens),
                        accessibilityText: NumberFormat.grouped(tokens.inputTokens)
                    )
                ),
                detail: DashboardText(copy.prompt)
            ),
            MetricTileModel(
                id: "output",
                header: DashboardText(copy.output),
                primary: .integer(
                    value: tokens.outputTokens,
                    display: DashboardText(
                        NumberFormat.compact(tokens.outputTokens),
                        accessibilityText: NumberFormat.grouped(tokens.outputTokens)
                    )
                ),
                detail: DashboardText(copy.generated)
            ),
            MetricTileModel(
                id: "cache-read",
                header: DashboardText(copy.cacheRead),
                primary: .integer(
                    value: tokens.cacheReadTokens,
                    display: DashboardText(
                        NumberFormat.compact(tokens.cacheReadTokens),
                        accessibilityText: NumberFormat.grouped(tokens.cacheReadTokens)
                    )
                ),
                detail: DashboardText(copy.reused)
            )
        ]
        guard let model = MetricGridModel(columns: 2, tiles: tiles) else {
            preconditionFailure("The built-in summary grid must have a valid layout")
        }
        return model
    }

    static func budgetList(
        status: BudgetStatus,
        alertLabel: String,
        copy: L10n
    ) -> ProgressListModel {
        let headerStatus: DashboardStatusBadge?
        if status.isAlerting {
            let text = status.hasUncertainPricing
                ? copy.budgetAlertWithIncompletePricing(alertLabel)
                : alertLabel
            headerStatus = DashboardStatusBadge(
                status: DashboardStatus(
                    kind: .alert,
                    text: DashboardText(text)
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
        } else if status.hasUncertainPricing {
            headerStatus = DashboardStatusBadge(
                status: DashboardStatus(
                    kind: .alert,
                    text: DashboardText(copy.budgetDataIncomplete)
                ),
                systemImage: "questionmark.circle.fill"
            )
        } else {
            headerStatus = nil
        }

        let items = [
            budgetItem(
                id: "daily",
                title: copy.dailyBudget,
                metric: status.daily,
                noDataLabel: copy.noBudgetData,
                copy: copy
            ),
            budgetItem(
                id: "monthly",
                title: copy.monthlyBudget,
                metric: status.monthly,
                noDataLabel: copy.noBudgetData,
                copy: copy
            )
        ]
        let header = ProgressListHeader(
            title: DashboardText(copy.budget),
            trailingStatus: headerStatus
        )
        guard let model = ProgressListModel(header: header, items: items) else {
            preconditionFailure("The built-in budget list must have unique row identifiers")
        }
        return model
    }

    private static func budgetItem(
        id: String,
        title: String,
        metric: BudgetMetric,
        noDataLabel: String,
        copy: L10n
    ) -> ProgressListItemModel {
        let label = DashboardText(title)

        switch metric.level {
        case .disabled:
            return .value(
                ValueItemModel(
                    id: id,
                    label: label,
                    value: DashboardText("—"),
                    status: DashboardStatus(
                        kind: .disabled,
                        text: DashboardText(copy.notConfigured)
                    )
                )
            )
        case .noData:
            let status = DashboardStatus(
                kind: .noData,
                text: DashboardText(noDataLabel)
            )
            if let progress = ProgressUnavailableItemModel(
                id: id,
                label: label,
                maximum: metric.limit,
                message: DashboardText(noDataLabel),
                status: status
            ) {
                return .progressUnavailable(progress)
            }
            return noDataItem(id: id, label: label, message: noDataLabel)
        case .normal, .uncertain, .alert:
            guard let cost = metric.cost, cost.isFinite else {
                return noDataItem(id: id, label: label, message: noDataLabel)
            }
            let isUncertain = metric.hasUnknownPricing
            let status = DashboardStatus(
                kind: metric.isAlerting || isUncertain ? .alert : .normal,
                text: DashboardText(
                    metric.isAlerting
                        ? (isUncertain
                            ? copy.budgetAlertWithIncompletePricing(copy.budgetPreviewAlert)
                            : copy.budgetPreviewAlert)
                        : (isUncertain ? copy.budgetDataIncomplete : copy.budgetPreviewNormal)
                )
            )
            let value = DashboardText(
                "\(Currency.format(cost)) / \(Currency.format(metric.limit))"
            )
            guard let progress = ProgressItemModel(
                id: id,
                label: label,
                current: cost,
                maximum: metric.limit,
                value: value,
                status: status
            ) else {
                return noDataItem(id: id, label: label, message: noDataLabel)
            }
            return .progress(progress)
        }
    }

    private static func noDataItem(
        id: String,
        label: DashboardText,
        message: String
    ) -> ProgressListItemModel {
        let text = DashboardText(message)
        return .status(
            StatusItemModel(
                id: id,
                label: label,
                message: text,
                status: DashboardStatus(kind: .noData, text: text)
            )
        )
    }
}
