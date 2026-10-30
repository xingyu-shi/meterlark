import AppKit
import Charts
import SwiftUI

private extension View {
    func numericValueTransition<Value: Equatable>(value: Value) -> some View {
        contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.55), value: value)
    }
}

struct DashboardPreviewView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var draft: DashboardLayoutDraft
    let onHeightChange: (Double) -> Void

    var body: some View {
        MonitorPopover(
            store: store,
            layoutOverride: draft.layout,
            popoverHeightOverride: draft.popoverHeight,
            showsSettingsMenu: false,
            editingDraft: draft,
            onHeightChange: onHeightChange
        )
    }
}

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore
    let appUpdater: AppUpdater?
    let layoutOverride: DashboardLayout?
    let popoverHeightOverride: Double?
    let showsSettingsMenu: Bool
    let editingDraft: DashboardLayoutDraft?
    let onHeightChange: ((Double) -> Void)?
    @State private var chartMetric: ChartMetric = .tokens
    @State private var chartGrouping: ChartGrouping = .model
    @State private var showAllModels = false
    @State private var isDatePinned = false
    @State private var isNotificationFeedPresented = false
    @State private var measuredContentHeight: Double?
    @State private var maximumVisibleHeight: Double?
    @StateObject private var componentDrag = DashboardPreviewDragState()

    init(
        store: MonitorStore,
        appUpdater: AppUpdater? = nil,
        layoutOverride: DashboardLayout? = nil,
        popoverHeightOverride: Double? = nil,
        showsSettingsMenu: Bool = true,
        editingDraft: DashboardLayoutDraft? = nil,
        onHeightChange: ((Double) -> Void)? = nil
    ) {
        self.store = store
        self.appUpdater = appUpdater
        self.layoutOverride = layoutOverride
        self.popoverHeightOverride = popoverHeightOverride
        self.showsSettingsMenu = showsSettingsMenu
        self.editingDraft = editingDraft
        self.onHeightChange = onHeightChange
    }

    private var copy: L10n { L10n(language: store.settings.language) }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: shouldShowScrollIndicator) {
            VStack(alignment: .leading, spacing: CGFloat(store.settings.interfaceTextSize.sectionSpacing)) {
                header
                if let appUpdater {
                    AppUpdateNotice(updater: appUpdater, copy: copy)
                }
                ForEach(store.visibleDashboardComponents(for: layoutOverride)) { component in
                    if let editingDraft {
                        EditableDashboardComponent(component: component, draft: editingDraft, drag: componentDrag, copy: copy) {
                            dashboardComponentView(component)
                        }
                    } else {
                        dashboardComponentView(component)
                    }
                }
                footer
            }
            .coordinateSpace(name: DashboardPreviewDragState.coordinateSpace)
            .onPreferenceChange(DashboardComponentFramesKey.self) { frames in
                if componentDrag.frames != frames { componentDrag.frames = frames }
            }
            .padding(CGFloat(store.settings.interfaceTextSize.contentPadding))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PopoverContentHeightKey.self,
                        value: ceil(geometry.size.height)
                    )
                }
            }
        }
        .frame(
            width: CGFloat(store.settings.interfaceTextSize.popoverWidth),
            height: CGFloat(resolvedPopoverHeight),
            alignment: .top
        )
        .background(AppSurfaceBackground(style: store.settings.surfaceStyle))
        .background(WindowAppearanceBridge(
            appearance: store.settings.appearance,
            surfaceStyle: store.settings.surfaceStyle
        ))
        .preferredColorScheme(preferredColorScheme)
        .appInterfaceTextSize(store.settings.interfaceTextSize)
        .environment(\.appSurfaceStyle, store.settings.surfaceStyle)
        .background(PopoverWindowSizer(
            // The dashboard layout preview window is resized by its owner.
            windowHeight: onHeightChange == nil ? resolvedPopoverHeight : nil
        ) { height in
            if maximumVisibleHeight != height {
                maximumVisibleHeight = height
            }
        })
        .onPreferenceChange(PopoverContentHeightKey.self) { height in
            if height > 0, height.isFinite, measuredContentHeight != Double(height) {
                measuredContentHeight = Double(height)
            }
        }
        .onChange(of: resolvedPopoverHeight) { height in onHeightChange?(height) }
    }

    private var resolvedPopoverHeight: Double {
        store.effectivePopoverHeight(
            for: layoutOverride,
            storedHeight: popoverHeightOverride,
            contentHeight: measuredContentHeight,
            maximumVisibleHeight: maximumVisibleHeight
        )
    }

    private var shouldShowScrollIndicator: Bool {
        (measuredContentHeight ?? store.effectivePopoverHeight(
            for: layoutOverride,
            storedHeight: MonitorSettings.compactPopoverHeight
        )) > resolvedPopoverHeight + 1
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                BrandMark(size: 23)
                Text(store.primaryCostTitle)
                    .appFont(.display)
                    .foregroundStyle(
                        store.budgetStatus.isAlerting
                            ? Color.alert
                            : (store.budgetStatus.hasUncertainPricing ? Color.warning : Color.bone)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .numericValueTransition(value: store.primaryCostTitle)
                    .animation(.easeOut(duration: 0.2), value: store.budgetStatus.needsAttention)
                    .accessibilityLabel("\(copy.apiEquivalentEstimate), \(store.primaryCostTitle)")
                Spacer()
                statusMark
                if store.settings.notificationFeedEnabled {
                    NotificationBellButton(
                        store: store,
                        isPresented: $isNotificationFeedPresented
                    )
                }
                if showsSettingsMenu {
                    settingsMenu
                }
            }
            HStack(alignment: .center, spacing: 6) {
                Text(copy.apiEquivalentEstimate)
                    .appFont(.caption)
                    .foregroundStyle(Color.muted)
                    .lineLimit(1)
                PricingStatusBadge(
                    snapshot: store.snapshot,
                    unknownPricingModels: store.budgetStatus.unknownPricingModels,
                    pricingIsStale: store.pricingStatusIsStale(relativeTo: Date()),
                    pricingComposition: store.pricingCatalogComposition,
                    pricingProviderDisplayNames: store.modelCatalogProviderDisplayNames,
                    onUpdatePricing: store.updatePricingNow,
                    language: store.settings.language
                )
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .appFont(.metadataEmphasis)
                    lastUpdatedLabel
                }
                .appFont(.caption)
                .foregroundStyle(Color.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            if case let .failed(message) = store.phase {
                Text(message)
                    .appFont(.caption)
                    .foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .zIndex(100)
    }

    private var statusMark: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.phase.isHealthy ? Color.signal : Color.warning)
                .frame(width: 7, height: 7)
            Text(store.statusText)
                .appFont(.metadataEmphasis)
                .foregroundStyle(store.phase.isHealthy ? Color.signal : Color.warning)
        }
        .help(copy.statusHelp)
    }

    @ViewBuilder
    private func dashboardComponentView(_ component: DashboardLayoutComponent) -> some View {
        switch component.kind {
        case .builtIn(.summary):
            let model = DashboardAdapters.summaryGrid(snapshot: store.snapshot, copy: copy)
            let columns = store.dashboardComponentColumns(for: component, layout: layoutOverride) ?? model.columns
            MetricGrid(model: MetricGridModel(columns: columns, tiles: model.tiles) ?? model)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .builtIn(.budget):
            budgetSection
        case .builtIn(.daily):
            dailySection
        case .builtIn(.modelCatalog):
            ModelCatalogDashboardView(store: store)
        case let .pluginBlock(pluginID, blockID, _, _, _):
            if let snapshot = store.pluginStates.first(where: { $0.id == pluginID }) {
                PluginDashboardComponentView(
                    snapshot: snapshot,
                    blockID: blockID,
                    title: component.title,
                    columns: store.dashboardComponentColumns(for: component, layout: layoutOverride),
                    language: store.settings.language
                )
            }
        }
    }

    @ViewBuilder
    private var lastUpdatedLabel: some View {
        if store.snapshot.generatedAt == .distantPast {
            Text(store.lastUpdatedText)
                .numericValueTransition(value: store.lastUpdatedText)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(copy.updated) \(store.lastUpdatedText(relativeTo: context.date))")
                    .numericValueTransition(value: store.lastUpdatedText(relativeTo: context.date))
            }
        }
    }

    @ViewBuilder
    private var pricingStatusLabel: some View {
        if store.snapshot.pricingUpdatedAt == nil {
            Text(store.pricingStatusText)
                .foregroundStyle(Color.muted)
                .numericValueTransition(value: store.pricingStatusText)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(store.pricingStatusText(relativeTo: context.date))
                    .foregroundStyle(store.pricingStatusIsStale(relativeTo: context.date) ? Color.warning : Color.muted)
                    .numericValueTransition(value: store.pricingStatusText(relativeTo: context.date))
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Section(copy.generalSettings) {
                Toggle(isOn: Binding(
                    get: { store.launchAtLoginEnabled },
                    set: { store.setLaunchAtLogin($0) }
                )) {
                    Label(launchAtLoginLabel, systemImage: "power")
                }
            }

            if let appUpdater {
                AppUpdateMenu(updater: appUpdater, copy: copy)
            }

            Section(copy.usageSettings) {
                Picker(selection: Binding(
                    get: { store.settings.lookbackDays },
                    set: { store.setLookbackDays($0) }
                )) {
                    ForEach(MonitorSettings.allowedLookbackDays, id: \.self) { days in
                        Text(lookbackLabel(days)).tag(days)
                    }
                } label: {
                    Label(settingValue(copy.lookback, lookbackLabel(store.settings.lookbackDays)), systemImage: "calendar")
                }
                .pickerStyle(.menu)
            }

            Section(copy.refreshSettings) {
                Picker(selection: Binding(
                    get: { store.settings.refreshInterval },
                    set: { store.setRefreshInterval($0) }
                )) {
                    ForEach(MonitorSettings.allowedIntervals, id: \.self) { interval in
                        Text(intervalLabel(interval)).tag(interval)
                    }
                } label: {
                    Label(settingValue(copy.usageRefreshInterval, intervalLabel(store.settings.refreshInterval)), systemImage: "arrow.clockwise")
                }
                .pickerStyle(.menu)
                .help(copy.usageRefreshIntervalHelp)
                Picker(selection: Binding(
                    get: { store.settings.sourceVerificationMode },
                    set: { store.setSourceVerificationMode($0) }
                )) {
                    ForEach(SourceVerificationMode.allCases) { mode in
                        Text(sourceVerificationModeLabel(mode)).tag(mode)
                    }
                } label: {
                    Label(
                        settingValue(copy.sourceVerificationMode, sourceVerificationModeLabel(store.settings.sourceVerificationMode)),
                        systemImage: "waveform.path.ecg"
                    )
                }
                .pickerStyle(.menu)
                .help(copy.sourceVerificationModeHelp)
                if store.settings.sourceVerificationMode == .periodicFingerprint {
                    Picker(selection: Binding(
                        get: { store.settings.fingerprintCheckInterval },
                        set: { store.setFingerprintCheckInterval($0) }
                    )) {
                        ForEach(fingerprintIntervalOptions, id: \.self) { interval in
                            Text(fingerprintIntervalLabel(interval)).tag(interval)
                        }
                    } label: {
                        Label(
                            settingValue(copy.fingerprintCheckInterval, fingerprintIntervalLabel(store.settings.fingerprintCheckInterval)),
                            systemImage: "clock.arrow.2.circlepath"
                        )
                    }
                    .pickerStyle(.menu)
                    .help(copy.fingerprintCheckIntervalHelp)
                    Button {
                        store.showCustomFingerprintIntervalEditor()
                    } label: {
                        Label(copy.customFingerprintInterval, systemImage: "slider.horizontal.3")
                    }
                    .help(copy.customFingerprintIntervalHelp)
                }
            }

            Section(copy.budget) {
                Button {
                    store.showBudgetSettings()
                } label: {
                    Label(
                        settingValue(copy.budget, budgetSettingsSummary),
                        systemImage: "bell.badge"
                    )
                }
            }

            if store.externalPluginManagementAvailable || !store.pluginStates.isEmpty {
                Section(copy.plugins) {
                    Button {
                        store.showPluginSettings()
                    } label: {
                        Label(
                            settingValue(copy.pluginSettings, pluginSettingsSummary),
                            systemImage: "puzzlepiece.extension"
                        )
                    }
                    Button {
                        store.refreshPlugins()
                    } label: {
                        Label(copy.refreshPlugins, systemImage: "arrow.clockwise")
                    }
                }
            }

            Section(copy.displaySettings) {
                Button {
                    store.showDashboardLayoutSettings()
                } label: {
                    Label(copy.customizeDashboardLayout, systemImage: "rectangle.3.group")
                }
                Button {
                    store.editMenuBarFormat()
                } label: {
                    Label(settingValue(copy.menuBarFormat, store.settings.menuBarFormat), systemImage: "menubar.rectangle")
                }
                Picker(selection: Binding(
                    get: { store.settings.language },
                    set: { store.setLanguage($0) }
                )) {
                    Text(copy.systemLanguage).tag(AppLanguage.system)
                    Text(copy.englishLanguage).tag(AppLanguage.english)
                    Text(copy.chineseLanguage).tag(AppLanguage.chinese)
                } label: {
                    Label(settingValue(copy.languageLabel, languageLabel), systemImage: "globe")
                }
                .pickerStyle(.menu)
                Menu {
                    Button {
                        store.setAppearance(.automatic)
                    } label: {
                        Label(copy.automaticAppearance, systemImage: store.settings.appearance == .automatic ? "checkmark" : "circle")
                    }
                    Button {
                        store.setAppearance(.light)
                    } label: {
                        Label(copy.lightAppearance, systemImage: store.settings.appearance == .light ? "checkmark" : "circle")
                    }
                    Button {
                        store.setAppearance(.dark)
                    } label: {
                        Label(copy.darkAppearance, systemImage: store.settings.appearance == .dark ? "checkmark" : "circle")
                    }
                } label: {
                    Label(settingValue(copy.appearance, appearanceLabel), systemImage: "circle.lefthalf.filled")
                }
                Picker(selection: Binding(
                    get: { store.settings.surfaceStyle },
                    set: { store.setSurfaceStyle($0) }
                )) {
                    Text(copy.solidSurfaceStyle).tag(AppSurfaceStyle.solid)
                    Text(copy.glassSurfaceStyle).tag(AppSurfaceStyle.glass)
                } label: {
                    Label(settingValue(copy.surfaceStyle, surfaceStyleLabel), systemImage: "square.on.square.dashed")
                }
                .pickerStyle(.menu)
                .help(copy.surfaceStyleHelp)
                Picker(selection: Binding(
                    get: { store.settings.interfaceTextSize },
                    set: { store.setInterfaceTextSize($0) }
                )) {
                    ForEach(InterfaceTextSize.allCases) { textSize in
                        Text(copy.interfaceTextSizeLabel(textSize)).tag(textSize)
                    }
                } label: {
                    Label(
                        settingValue(copy.interfaceTextSize, copy.interfaceTextSizeLabel(store.settings.interfaceTextSize)),
                        systemImage: "textformat.size"
                    )
                }
                .pickerStyle(.menu)
                .help(copy.interfaceTextSizeHelp)
            }

            Section(copy.pricing) {
                Menu {
                    Button {
                        store.importCustomPricing(mode: .merge)
                    } label: {
                        Label(copy.importAndMergeCustomPricing, systemImage: "square.and.arrow.down")
                    }
                    Button {
                        store.importCustomPricing(mode: .replace)
                    } label: {
                        Label(copy.replaceCustomPricing, systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                    Button {
                        store.exportCustomPricing()
                    } label: {
                        Label(copy.exportCustomPricing, systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.customPricingModelCount == 0)
                    if !store.settings.customPricingPath.isEmpty {
                        Button(role: .destructive) {
                            store.removeCustomPricing()
                        } label: {
                            Label(copy.removeCustomPricing, systemImage: "trash")
                        }
                    }
                } label: {
                    Label(settingValue(copy.customPricing, store.customPricingStatusText), systemImage: "tablecells")
                }
                if store.hasCustomPricing || store.hasModelCatalogEntries {
                    Button {
                        store.showModelCatalog()
                    } label: {
                        Label(copy.searchModels, systemImage: "magnifyingglass")
                    }
                }
                Button {
                    store.updatePricingNow()
                } label: {
                    Label(copy.updatePricing, systemImage: "arrow.triangle.2.circlepath")
                }
                Toggle(isOn: Binding(
                    get: { store.settings.automaticPricingRefresh },
                    set: { store.settings.automaticPricingRefresh = $0 }
                )) {
                    Label(copy.automaticPricing, systemImage: "tag")
                }
                Toggle(isOn: Binding(
                    get: { store.settings.notificationFeedEnabled },
                    set: { store.settings.notificationFeedEnabled = $0 }
                )) {
                    Label(copy.notificationFeedEnabled, systemImage: "bell.badge")
                }
            }

            Section(copy.developerSettings) {
                Toggle(isOn: Binding(
                    get: { store.settings.developerMode },
                    set: { store.setDeveloperMode($0) }
                )) {
                    Label(copy.developerMode, systemImage: "stethoscope")
                }
                .help(copy.developerModeHelp)
                if store.settings.developerMode {
                    Button {
                        store.showDeveloperDiagnostics()
                    } label: {
                        Label(copy.openDeveloperDiagnostics, systemImage: "waveform.path.ecg")
                    }
                    Button {
                        store.publishMockNotificationEvents()
                    } label: {
                        Label(copy.generateNotificationTestEvents, systemImage: "bell.badge")
                    }
                    .help(copy.generateNotificationTestEventsHelp)
                }
            }

            Section(copy.about) {
                Button {
                    store.showAbout()
                } label: {
                    Label(copy.about, systemImage: "info.circle")
                }
            }

            Divider()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(copy.quitApp, systemImage: "power")
            }
        } label: {
            Image(systemName: "gearshape")
                .appFont(.bodyEmphasis)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Color.muted)
        .help(copy.settingsLabel)
        .accessibilityLabel(copy.settingsLabel)
    }

    private var launchAtLoginLabel: String {
        switch store.launchAtLoginStatus {
        case .requiresApproval:
            return "\(copy.launchAtLogin) · \(copy.launchAtLoginNeedsApproval)"
        case .notRegistered, .notFound, .enabled:
            return copy.launchAtLogin
        }
    }

    private var appearanceLabel: String {
        switch store.settings.appearance {
        case .automatic: return copy.automaticAppearance
        case .light: return copy.lightAppearance
        case .dark: return copy.darkAppearance
        }
    }

    private var surfaceStyleLabel: String {
        switch store.settings.surfaceStyle {
        case .solid: return copy.solidSurfaceStyle
        case .glass: return copy.glassSurfaceStyle
        }
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.usageByDay)
                        .appFont(.section)
                        .foregroundStyle(Color.bone)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Text("\(copy.dailyTotals) · \(chartGrouping.byLocalizedTitle(copy))")
                        .appFont(.metadata)
                        .foregroundStyle(Color.muted)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text(lookbackLabel(store.settings.lookbackDays))
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(Color.muted)
                    ChartViewMenu(
                        metric: $chartMetric,
                        grouping: $chartGrouping,
                        showAllModels: $showAllModels,
                        hasOtherModels: Set(store.snapshot.models.compactMap { model in
                            chartMetric == .cost && !model.hasKnownPricing ? nil : model.name
                        }).count > UsageByDayChart.maxModelSeries,
                        language: store.settings.language
                    )
                }
            }
            UsageByDayChart(
                snapshot: store.snapshot,
                metric: $chartMetric,
                grouping: $chartGrouping,
                showAllModels: $showAllModels,
                isDatePinned: $isDatePinned,
                periodLabel: lookbackLabel(store.settings.lookbackDays),
                language: store.settings.language,
                pricingProviderDisplayNames: store.modelCatalogProviderDisplayNames,
                pricingDetails: { modelName in
                    store.pricingDetails(for: modelName)
                }
            )
        }
    }

    private var budgetSection: some View {
        ProgressList(
            model: DashboardAdapters.budgetList(
                status: store.budgetStatus,
                alertLabel: copy.budgetAlertLabel(
                    MonitorSettings.budgetAlertThresholdPercentage(store.settings.budgetAlertThreshold)
                ),
                copy: copy
            )
        )
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider().overlay(Color.line)
            HStack(spacing: 8) {
                Button {
                    store.refreshNow()
                } label: {
                    Label(copy.refreshUsage, systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.phase == .refreshing || store.phase == .updatingPricing)

            }
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                    pricingStatusLabel
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("\(copy.autoRefreshShort) · \(intervalLabel(store.settings.refreshInterval))")
                }
            }
            .appFont(.metadata)
            .foregroundStyle(Color.muted)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .appFont(.sectionSubtitle)
            .foregroundStyle(Color.bone)
            .textCase(.uppercase)
            .tracking(1.1)
    }

    private func intervalLabel(_ interval: TimeInterval) -> String {
        interval >= 60 ? "\(Int(interval / 60)) \(copy.minutes)" : "\(Int(interval)) \(copy.seconds)"
    }

    private var fingerprintIntervalOptions: [TimeInterval] {
        var options = MonitorSettings.allowedFingerprintIntervals
        if !options.contains(store.settings.fingerprintCheckInterval) {
            options.append(store.settings.fingerprintCheckInterval)
        }
        return options
    }

    private func fingerprintIntervalLabel(_ interval: TimeInterval) -> String {
        if MonitorSettings.allowedFingerprintIntervals.contains(interval) {
            return intervalLabel(interval)
        }
        return "\(copy.customFingerprintInterval) · \(intervalLabel(interval))"
    }

    private func sourceVerificationModeLabel(_ mode: SourceVerificationMode) -> String {
        switch mode {
        case .eventDriven: return copy.eventDrivenVerificationMode
        case .periodicFingerprint: return copy.periodicFingerprintVerificationMode
        }
    }

    private var languageLabel: String {
        switch store.settings.language {
        case .system: return copy.systemLanguage
        case .english: return copy.englishLanguage
        case .chinese: return copy.chineseLanguage
        }
    }

    private func settingValue(_ label: String, _ value: String) -> String {
        let separator = copy.language == .chinese ? "：" : ": "
        return label + separator + value
    }

    private func lookbackLabel(_ days: Int) -> String {
        switch days {
        case 1: return copy.today
        case MonitorSettings.calendarMonthLookback: return copy.currentMonth
        default: return "\(days) \(copy.days)"
        }
    }

    private func budgetLabel(_ limit: Double) -> String {
        limit > 0 ? Currency.format(limit) : copy.notConfigured
    }

    private func budgetAlertThresholdLabel(_ threshold: Double) -> String {
        MonitorSettings.budgetAlertThresholdPercentage(threshold) + "%"
    }

    private var budgetSettingsSummary: String {
        "\(budgetLabel(store.settings.dailyCostLimit)) / \(budgetLabel(store.settings.monthlyCostLimit)) · \(budgetAlertThresholdLabel(store.settings.budgetAlertThreshold))"
    }

    private var pluginSettingsSummary: String {
        let plugins = store.externalPlugins
        if plugins.isEmpty {
            return copy.noExternalPlugins
        }

        let packageValidCount = plugins.filter(\.isPackageValid).count
        let activeCount = plugins.filter(\.enabled).count
        let activeValidCount = plugins.filter { $0.isValid && $0.enabled }.count
        if activeValidCount == plugins.count {
            return copy.configured
        }
        if activeValidCount > 0 {
            return copy.externalPluginMixed
        }
        if activeCount > 0 || packageValidCount < plugins.count {
            return copy.externalPluginMixed
        }
        if packageValidCount > 0 {
            return copy.externalPluginNotActive
        }
        return copy.externalPluginInvalid
    }

}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(Color.muted)
            .padding(.vertical, 4)
    }
}

