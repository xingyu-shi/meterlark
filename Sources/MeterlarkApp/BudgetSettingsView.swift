import AppKit
import SwiftUI

struct BudgetSettingsView: View {
    @ObservedObject var store: MonitorStore
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var dailyBudgetText: String
    @State private var monthlyBudgetText: String
    @State private var thresholdPercent: Double

    init(store: MonitorStore, onCancel: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.store = store
        self.onCancel = onCancel
        self.onSave = onSave
        _dailyBudgetText = State(initialValue: Self.inputValue(store.settings.dailyCostLimit))
        _monthlyBudgetText = State(initialValue: Self.inputValue(store.settings.monthlyCostLimit))
        _thresholdPercent = State(initialValue: MonitorSettings.validBudgetAlertThreshold(store.settings.budgetAlertThreshold) * 100)
    }

    private var copy: L10n { L10n(language: store.settings.language) }
    private var textSize: InterfaceTextSize { store.settings.interfaceTextSize }

    private var dailyLimit: Double? {
        MonitorSettings.parseCostLimit(dailyBudgetText)
    }

    private var monthlyLimit: Double? {
        MonitorSettings.parseCostLimit(monthlyBudgetText)
    }

    private var isDraftValid: Bool {
        dailyLimit != nil && monthlyLimit != nil
    }

    private var normalizedThreshold: Double {
        MonitorSettings.validBudgetAlertThreshold(thresholdPercent / 100)
    }

    private var thresholdLabel: String {
        MonitorSettings.budgetAlertThresholdPercentage(normalizedThreshold)
    }

    private var previewLimit: Double {
        let configuredLimits = [dailyLimit ?? 0, monthlyLimit ?? 0]
        let largestLimit = configuredLimits.max() ?? 0
        return largestLimit > 0 ? largestLimit : 100
    }

    private var previewNormalCost: Double {
        previewLimit * max(normalizedThreshold - 0.1, 0)
    }

    private var previewAlertCost: Double {
        previewLimit * normalizedThreshold
    }

    var body: some View {
        AppWindowShell(
            title: copy.budgetSettingsTitle,
            subtitle: copy.budgetSettingsSubtitle,
            mark: .symbol("bell.badge.fill"),
            interfaceTextSize: textSize,
            appearance: store.settings.appearance,
            surfaceStyle: store.settings.surfaceStyle,
            width: textSize.budgetSettingsWidth,
            height: textSize.budgetSettingsHeight,
            contentPadding: 0
        ) {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        limitsCard
                        thresholdCard
                        previewCard
                    }
                    .padding(22)
                }
                Divider()
                footer
            }
        }
    }

    private var limitsCard: some View {
        AppWindowCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(copy.budgetInputMessage)
                    .appFont(.caption)
                    .foregroundStyle(BudgetSettingsColors.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 13)
                    .padding(.bottom, 4)

                BudgetSettingsInputRow(
                    title: copy.dailyBudget,
                    symbol: "sun.max",
                    placeholder: copy.notConfigured,
                    text: $dailyBudgetText
                )
                Divider().padding(.leading, 48)
                BudgetSettingsInputRow(
                    title: copy.monthlyBudget,
                    symbol: "calendar",
                    placeholder: copy.notConfigured,
                    text: $monthlyBudgetText
                )
            }
        }
    }

    private var thresholdCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Label(copy.budgetAlertThreshold, systemImage: "bell")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(BudgetSettingsColors.primary)
                    Spacer()
                    Text("\(thresholdLabel)%")
                        .appFont(.bodyAlert)
                        .foregroundStyle(BudgetSettingsColors.alert)
                        .contentTransition(.numericText())
                }
                Slider(value: $thresholdPercent, in: 1...100, step: 1)
                    .tint(BudgetSettingsColors.alert)
                HStack {
                    Text("1%")
                    Spacer()
                    Text("100%")
                }
                .appFont(.metadata)
                .foregroundStyle(BudgetSettingsColors.secondary)
                Text(copy.budgetAlertThresholdInputMessage)
                    .appFont(.caption)
                    .foregroundStyle(BudgetSettingsColors.secondary)
            }
        }
    }

    private var previewCard: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text(copy.budgetPreview)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(BudgetSettingsColors.primary)
                    Spacer()
                    Text(copy.budgetAlertLabel(thresholdLabel))
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(BudgetSettingsColors.secondary)
                }
                Text(copy.budgetPreviewExample)
                    .appFont(.caption)
                    .foregroundStyle(BudgetSettingsColors.secondary)
                BudgetPreviewRow(
                    title: copy.budgetPreviewNormal,
                    cost: previewNormalCost,
                    limit: previewLimit,
                    alerting: false
                )
                BudgetPreviewRow(
                    title: copy.budgetPreviewAlert,
                    cost: previewAlertCost,
                    limit: previewLimit,
                    alerting: true
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isDraftValid {
                Label(copy.invalidBudgetMessage, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundStyle(BudgetSettingsColors.alert)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(copy.cancel) {
                onCancel()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            Button(copy.save) {
                saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isDraftValid)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private func saveDraft() {
        guard let dailyLimit, let monthlyLimit else { return }
        store.setBudgetSettings(
            dailyCostLimit: dailyLimit,
            monthlyCostLimit: monthlyLimit,
            budgetAlertThreshold: normalizedThreshold
        )
        onSave()
    }

    private static func inputValue(_ value: Double) -> String {
        value > 0 && value.isFinite ? String(value) : ""
    }
}

private struct BudgetSettingsInputRow: View {
    let title: String
    let symbol: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .appFont(.captionEmphasis)
                .foregroundStyle(BudgetSettingsColors.secondary)
                .frame(width: 24)
            Text(title)
                .appFont(.bodyEmphasis)
                .foregroundStyle(BudgetSettingsColors.primary)
            Spacer(minLength: 10)
            HStack(spacing: 4) {
                Text("$")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(BudgetSettingsColors.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 128)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct BudgetPreviewRow: View {
    let title: String
    let cost: Double
    let limit: Double
    let alerting: Bool

    private var progress: Double {
        guard limit > 0, cost.isFinite else { return 0 }
        return min(max(cost / limit, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .appFont(.captionEmphasis)
                    .foregroundStyle(alerting ? BudgetSettingsColors.alert : BudgetSettingsColors.secondary)
                Spacer()
                Text("\(Currency.format(cost)) / \(Currency.format(limit))")
                    .appFont(alerting ? .bodyAlert : .bodyEmphasis)
                    .foregroundStyle(alerting ? BudgetSettingsColors.alert : BudgetSettingsColors.primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(BudgetSettingsColors.line.opacity(0.35))
                    Capsule()
                        .fill(alerting ? BudgetSettingsColors.alert : BudgetSettingsColors.signal)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 5)
        }
    }
}

private enum BudgetSettingsColors {
    static let window = AppWindowTheme.canvas
    static let panel = AppWindowTheme.panel
    static let primary = AppWindowTheme.primary
    static let secondary = AppWindowTheme.secondary
    static let line = AppWindowTheme.separator
    static let signal = AppWindowTheme.signal
    static let alert = AppWindowTheme.alert
}
