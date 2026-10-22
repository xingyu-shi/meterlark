import SwiftUI

private enum DashboardHeightMode: Hashable {
    case fitContent
    case fixed
}

struct DashboardLayoutSettingsView: View {
    let components: [DashboardLayoutComponent]
    let language: AppLanguage
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle
    let interfaceTextSize: InterfaceTextSize
    let popoverHeight: Double
    let initialCustomPopoverHeight: Double
    let onSave: (DashboardLayout, Double) throws -> Void
    let onReset: () throws -> Void
    let onDraftChange: (DashboardLayout, Double) -> Void
    let onClose: () -> Void

    @State private var draft: DashboardLayout
    @State private var draftPopoverHeight: Double
    @State private var customPopoverHeightText: String
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private var copy: L10n { L10n(language: language) }

    init(
        components: [DashboardLayoutComponent],
        layout: DashboardLayout,
        language: AppLanguage,
        appearance: AppAppearance = .automatic,
        surfaceStyle: AppSurfaceStyle = .solid,
        interfaceTextSize: InterfaceTextSize = .standard,
        popoverHeight: Double = MonitorSettings.compactPopoverHeight,
        initialCustomPopoverHeight: Double? = nil,
        onSave: @escaping (DashboardLayout, Double) throws -> Void,
        onReset: @escaping () throws -> Void,
        onDraftChange: @escaping (DashboardLayout, Double) -> Void = { _, _ in },
        onClose: @escaping () -> Void
    ) {
        self.components = components
        self.language = language
        self.appearance = appearance
        self.surfaceStyle = surfaceStyle
        self.interfaceTextSize = interfaceTextSize
        self.popoverHeight = popoverHeight
        let resolvedCustomHeight = Self.resolvedCustomPopoverHeight(
            initialCustomPopoverHeight ?? popoverHeight
        )
        self.initialCustomPopoverHeight = resolvedCustomHeight
        self.onSave = onSave
        self.onReset = onReset
        self.onDraftChange = onDraftChange
        self.onClose = onClose
        _draft = State(initialValue: layout.normalized(for: components))
        _draftPopoverHeight = State(initialValue: popoverHeight)
        _customPopoverHeightText = State(initialValue: Self.heightText(resolvedCustomHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            heightEditor

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.componentOrder, id: \.self) { componentID in
                        if let component = components.first(where: { $0.id == componentID }) {
                            componentEditor(component)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let savedMessage {
                Text(savedMessage)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.signal)
            }

            HStack(spacing: 8) {
                Button(copy.resetDashboardLayout, action: reset)
                Spacer()
                Button(copy.done, action: onClose)
                Button(copy.saveDashboardLayout, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 520)
        .background(AppSurfaceBackground(style: surfaceStyle))
        .background(WindowAppearanceBridge(
            appearance: appearance,
            surfaceStyle: surfaceStyle
        ))
        .preferredColorScheme(preferredColorScheme)
        .appInterfaceTextSize(interfaceTextSize)
        .environment(\.appSurfaceStyle, surfaceStyle)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(copy.dashboardLayoutSettingsTitle)
                .appFont(.section)
                .foregroundStyle(AppWindowTheme.primary)
            Text(copy.dashboardLayoutSubtitle)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heightEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.dashboardLayoutHeight)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(AppWindowTheme.primary)
                    Text(heightMode == .fitContent
                         ? copy.dashboardLayoutFitContent
                         : copy.dashboardLayoutFixedHeight)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                }
                Spacer()
                Picker(
                    copy.dashboardLayoutHeight,
                    selection: Binding(
                        get: { heightMode },
                        set: { setHeightMode($0) }
                    )
                ) {
                    Text(copy.dashboardLayoutFitContent).tag(DashboardHeightMode.fitContent)
                    Text(copy.dashboardLayoutFixedHeight).tag(DashboardHeightMode.fixed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            if heightMode == .fixed {
                HStack(spacing: 8) {
                    TextField(copy.dashboardLayoutCustomHeight, text: $customPopoverHeightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: customPopoverHeightText) { _ in
                            commitCustomPopoverHeightIfValid()
                        }
                        .onSubmit(commitCustomPopoverHeight)
                    Text(copy.dashboardLayoutPoints)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                    Stepper(
                        "",
                        value: Binding(
                            get: { fixedPopoverHeight },
                            set: { setPopoverHeight($0) }
                        ),
                        in: MonitorSettings.minimumPopoverHeight...MonitorSettings.maximumPopoverHeight,
                        step: 20
                    )
                    .labelsHidden()
                }
                .padding(.leading, 24)
            }
        }
        .padding(14)
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func componentEditor(_ component: DashboardLayoutComponent) -> some View {
        let isVisible = draft.isVisible(component.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(
                    isOn: Binding(
                        get: { draft.isVisible(component.id) },
                        set: { setVisible($0, componentID: component.id) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(component.title)
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(AppWindowTheme.primary)
                        Text(sourceLabel(for: component))
                            .appFont(.metadata)
                            .foregroundStyle(AppWindowTheme.secondary)
                    }
                }
                Spacer()
                orderButtons(
                    index: draft.componentOrder.firstIndex(of: component.id) ?? 0,
                    count: draft.componentOrder.count,
                    moveUp: { move(component.id, offset: -1) },
                    moveDown: { move(component.id, offset: 1) }
                )
            }

            if isVisible, let range = component.columnRange {
                Picker(
                    copy.dashboardLayoutColumns,
                    selection: Binding(
                        get: {
                            draft.componentColumns[component.id]
                                ?? component.defaultColumns
                                ?? range.lowerBound
                        },
                        set: { setColumns($0, for: component, range: range) }
                    )
                ) {
                    ForEach(range, id: \.self) { columns in
                        Text(String(columns)).tag(columns)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
                .padding(.leading, 24)
            }
        }
        .padding(14)
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func orderButtons(
        index: Int,
        count: Int,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index <= 0)
            .help(copy.layoutMoveUp)
            .accessibilityLabel(copy.layoutMoveUp)

            Button(action: moveDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= count - 1)
            .help(copy.layoutMoveDown)
            .accessibilityLabel(copy.layoutMoveDown)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func sourceLabel(for component: DashboardLayoutComponent) -> String {
        switch component.kind {
        case .builtIn:
            return copy.dashboardLayoutBuiltIn
        case .pluginBlock:
            return copy.dashboardLayoutPlugin
        }
    }

    private func setVisible(_ visible: Bool, componentID: String) {
        if visible {
            draft.hiddenComponentIDs.removeAll { $0 == componentID }
        } else if !draft.hiddenComponentIDs.contains(componentID) {
            draft.hiddenComponentIDs.append(componentID)
        }
        clearMessages()
        publishDraft()
    }

    private func setColumns(
        _ columns: Int,
        for component: DashboardLayoutComponent,
        range: ClosedRange<Int>
    ) {
        guard range.contains(columns) else { return }
        draft.componentColumns[component.id] = columns
        clearMessages()
        publishDraft()
    }

    private func move(_ componentID: String, offset: Int) {
        guard let index = draft.componentOrder.firstIndex(of: componentID) else { return }
        let destination = index + offset
        guard draft.componentOrder.indices.contains(destination) else { return }
        draft.componentOrder.swapAt(index, destination)
        clearMessages()
        publishDraft()
    }

    private func save() {
        let normalized = draft.normalized(for: components)
        do {
            try onSave(normalized, draftPopoverHeight)
            draft = normalized
            onDraftChange(normalized, draftPopoverHeight)
            errorMessage = nil
            savedMessage = copy.layoutSaved
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }

    private func reset() {
        do {
            try onReset()
            draft = DashboardLayout.default.normalized(for: components)
            draftPopoverHeight = popoverHeight
            customPopoverHeightText = Self.heightText(Self.resolvedCustomPopoverHeight(popoverHeight))
            onDraftChange(draft, draftPopoverHeight)
            errorMessage = nil
            savedMessage = copy.layoutSaved
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }

    private func clearMessages() {
        errorMessage = nil
        savedMessage = nil
    }

    private func publishDraft() {
        onDraftChange(draft.normalized(for: components), draftPopoverHeight)
    }

    private var heightMode: DashboardHeightMode {
        draftPopoverHeight == MonitorSettings.compactPopoverHeight ? .fitContent : .fixed
    }

    private var fixedPopoverHeight: Double {
        heightMode == .fixed
            ? draftPopoverHeight
            : initialCustomPopoverHeight
    }

    private func setHeightMode(_ mode: DashboardHeightMode) {
        switch mode {
        case .fitContent:
            setPopoverHeight(MonitorSettings.compactPopoverHeight)
        case .fixed:
            setPopoverHeight(Self.resolvedCustomPopoverHeight(fixedPopoverHeight))
        }
    }

    private func setPopoverHeight(_ height: Double) {
        guard MonitorSettings.isValidPopoverHeight(height) else { return }
        draftPopoverHeight = height
        if height != MonitorSettings.compactPopoverHeight {
            customPopoverHeightText = Self.heightText(height)
        }
        clearMessages()
        publishDraft()
    }

    private func commitCustomPopoverHeightIfValid() {
        guard let value = Double(customPopoverHeightText),
              MonitorSettings.isValidPopoverHeight(value) else { return }
        setPopoverHeight(value)
    }

    private func commitCustomPopoverHeight() {
        guard let value = Double(customPopoverHeightText),
              MonitorSettings.isValidPopoverHeight(value) else {
            customPopoverHeightText = Self.heightText(fixedPopoverHeight)
            return
        }
        setPopoverHeight(value)
    }

    private static func resolvedCustomPopoverHeight(_ height: Double) -> Double {
        guard height.isFinite else { return 800 }
        if height == MonitorSettings.compactPopoverHeight {
            return MonitorSettings.compactPopoverHeight + 20
        }
        return min(
            MonitorSettings.maximumPopoverHeight,
            max(MonitorSettings.minimumPopoverHeight, height)
        )
    }

    private static func heightText(_ height: Double) -> String {
        if let integer = Int(exactly: height) {
            return String(integer)
        }
        return String(height)
    }
}