private struct ChartViewMenu: View {
    @Binding var metric: ChartMetric
    @Binding var grouping: ChartGrouping
    @Binding var showAllModels: Bool
    let hasOtherModels: Bool
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        Menu {
            Section(copy.metric) {
                Picker(selection: $metric) {
                    Text(copy.tokens).tag(ChartMetric.tokens)
                    Text(copy.cost).tag(ChartMetric.cost)
                } label: {
                    Label(metric.localizedTitle(copy), systemImage: "chart.bar.xaxis")
                }
                .pickerStyle(.menu)
            }
            Section(copy.breakdown) {
                Picker(selection: $grouping) {
                    Text(copy.byAgent).tag(ChartGrouping.agent)
                    Text(copy.byModel).tag(ChartGrouping.model)
                } label: {
                    Label(grouping.byLocalizedTitle(copy), systemImage: "square.grid.2x2")
                }
                .pickerStyle(.menu)
                if grouping == .model {
                    Button { showAllModels.toggle() } label: {
                        Label(
                            showAllModels ? copy.collapseOtherModels : copy.expandOtherModels,
                            systemImage: showAllModels ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .disabled(!hasOtherModels)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis")
                    .appFont(.chartControlIcon)
                Text("\(metric.localizedTitle(copy)) / \(grouping.localizedTitle(copy))")
                    .appFont(.captionEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .appFont(.chartControlChevron)
            }
            .foregroundStyle(Color.bone)
            .padding(.horizontal, 10)
            .appControlHeight()
            .background(AppSurfacePanelBackground())
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .help(copy.chartView)
        .accessibilityLabel(copy.chartView)
    }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }
    var title: String { self == .tokens ? "Tokens" : "Cost" }
    var axisTitle: String { self == .tokens ? "tokens" : "$" }

    func localizedTitle(_ copy: L10n) -> String {
        self == .tokens ? copy.tokens : copy.cost
    }

    func localizedAxisTitle(_ copy: L10n) -> String {
        self == .tokens ? copy.tokensShort : "$"
    }

    func axisValueLabel(_ value: Double) -> String {
        self == .tokens ? NumberFormat.compact(value) : Currency.compact(value)
    }
}

private enum ChartGrouping: String, CaseIterable, Identifiable {
    case agent
    case model

    var id: String { rawValue }
    var title: String { self == .agent ? "Agent" : "Model" }

    func localizedTitle(_ copy: L10n) -> String {
        self == .agent ? copy.agent : copy.model
    }

    func byLocalizedTitle(_ copy: L10n) -> String {
        self == .agent ? copy.byAgent : copy.byModel
    }
}

private struct UsageByDayChart: View {
    static let maxModelSeries = 6

    let snapshot: UsageSnapshot
    @Binding var metric: ChartMetric
    @Binding var grouping: ChartGrouping
    @Binding var showAllModels: Bool
    @Binding var isDatePinned: Bool
    let periodLabel: String
    let language: AppLanguage
    let pricingProviderDisplayNames: [String: String]
    let pricingDetails: (String) -> PricingCatalogMatch?
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    @State private var selectedDate: Date?

    private var copy: L10n { L10n(language: language) }

    private var points: [UsageChartPoint] {
        let names = topModelNames
        var grouped: [String: UsageChartPoint] = [:]
        for item in snapshot.dailyModels {
            if metric == .cost && !item.hasKnownPricing { continue }
            let series: String
            switch grouping {
            case .agent:
                series = item.agent
            case .model:
                series = names.contains(item.name) ? item.name : "Other"
            }
            let key = "\(item.period)::\(series)"
            var point = grouped[key] ?? UsageChartPoint(period: item.period, series: series, tokens: .zero, cost: 0)
            point.tokens += item.tokens
            if item.hasKnownPricing { point.cost += item.estimatedCost }
            grouped[key] = point
        }

        if grouped.isEmpty {
            return snapshot.days.map { UsageChartPoint(period: $0.period, series: "All", tokens: $0.tokens, cost: $0.estimatedCost) }
        }
        return grouped.values.sorted { $0.period == $1.period ? $0.series < $1.series : $0.period < $1.period }
    }

    private var seriesNames: [String] {
        Array(Set(points.map(\.series))).sorted()
    }

    private var colors: [String: Color] {
        let palette: [Color] = [.signal, .warning, .blue, .pink, .purple, .cyan, .gray]
        switch grouping {
        case .agent:
            return Dictionary(uniqueKeysWithValues: seriesNames.enumerated().map { index, name in
                (name, palette[index % palette.count])
            })
        case .model:
            var result = Dictionary(uniqueKeysWithValues: rankedModelNames.enumerated().map { index, name in
                (name, palette[index % palette.count])
            })
            if !showAllModels, rankedModelNames.count > Self.maxModelSeries {
                result["Other"] = palette[Self.maxModelSeries % palette.count]
            }
            return result
        }
    }

    private var rankedModelNames: [String] {
        guard grouping == .model else { return [] }
        var totals: [String: Double] = [:]
        for model in snapshot.models {
            if metric == .cost && !model.hasKnownPricing { continue }
            totals[model.name, default: 0] += metric == .tokens ? Double(model.tokens.totalTokens) : model.estimatedCost
        }
        return totals
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map(\.key)
    }

    private var topModelNames: Set<String> {
        guard grouping == .model else { return [] }
        let visibleNames = showAllModels
            ? rankedModelNames
            : Array(rankedModelNames.prefix(Self.maxModelSeries))
        return Set(visibleNames)
    }

    private var modelSeriesByName: [String: String] {
        guard grouping == .model else { return [:] }
        let names = topModelNames
        return Dictionary(uniqueKeysWithValues: rankedModelNames.map { name in
            (name, names.contains(name) ? name : "Other")
        })
    }

    private var selectedPeriod: String? {
        guard let selectedDate else { return nil }
        return points.min {
            abs(ChartDate.date(from: $0.period).timeIntervalSince(selectedDate)) <
                abs(ChartDate.date(from: $1.period).timeIntervalSince(selectedDate))
        }?.period
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if points.isEmpty {
                EmptyChart(text: copy.waitingRefresh)
            } else {
                Chart {
                    chartMarks
                }
                .chartXScale(domain: chartDateDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(Color.line)
                        AxisTick().foregroundStyle(Color.line)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(AppTypography(textSize: interfaceTextSize).font(for: .metadata))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.line)
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                            .font(AppTypography(textSize: interfaceTextSize).font(for: .metadata))
                    }
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(
                    domain: seriesNames,
                    range: seriesNames.map { colors[$0] ?? Color.signal }
                )
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case let .active(location):
                                    if !isDatePinned {
                                        updateSelection(location, proxy: proxy, geometry: geometry)
                                    }
                                case .ended:
                                    if !isDatePinned {
                                        selectedDate = nil
                                    }
                                }
                            }
                            .onTapGesture {
                                if selectedDate != nil {
                                    withAnimation(.easeInOut(duration: 0.24)) {
                                        isDatePinned.toggle()
                                    }
                                }
                            }
                    }
                }
                .drawingGroup()
                .frame(height: CGFloat(interfaceTextSize.chartHeight))
                .padding(10)
                .background(AppSurfacePanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.easeInOut(duration: 0.65), value: snapshot.generatedAt)
            }
            legend
            detailPanel
        }
        .onChange(of: metric) { _ in
            isDatePinned = false
            selectedDate = nil
        }
        .onChange(of: grouping) { _ in
            isDatePinned = false
            selectedDate = nil
        }
        .onChange(of: snapshot.generatedAt) { _ in
            // A normal refresh replaces the snapshot object but keeps the same
            // date range. Preserve the user's pinned detail in that case. If
            // the range changed and the selected period disappeared, clear
            // the stale selection so it cannot silently point at another day.
            guard let selectedDate, !points.contains(where: { $0.date == selectedDate }) else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                isDatePinned = false
                self.selectedDate = nil
            }
        }
    }

    @ChartContentBuilder
    private var chartMarks: some ChartContent {
        ForEach(points) { point in
            BarMark(
                x: .value("Date", point.date),
                y: .value(metric.localizedAxisTitle(copy), point.value(for: metric))
            )
            .foregroundStyle(by: .value(grouping.title, point.series))
            .cornerRadius(2)
        }
        if let selectedDate {
            RuleMark(x: .value("Selected date", selectedDate))
                .foregroundStyle(Color.bone.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            ChartSummaryTile(
                title: metric == .tokens ? copy.totalTokens : copy.totalCost,
                value: totalValue,
                accent: metric == .tokens ? .signal : .warning,
                emphasis: true
            )
            ChartSummaryTile(title: copy.peakDay, value: peakValue, accent: Color.bone)
            ChartSummaryTile(
                title: grouping == .model ? copy.models : copy.agents,
                value: seriesCountValue,
                accent: Color.muted
            )
            if metric == .tokens {
                ChartSummaryTile(
                    title: copy.totalCost,
                    value: secondaryValue { Currency.format(snapshot.estimatedCost) },
                    accent: Color.warning,
                    emphasis: true
                )
            } else {
                ChartSummaryTile(
                    title: copy.totalTokens,
                    value: secondaryValue { NumberFormat.compact(snapshot.totalTokens.totalTokens) },
                    accent: Color.signal,
                    emphasis: true
                )
            }
        }
    }

    private var totalValue: String {
        // UsageSnapshot is the canonical total for the queried range. Do not
        // re-sum presentation points here: model grouping may filter or merge
        // rows, while the budget resolver intentionally uses this same source.
        guard snapshot.hasData else { return "—" }
        if metric == .tokens {
            return NumberFormat.compact(snapshot.totalTokens.totalTokens)
        }
        return Currency.format(snapshot.estimatedCost)
    }

    private var seriesCountValue: String {
        snapshot.hasData ? "\(seriesCount)" : "—"
    }

    private func secondaryValue(_ format: () -> String) -> String {
        snapshot.hasData ? format() : "—"
    }

    private var peakValue: String {
        guard snapshot.hasData else { return "—" }
        let totals = Dictionary(grouping: points, by: \.period).mapValues { values in
            values.reduce(0.0) { $0 + $1.value(for: metric) }
        }
        guard let peak = totals.max(by: { $0.value < $1.value }) else { return "—" }
        return ChartDate.display(peak.key)
    }

    private var seriesCount: Int {
        seriesNames.count
    }

    private var detailPanel: some View {
        Group {
            if let selectedPeriod, isDatePinned {
                UsageChartDetail(
                    period: selectedPeriod,
                    points: points.filter { $0.period == selectedPeriod },
                    dailyModels: snapshot.dailyModels.filter { $0.period == selectedPeriod },
                    metric: metric,
                    grouping: grouping,
                    colors: colors,
                    modelSeriesByName: modelSeriesByName,
                    language: language,
                    pricingProviderDisplayNames: pricingProviderDisplayNames,
                    pricingDetails: pricingDetails,
                    isPinned: true,
                        onUnpin: {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                isDatePinned = false
                                selectedDate = nil
                            }
                    }
                )
                .padding(1)
            } else if let selectedPeriod {
                let selectedPoints = points.filter { $0.period == selectedPeriod }
                CompactDetailPreview(
                    period: selectedPeriod,
                    value: metric == .tokens
                        ? NumberFormat.compact(selectedPoints.reduce(0) { $0 + $1.tokens.totalTokens })
                        : Currency.format(selectedPoints.reduce(0) { $0 + $1.cost }),
                    metric: metric,
                    language: language
                )
            } else if points.isEmpty {
                Text(copy.waitingRefresh)
                    .appFont(.metadata)
                    .foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                PeriodDetailPreview(
                    period: periodLabel,
                    tokens: snapshot.totalTokens.totalTokens,
                    cost: snapshot.estimatedCost,
                    language: language
                )
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppSurfacePanelBackground())
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(seriesNames, id: \.self) { name in
                legendItem(name)
            }
        }
    }

    @ViewBuilder
    private func legendItem(_ name: String) -> some View {
        if name == "Other", grouping == .model, !showAllModels {
            Button {
                showAllModels = true
            } label: {
                legendLabel(name)
            }
            .buttonStyle(.plain)
            .help(copy.expandOtherModels)
        } else {
            legendLabel(name)
        }
    }

    private func legendLabel(_ name: String) -> some View {
        Label(name, systemImage: "circle.fill")
            .appFont(.metadata)
            .foregroundStyle(colors[name] ?? Color.signal)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(name)
            .accessibilityLabel(name)
    }

    private func updateSelection(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard #available(macOS 14.0, *),
              let plotFrameAnchor = proxy.plotFrame else { return }
        let plotFrame = geometry[plotFrameAnchor]
        let x = location.x - plotFrame.origin.x
        guard x >= 0, x <= plotFrame.width,
              let date: Date = proxy.value(atX: x, as: Date.self) else { return }
        let nextDate = ChartDate.date(from: nearestPeriod(to: date))
        guard selectedDate != nextDate else { return }
        selectedDate = nextDate
    }

    private func nearestPeriod(to date: Date) -> String {
        points.min {
            abs($0.date.timeIntervalSince(date)) <
                abs($1.date.timeIntervalSince(date))
        }?.period ?? points[0].period
    }

    private var chartDateDomain: ClosedRange<Date> {
        guard let first = points.first, let last = points.last else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now.addingTimeInterval(86_400)
        }
        let firstDate = first.date
        let lastDate = last.date
        let span = max(lastDate.timeIntervalSince(firstDate), 86_400)
        let inset = max(span * 0.04, 43_200)
        return firstDate.addingTimeInterval(-inset)...lastDate.addingTimeInterval(inset)
    }
}

