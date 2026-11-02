import AppKit
import SwiftUI

/// The app owns one settings window; reopening it preserves the selected page.
@MainActor
final class AppSettingsWindowController: NSWindowController {
    init() { super.init(window: nil) }

    required init?(coder: NSCoder) { nil }

    func show(store: MonitorStore, updater: AppUpdater) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 650),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 760, height: 560)
            window.setFrameAutosaveName("MeterlarkSettings")
            let host = NSHostingView(rootView: AppSettingsView(
                store: store,
                updater: updater,
                onTitleChange: { [weak self] title in self?.window?.title = title }
            ))
            // Window size belongs to AppKit, not each page's ideal Form size.
            host.sizingOptions = []
            window.contentView = host
            self.window = window
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum AppSettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, data, budget, plugins, advanced
    var id: Self { self }

    func title(_ copy: L10n) -> String {
        switch self {
        case .general: return copy.generalSettings
        case .appearance: return copy.settingsAppearance
        case .data: return copy.settingsData
        case .budget: return copy.budget
        case .plugins: return copy.plugins
        case .advanced: return copy.settingsAdvanced
        }
    }

    func subtitle(_ copy: L10n) -> String {
        switch self {
        case .general: return copy.settingsGeneralSubtitle
        case .appearance: return copy.settingsAppearanceSubtitle
        case .data: return copy.settingsDataSubtitle
        case .budget: return copy.budgetSettingsSubtitle
        case .plugins: return copy.pluginSettingsSubtitle
        case .advanced: return copy.settingsAdvancedSubtitle
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .data: return "chart.bar"
        case .budget: return "bell.badge"
        case .plugins: return "puzzlepiece.extension"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var updater: AppUpdater
    let onTitleChange: (String) -> Void
    @State private var selection: AppSettingsPage? = .general
    @State private var editingBudget = false

    init(
        store: MonitorStore,
        updater: AppUpdater,
        initialPage: AppSettingsPage = .general,
        onTitleChange: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.updater = updater
        self.onTitleChange = onTitleChange
        _selection = State(initialValue: initialPage)
    }

    private var copy: L10n { L10n(language: store.settings.language) }
    private var page: AppSettingsPage { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            List(AppSettingsPage.allCases, selection: $selection) { page in
                Label(page.title(copy), systemImage: page.symbol)
                    .appFont(.body)
                    .padding(.vertical, 5)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 196)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(page.title(copy))
                        .appFont(.title)
                        .foregroundStyle(AppWindowTheme.primary)
                    Text(page.subtitle(copy))
                        .appFont(.caption)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                Divider()
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .tint(AppWindowTheme.signal)
        .appFont(.body)
        .background(AppSurfaceBackground(style: store.settings.surfaceStyle))
        .background(WindowAppearanceBridge(appearance: store.settings.appearance, surfaceStyle: store.settings.surfaceStyle))
        .preferredColorScheme(preferredColorScheme)
        .appInterfaceTextSize(store.settings.interfaceTextSize)
        .environment(\.appSurfaceStyle, store.settings.surfaceStyle)
        .onAppear {
            updateTitle()
            store.refreshLaunchAtLoginStatus()
        }
        .onChange(of: selection) { _ in updateTitle() }
        .onChange(of: store.settings.language) { _ in updateTitle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLaunchAtLoginStatus()
        }
        .sheet(isPresented: $editingBudget) {
            BudgetSettingsView(store: store, onCancel: { editingBudget = false }, onSave: { editingBudget = false })
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general:
            generalPage
        case .appearance:
            appearancePage
        case .data:
            dataPage
        case .budget:
            budgetPage
        case .plugins:
            ScrollView { PluginSettingsView(store: store) }
        case .advanced:
            advancedPage
        }
    }

    private var generalPage: some View {
        Form {
            Section {
                Toggle(copy.launchAtLogin, isOn: Binding(get: { store.launchAtLoginEnabled }, set: store.setLaunchAtLogin))
                if store.launchAtLoginStatus == .requiresApproval {
                    Text(copy.launchAtLoginNeedsApproval).foregroundStyle(AppWindowTheme.secondary)
                }
                Picker(copy.languageLabel, selection: Binding(get: { store.settings.language }, set: store.setLanguage)) {
                    Text(copy.systemLanguage).tag(AppLanguage.system)
                    Text(copy.englishLanguage).tag(AppLanguage.english)
                    Text(copy.chineseLanguage).tag(AppLanguage.chinese)
                }
                Toggle(copy.notificationFeedEnabled, isOn: setting(\.notificationFeedEnabled))
            }
            AppUpdateSettingsSection(updater: updater, copy: copy)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var appearancePage: some View {
        Form {
            Section(copy.settingsDashboard) {
                Picker(copy.appearance, selection: Binding(get: { store.settings.appearance }, set: store.setAppearance)) {
                    Text(copy.automaticAppearance).tag(AppAppearance.automatic)
                    Text(copy.lightAppearance).tag(AppAppearance.light)
                    Text(copy.darkAppearance).tag(AppAppearance.dark)
                }
                Picker(copy.surfaceStyle, selection: Binding(get: { store.settings.surfaceStyle }, set: store.setSurfaceStyle)) {
                    Text(copy.solidSurfaceStyle).tag(AppSurfaceStyle.solid)
                    Text(copy.glassSurfaceStyle).tag(AppSurfaceStyle.glass)
                }
                Picker(copy.interfaceTextSize, selection: Binding(get: { store.settings.interfaceTextSize }, set: store.setInterfaceTextSize)) {
                    ForEach(InterfaceTextSize.allCases) { size in
                        Text(copy.interfaceTextSizeLabel(size)).tag(size)
                    }
                }
                Button(copy.customizeDashboardLayout, action: store.showDashboardLayoutSettings)
            }
            Section(copy.settingsMenuBar) {
                MenuBarFormatPreviewView(format: MenuBarFormat(rawValue: store.settings.menuBarFormat), cost: store.snapshot.primaryEstimatedCost)
                Button(copy.settingsEditMenuBar, action: store.editMenuBarFormat)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var dataPage: some View {
        Form {
            Section(copy.usageSettings) {
                Picker(copy.lookback, selection: Binding(get: { store.settings.lookbackDays }, set: store.setLookbackDays)) {
                    ForEach(MonitorSettings.allowedLookbackDays, id: \.self) { days in
                        Text(lookbackLabel(days)).tag(days)
                    }
                }
                Picker(copy.usageRefreshInterval, selection: Binding(get: { store.settings.refreshInterval }, set: store.setRefreshInterval)) {
                    ForEach(MonitorSettings.allowedIntervals, id: \.self) { interval in
                        Text(intervalLabel(interval)).tag(interval)
                    }
                }
                helpText(copy.usageRefreshIntervalHelp)
            }
            Section(copy.pricing) {
                LabeledContent(copy.customPricing, value: store.customPricingStatusText)
                Menu {
                    Button(copy.importAndMergeCustomPricing) { store.importCustomPricing(mode: .merge) }
                    Button(copy.replaceCustomPricing) { store.importCustomPricing(mode: .replace) }
                    Divider()
                    Button(copy.exportCustomPricing, action: store.exportCustomPricing)
                        .disabled(store.customPricingModelCount == 0)
                    if !store.settings.customPricingPath.isEmpty {
                        Button(copy.removeCustomPricing, role: .destructive, action: store.removeCustomPricing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(copy.settingsManagePrices)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .foregroundStyle(AppWindowTheme.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if store.hasCustomPricing || store.hasModelCatalogEntries {
                    Button(copy.searchModels, action: store.showModelCatalog)
                }
                Toggle(copy.automaticPricing, isOn: setting(\.automaticPricingRefresh))
                Button(copy.updatePricing, action: store.updatePricingNow)
                    .disabled(store.phase == .updatingPricing)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var budgetPage: some View {
        Form {
            Section {
                LabeledContent(copy.dailyBudget, value: budgetLabel(store.settings.dailyCostLimit))
                LabeledContent(copy.monthlyBudget, value: budgetLabel(store.settings.monthlyCostLimit))
                LabeledContent(copy.budgetAlertThreshold, value: MonitorSettings.budgetAlertThresholdPercentage(store.settings.budgetAlertThreshold) + "%")
                Button(copy.settingsEditBudget) { editingBudget = true }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var advancedPage: some View {
        Form {
            Section(copy.sourceVerificationMode) {
                Picker(copy.sourceVerificationMode, selection: Binding(get: { store.settings.sourceVerificationMode }, set: store.setSourceVerificationMode)) {
                    Text(copy.eventDrivenVerificationMode).tag(SourceVerificationMode.eventDriven)
                    Text(copy.periodicFingerprintVerificationMode).tag(SourceVerificationMode.periodicFingerprint)
                }
                helpText(copy.sourceVerificationModeHelp)
                if store.settings.sourceVerificationMode == .periodicFingerprint {
                    Picker(copy.fingerprintCheckInterval, selection: Binding(get: { store.settings.fingerprintCheckInterval }, set: store.setFingerprintCheckInterval)) {
                        ForEach(fingerprintIntervals, id: \.self) { interval in
                            Text(intervalLabel(interval)).tag(interval)
                        }
                    }
                    Button(copy.customFingerprintInterval, action: store.showCustomFingerprintIntervalEditor)
                    helpText(copy.fingerprintCheckIntervalHelp)
                }
            }
            Section(copy.developerSettings) {
                Toggle(copy.developerMode, isOn: Binding(get: { store.settings.developerMode }, set: store.setDeveloperMode))
                helpText(copy.developerModeHelp)
                if store.settings.developerMode {
                    Button(copy.openDeveloperDiagnostics, action: store.showDeveloperDiagnostics)
                    Button(copy.generateNotificationTestEvents) { store.publishMockNotificationEvents() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var fingerprintIntervals: [TimeInterval] {
        var intervals = MonitorSettings.allowedFingerprintIntervals
        if !intervals.contains(store.settings.fingerprintCheckInterval) {
            intervals.append(store.settings.fingerprintCheckInterval)
        }
        return intervals
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<MonitorSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { store.settings[keyPath: keyPath] = $0 })
    }

    private func lookbackLabel(_ days: Int) -> String {
        switch days {
        case 1: return copy.today
        case MonitorSettings.calendarMonthLookback: return copy.currentMonth
        default: return "\(days) \(copy.days)"
        }
    }

    private func intervalLabel(_ interval: TimeInterval) -> String {
        interval >= 60 ? "\(Int(interval / 60)) \(copy.minutes)" : "\(Int(interval)) \(copy.seconds)"
    }

    private func budgetLabel(_ limit: Double) -> String {
        limit > 0 ? Currency.format(limit) : copy.notConfigured
    }

    private func helpText(_ text: String) -> some View {
        Text(text).appFont(.caption).foregroundStyle(AppWindowTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updateTitle() {
        onTitleChange(page.title(copy) + " · Meterlark")
    }
}
