import SwiftUI

struct PluginConfigurationView: View {
    let record: ExternalPluginRecord
    let schema: PluginConfigurationSchema
    let language: AppLanguage
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle
    let interfaceTextSize: InterfaceTextSize
    let onSave: (PluginConfigurationSubmission) throws -> Void
    let onReset: () throws -> Void
    let onClose: () -> Void

    @State private var publicValues: [String: PluginJSONValue]
    @State private var secretInputs: [String: String]
    @State private var configuredSecretIDs: Set<String>
    @State private var clearSecretIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private var copy: L10n { L10n(language: language) }

    init(
        record: ExternalPluginRecord,
        schema: PluginConfigurationSchema,
        draft: PluginConfigurationDraft,
        language: AppLanguage,
        appearance: AppAppearance = .automatic,
        surfaceStyle: AppSurfaceStyle = .solid,
        interfaceTextSize: InterfaceTextSize = .standard,
        onSave: @escaping (PluginConfigurationSubmission) throws -> Void,
        onReset: @escaping () throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.record = record
        self.schema = schema
        self.language = language
        self.appearance = appearance
        self.surfaceStyle = surfaceStyle
        self.interfaceTextSize = interfaceTextSize
        self.onSave = onSave
        self.onReset = onReset
        self.onClose = onClose
        _publicValues = State(initialValue: draft.publicValues)
        _secretInputs = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: schema.fields
                    .filter { $0.kind == .secret }
                    .map { ($0.id, "") }
            )
        )
        _configuredSecretIDs = State(initialValue: draft.configuredSecretIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(schema.fields) { field in
                        fieldEditor(field)
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
                Button(copy.pluginConfigurationReset, action: reset)
                Spacer()
                Button(copy.done, action: onClose)
                Button(copy.pluginConfigurationSave, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
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
            Text(
                schema.localizedTitle(for: language)
                    ?? copy.pluginConfigurationTitle(record.manifest.localizedDisplayName(for: language))
            )
                .appFont(.section)
                .foregroundStyle(AppWindowTheme.primary)
            if let description = schema.localizedDescription(for: language) {
                Text(description)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(copy.pluginConfigurationSubtitle)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fieldEditor(_ field: PluginConfigurationField) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.localizedLabel(for: language))
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(AppWindowTheme.primary)
                if field.required {
                    Text(copy.pluginConfigurationRequired)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.alert)
                }
                if field.kind == .secret {
                    Spacer()
                    Text(secretStatus(for: field.id))
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                }
            }

            control(for: field)
        }
        .padding(12)
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func control(for field: PluginConfigurationField) -> some View {
        switch field.kind {
        case .boolean:
            Toggle("", isOn: boolBinding(for: field))
                .labelsHidden()
        case .choice:
            Picker("", selection: stringBinding(for: field)) {
                ForEach(field.options ?? []) { option in
                    Text(option.localizedLabel(for: language)).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .secret:
            HStack(spacing: 8) {
                SecureField(
                    field.localizedPlaceholder(for: language)
                        ?? field.localizedLabel(for: language),
                    text: secretBinding(for: field)
                )
                    .textFieldStyle(.roundedBorder)
                if configuredSecretIDs.contains(field.id) {
                    Button(
                        clearSecretIDs.contains(field.id)
                            ? copy.pluginConfigurationKeepSecret
                            : copy.pluginConfigurationClearSecret
                    ) {
                        if clearSecretIDs.contains(field.id) {
                            clearSecretIDs.remove(field.id)
                        } else {
                            clearSecretIDs.insert(field.id)
                            secretInputs[field.id] = ""
                        }
                        clearMessages()
                    }
                    .buttonStyle(.borderless)
                }
            }
        case .text, .url, .integer, .decimal:
            TextField(field.localizedPlaceholder(for: language) ?? "", text: stringBinding(for: field))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stringBinding(for field: PluginConfigurationField) -> Binding<String> {
        Binding(
            get: { stringValue(for: field) },
            set: { value in
                switch field.kind {
                case .integer:
                    if let integer = Int64(value) {
                        publicValues[field.id] = .integer(integer)
                    } else {
                        publicValues[field.id] = .string(value)
                    }
                case .decimal:
                    if let decimal = Double(value) {
                        publicValues[field.id] = .decimal(decimal)
                    } else {
                        publicValues[field.id] = .string(value)
                    }
                default:
                    publicValues[field.id] = .string(value)
                }
                clearMessages()
            }
        )
    }

    private func boolBinding(for field: PluginConfigurationField) -> Binding<Bool> {
        Binding(
            get: {
                guard case let .boolean(value) = publicValues[field.id] ?? field.defaultValue else {
                    return false
                }
                return value
            },
            set: {
                publicValues[field.id] = .boolean($0)
                clearMessages()
            }
        )
    }

    private func secretBinding(for field: PluginConfigurationField) -> Binding<String> {
        Binding(
            get: { secretInputs[field.id] ?? "" },
            set: {
                secretInputs[field.id] = $0
                clearSecretIDs.remove(field.id)
                clearMessages()
            }
        )
    }

    private func stringValue(for field: PluginConfigurationField) -> String {
        switch publicValues[field.id] ?? field.defaultValue {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .decimal(value): return String(value)
        case let .boolean(value): return value ? "true" : "false"
        default: return ""
        }
    }

    private func secretStatus(for fieldID: String) -> String {
        if clearSecretIDs.contains(fieldID) {
            return copy.pluginConfigurationSecretNotConfigured
        }
        return configuredSecretIDs.contains(fieldID)
            ? copy.pluginConfigurationSecretConfigured
            : copy.pluginConfigurationSecretNotConfigured
    }

    private func save() {
        let secretValues = secretInputs.filter { _, value in !value.isEmpty }
        let submission = PluginConfigurationSubmission(
            publicValues: publicValues,
            secretValues: secretValues,
            clearSecretIDs: clearSecretIDs
        )
        do {
            try onSave(submission)
            configuredSecretIDs.subtract(clearSecretIDs)
            configuredSecretIDs.formUnion(secretValues.keys)
            clearSecretIDs.removeAll()
            secretInputs = secretInputs.mapValues { _ in "" }
            savedMessage = copy.pluginConfigurationSaved
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }

    private func reset() {
        do {
            try onReset()
            publicValues = [:]
            secretInputs = secretInputs.mapValues { _ in "" }
            configuredSecretIDs.removeAll()
            clearSecretIDs.removeAll()
            savedMessage = copy.pluginConfigurationSaved
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }

    private func clearMessages() {
        errorMessage = nil
        savedMessage = nil
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