private struct ChartSummaryTile: View {
    let title: String
    let value: String
    let accent: Color
    var emphasis = false
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .appFont(emphasis ? .metadataEmphasis : .metadata)
                .foregroundStyle(Color.muted)
            Text(value)
                .appFont(emphasis ? .chartValueEmphasis : .chartValue)
                .foregroundStyle(accent)
                .lineLimit(1)
                .numericValueTransition(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .frame(height: CGFloat(interfaceTextSize.summaryTileHeight))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + value)
    }
}

private struct PeriodDetailPreview: View {
    let period: String
    let tokens: Int64
    let cost: Double
    let language: AppLanguage
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.fill")
                .appFont(.metadataEmphasis)
                .foregroundStyle(Color.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(period)
                    .appFont(.metadataEmphasis)
                    .foregroundStyle(Color.bone)
                Text(copy.clickToPin)
                    .appFont(.metadata)
                    .foregroundStyle(Color.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(NumberFormat.compact(tokens)) \(copy.tokensShort)")
                    .appFont(.metadataEmphasis)
                    .foregroundStyle(Color.signal)
                    .numericValueTransition(value: tokens)
                Text(Currency.format(cost))
                    .appFont(.metadataEmphasis)
                    .foregroundStyle(Color.warning)
                    .numericValueTransition(value: cost)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(interfaceTextSize.detailPreviewHeight))
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CompactDetailPreview: View {
    let period: String
    let value: String
    let metric: ChartMetric
    let language: AppLanguage
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .appFont(.metadataEmphasis)
                .foregroundStyle(metric == .tokens ? Color.signal : Color.warning)
            Text(ChartDate.display(period))
                .appFont(.metadataEmphasis)
                .foregroundStyle(Color.bone)
            Spacer()
            Text(value)
                .appFont(.metadataEmphasis)
                .foregroundStyle(metric == .tokens ? Color.signal : Color.warning)
                .numericValueTransition(value: value)
            Text(copy.clickToPinShort)
                .appFont(.metadata)
                .foregroundStyle(Color.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(interfaceTextSize.detailPreviewHeight))
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct UsageChartPoint: Identifiable {
    let period: String
    let series: String
    let date: Date
    var tokens: TokenTotals
    var cost: Double

    init(period: String, series: String, tokens: TokenTotals, cost: Double) {
        self.period = period
        self.series = series
        self.date = ChartDate.date(from: period)
        self.tokens = tokens
        self.cost = cost
    }

    var id: String { "\(period)::\(series)" }

    func value(for metric: ChartMetric) -> Double {
        metric == .tokens ? Double(tokens.totalTokens) : cost
    }
}

private struct UsageChartDetail: View {
    let period: String
    let points: [UsageChartPoint]
    let dailyModels: [DailyModelUsage]
    let metric: ChartMetric
    let grouping: ChartGrouping
    let colors: [String: Color]
    let modelSeriesByName: [String: String]
    let language: AppLanguage
    let pricingProviderDisplayNames: [String: String]
    let pricingDetails: (String) -> PricingCatalogMatch?
    let isPinned: Bool
    let onUnpin: () -> Void

    private var copy: L10n { L10n(language: language) }

    private var totalTokens: Int64 { points.reduce(0) { $0 + $1.tokens.totalTokens } }
    private var totalCost: Double { points.reduce(0) { $0 + $1.cost } }

    private var modelTotalTokens: Int64 { dailyModels.reduce(0) { $0 + $1.tokens.totalTokens } }
    private var modelTotalCost: Double {
        dailyModels.reduce(0) { $0 + ($1.hasKnownPricing ? $1.estimatedCost : 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ChartDate.display(period))
                    .appFont(.bodyAlert)
                    .foregroundStyle(Color.bone)
                Spacer()
                if isPinned {
                    Label(copy.pinned, systemImage: "pin.fill")
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(Color.signal)
                }
                Button(action: onUnpin) {
                    Image(systemName: "xmark")
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(Color.muted)
                }
                .buttonStyle(.plain)
                .help(copy.unpin)
                Text(metric == .tokens
                     ? NumberFormat.compact(grouping == .model ? modelTotalTokens : totalTokens)
                     : Currency.format(grouping == .model ? modelTotalCost : totalCost))
                    .appFont(.bodyAlert)
                    .foregroundStyle(metric == .tokens ? Color.signal : Color.warning)
                    .numericValueTransition(value: metric == .tokens
                        ? NumberFormat.compact(grouping == .model ? modelTotalTokens : totalTokens)
                        : Currency.format(grouping == .model ? modelTotalCost : totalCost))
            }
            Text("\(grouping.localizedTitle(copy)) · \(NumberFormat.compact(grouping == .model ? modelTotalTokens : totalTokens)) \(copy.tokensShort) · \(Currency.format(grouping == .model ? modelTotalCost : totalCost))")
                .appFont(.metadata)
                .foregroundStyle(Color.muted)
                .numericValueTransition(value: "\(modelTotalTokens)-\(modelTotalCost)-\(grouping.rawValue)")
            if grouping == .model {
                ForEach(Array(dailyModels.sorted { metric.value(for: $0) > metric.value(for: $1) }.enumerated()), id: \.element.id) { index, model in
                    ModelDetailRow(
                        model: model,
                        color: colors[modelSeriesByName[model.name] ?? model.name] ?? Color.warning,
                        metric: metric,
                        language: language,
                        pricingProviderDisplayNames: pricingProviderDisplayNames,
                        pricingDetails: pricingDetails(model.name)
                    )
                }
            } else {
                ForEach(points.sorted { $0.value(for: metric) > $1.value(for: metric) }) { point in
                    UsageDetailRow(point: point, color: colors[point.series] ?? Color.signal, metric: metric)
                }
            }
        }
        .padding(11)
        .background(AppSurfacePanelBackground())
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

}

private struct UsageDetailRow: View {
    let point: UsageChartPoint
    let color: Color
    let metric: ChartMetric

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(point.series)
                .appFont(.metadata)
                .foregroundStyle(Color.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(metric == .tokens ? NumberFormat.compact(point.tokens.totalTokens) : Currency.format(point.cost))
                .appFont(.metadataEmphasis)
                .foregroundStyle(Color.bone)
                .numericValueTransition(value: metric == .tokens
                    ? NumberFormat.compact(point.tokens.totalTokens)
                    : Currency.format(point.cost))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            point.series + ", " + (metric == .tokens
                ? NumberFormat.compact(point.tokens.totalTokens)
                : Currency.format(point.cost))
        )
    }
}

private enum TokenBreakdownKind: String, CaseIterable, Identifiable, Hashable {
    case input
    case output
    case cacheRead
    case cacheWrite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .input: return Color.signal
        case .output: return Color.warning
        case .cacheRead: return Color.blue
        case .cacheWrite: return Color.purple
        }
    }

    func title(_ copy: L10n) -> String {
        switch self {
        case .input: return copy.input
        case .output: return copy.output
        case .cacheRead: return copy.cacheRead
        case .cacheWrite: return copy.cacheWrite
        }
    }

    func shortTitle(_ copy: L10n) -> String {
        switch self {
        case .input: return copy.inputShort
        case .output: return copy.outputShort
        case .cacheRead: return copy.cacheReadShort
        case .cacheWrite: return copy.cacheWriteShort
        }
    }

    func value(in tokens: TokenTotals) -> Int64 {
        switch self {
        case .input: return tokens.inputTokens
        case .output: return tokens.outputTokens
        case .cacheRead: return tokens.cacheReadTokens
        case .cacheWrite: return tokens.cacheCreationTokens
        }
    }
}

private enum ModelDetailLayout {
    static let contentIndent: CGFloat = 27
}

private struct TokenBreakdownSummary: View {
    let tokens: TokenTotals
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(TokenBreakdownKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(Color.subtle)
                }
                HStack(spacing: 2) {
                    Text(kind.shortTitle(copy))
                        .foregroundStyle(kind.color.opacity(0.86))
                    Text(NumberFormat.compact(kind.value(in: tokens)))
                        .foregroundStyle(Color.muted)
                        .numericValueTransition(value: kind.value(in: tokens))
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .appFont(.metadata)
        .padding(.leading, ModelDetailLayout.contentIndent)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        TokenBreakdownKind.allCases.map { kind in
            "\(kind.title(copy)) \(NumberFormat.grouped(kind.value(in: tokens)))"
        }.joined(separator: ", ")
    }
}

private struct ModelDetailRow: View {
    let model: DailyModelUsage
    let color: Color
    let metric: ChartMetric
    let language: AppLanguage
    let pricingProviderDisplayNames: [String: String]
    let pricingDetails: PricingCatalogMatch?

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .appFont(.metadata)
                            .foregroundStyle(Color.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.agent)
                            .appFont(.metadata)
                            .foregroundStyle(Color.subtle)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(NumberFormat.compact(model.tokens.totalTokens) + " " + copy.tokensShort)
                            .appFont(.metadataEmphasis)
                            .foregroundStyle(metric == .tokens ? Color.bone : Color.muted)
                            .numericValueTransition(value: model.tokens.totalTokens)
                        Text(model.hasKnownPricing ? Currency.format(model.estimatedCost) : copy.unknown)
                            .appFont(.metadataEmphasis)
                            .foregroundStyle(model.hasKnownPricing ? (metric == .cost ? Color.warning : Color.subtle) : Color.warning)
                            .numericValueTransition(value: model.hasKnownPricing ? model.estimatedCost : 0)
                    }
                }
                TokenBreakdownSummary(tokens: model.tokens, language: language)
            }
            if let pricingDetails {
                HStack(spacing: 4) {
                    Image(systemName: isApproximatePricing ? "exclamationmark.triangle" : "checkmark.seal")
                        .appFont(.metadataEmphasis)
                    Text(pricingSourceTitle)
                    Text(copy.perMillionTokens)
                        .foregroundStyle(Color.subtle)
                }
                .appFont(.metadataEmphasis)
                .foregroundStyle(isApproximatePricing ? Color.warning : Color.signal)
                .padding(.leading, ModelDetailLayout.contentIndent)
                .help(priceSourceTooltip)
                if isApproximatePricing {
                    Text(copy.approximateTierNote)
                        .appFont(.metadata)
                        .foregroundStyle(Color.subtle)
                        .padding(.leading, ModelDetailLayout.contentIndent)
                }
                ModelPricingGrid(
                    schedule: pricingDetails.schedule,
                    selectedThreshold: model.pricingTierThreshold,
                    backendThreshold: model.pricingBackendThreshold,
                    isApproximate: isApproximatePricing,
                    language: language
                )
            } else if model.pricingSource == .custom || model.pricingSource == .approximate {
                HStack(spacing: 4) {
                    Image(systemName: isApproximatePricing ? "exclamationmark.triangle" : "checkmark.seal")
                        .appFont(.metadataEmphasis)
                    Text(isApproximatePricing ? copy.approximatePriceSource : copy.customPriceSource)
                    Text(copy.unitPricingUnavailable)
                        .foregroundStyle(Color.subtle)
                }
                .appFont(.metadataEmphasis)
                .foregroundStyle(isApproximatePricing ? Color.warning : Color.signal)
                .padding(.leading, ModelDetailLayout.contentIndent)
            } else if model.hasKnownPricing {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .appFont(.metadataEmphasis)
                    Text(copy.pricingStatusSourceLabel(
                        model.pricingSource,
                        providerNames: providerNames
                    ))
                }
                .appFont(.metadata)
                .foregroundStyle(Color.subtle)
                .padding(.leading, ModelDetailLayout.contentIndent)
                .help(priceSourceTooltip)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .appFont(.metadataEmphasis)
                    Text(copy.noPricingAvailable)
                        .lineLimit(1)
                }
                .appFont(.metadata)
                .foregroundStyle(Color.subtle)
                .padding(.leading, ModelDetailLayout.contentIndent)
            }
        }
    }

    private var isApproximatePricing: Bool {
        model.pricingSource == .approximate
    }

    private var providerNames: [String] {
        model.pricingProviderIDs.map { pricingProviderDisplayNames[$0] ?? $0 }
    }

    private var pricingSourceTitle: String {
        switch model.pricingSource {
        case .remote:
            return copy.priceListSourceLabel(providerNames)
        case .approximate:
            return copy.approximatePriceSource
        case .custom:
            return copy.customPriceSource
        case .mixed:
            return copy.pricingStatusSourceLabel(.mixed, providerNames: providerNames)
        case .ccusage, .unknown:
            return copy.pricingStatusSourceLabel(model.pricingSource, providerNames: providerNames)
        }
    }

    private var priceSourceTooltip: String {
        if model.pricingSource == .remote {
            return copy.priceListSourceTooltip(providerNames)
        }
        return copy.officialAPIPriceTooltip
    }
}

private struct ModelPricingGrid: View {
    let schedule: CanonicalModelPricing
    let selectedThreshold: Int64?
    let backendThreshold: Int64?
    let isApproximate: Bool
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    private var tiers: [PricingTier] {
        schedule.tiers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tiers.isEmpty {
                PricingTierHeader(title: baseTierTitle, color: Color.muted)
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                PricingRateCell(title: copy.input, rate: schedule.base.input)
                PricingRateCell(title: copy.output, rate: schedule.base.output)
                PricingRateCell(title: copy.cacheWrite, rate: schedule.base.cacheCreation)
                PricingRateCell(title: copy.cacheRead, rate: schedule.base.cacheRead)
            }
            ForEach(tiers, id: \.threshold) { tier in
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .overlay(Color.line.opacity(0.7))
                    PricingTierHeader(
                        title: tierTitle(tier),
                        color: selectedThreshold == tier.threshold ? Color.warning : Color.subtle
                    )
                    LazyVGrid(
                        columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        PricingRateCell(title: copy.input, rate: tier.rates.input)
                        PricingRateCell(title: copy.output, rate: tier.rates.output)
                        PricingRateCell(title: copy.cacheWrite, rate: tier.rates.cacheCreation)
                        PricingRateCell(title: copy.cacheRead, rate: tier.rates.cacheRead)
                    }
                }
            }
        }
        .padding(.leading, ModelDetailLayout.contentIndent)
        .padding(.vertical, 4)
        .background(AppSurfacePanelBackground(opacity: 0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var baseTierTitle: String {
        isApproximate ? "\(copy.basePricingTier) · \(copy.approximatePriceSource)" : copy.basePricingTier
    }

    private func tierTitle(_ tier: PricingTier) -> String {
        let sourceTitle = "\(copy.longContextPricingTier) · \(copy.above) \(NumberFormat.threshold(tier.threshold))"
        let title: String
        if isApproximate, selectedThreshold == tier.threshold, let backendThreshold, backendThreshold != tier.threshold {
            title = "\(sourceTitle) → \(copy.above) \(NumberFormat.threshold(backendThreshold))"
        } else {
            title = sourceTitle
        }
        guard selectedThreshold == tier.threshold else { return title }
        return "\(title) · \(copy.selectedPricingTier)"
    }
}

private struct PricingTierHeader: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.right")
                .appFont(.metadataEmphasis)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .appFont(.metadataEmphasis)
        .foregroundStyle(color)
    }
}

private struct PricingRateCell: View {
    let title: String
    let rate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .appFont(.metadata)
                .foregroundStyle(Color.muted)
            Text(rateText)
                .appFont(.metadataEmphasis)
                .foregroundStyle(Color.bone)
                .lineLimit(1)
                .numericValueTransition(value: rate)
        }
    }

    private var rateText: String {
        guard let rate, rate.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        let perMillion = rate * 1_000_000
        let formatted = formatter.string(from: NSNumber(value: perMillion)) ?? "0"
        return "$\(formatted)"
    }
}

private struct EmptyChart: View {
    let text: String

    var body: some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(Color.muted)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            .background(AppSurfacePanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension ChartMetric {
    func value(for model: DailyModelUsage) -> Double {
        self == .tokens ? Double(model.tokens.totalTokens) : model.estimatedCost
    }
}

private enum ChartDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    static func date(from period: String) -> Date {
        formatter.date(from: period) ?? .distantPast
    }

    static func display(_ period: String) -> String {
        let displayFormatter = DateFormatter()
        displayFormatter.calendar = Calendar(identifier: .gregorian)
        displayFormatter.locale = .current
        displayFormatter.timeZone = .current
        displayFormatter.dateFormat = "EEE, MMM d"
        return displayFormatter.string(from: date(from: period))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(.button)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .appControlHeight()
            .background(Color.signal.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(.button)
            .foregroundStyle(Color.bone)
            .padding(.horizontal, 11)
            .appControlHeight()
            .background(AppSurfacePanelBackground(opacity: configuration.isPressed ? 0.65 : 1))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension RefreshPhase {
    var isHealthy: Bool {
        switch self {
        case .failed: return false
        default: return true
        }
    }
}

private extension Color {
    static var ink: Color { AppWindowTheme.canvas }
    static var panel: Color { AppWindowTheme.panel }
    static var bone: Color { AppWindowTheme.primary }
    static var muted: Color { AppWindowTheme.secondary }
    static var subtle: Color { AppWindowTheme.tertiary }
    static var line: Color { AppWindowTheme.separator }
    static var signal: Color { AppWindowTheme.signal }
    static var warning: Color { Color(nsColor: NSColor.systemOrange) }
    static var alert: Color { AppWindowTheme.alert }
    static var tooltipBackground: Color { AppWindowTheme.panel }
}
