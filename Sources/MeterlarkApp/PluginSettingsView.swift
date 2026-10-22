import SwiftUI

struct PluginSettingsView: View {
    @ObservedObject var store: MonitorStore
    let onClose: () -> Void

    private var copy: L10n { L10n(language: store.settings.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !store.pluginStates.isEmpty {
                pluginStatusSection
            }

            if store.externalPluginManagementAvailable {
                externalPluginSection
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(copy.done, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 480, minHeight: 360)
        .background(AppSurfaceBackground(style: store.settings.surfaceStyle))
        .background(WindowAppearanceBridge(
            appearance: store.settings.appearance,
            surfaceStyle: store.settings.surfaceStyle
        ))
        .preferredColorScheme(preferredColorScheme)
        .appInterfaceTextSize(store.settings.interfaceTextSize)
        .environment(\.appSurfaceStyle, store.settings.surfaceStyle)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(copy.pluginSettingsTitle)
                .appFont(.section)
                .foregroundStyle(AppWindowTheme.primary)
            Text(copy.pluginSettingsSubtitle)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pluginStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.activeProviders)
                .appFont(.captionEmphasis)
                .foregroundStyle(AppWindowTheme.secondary)

            ForEach(store.pluginStates) { snapshot in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(AppWindowTheme.secondary)
                    Text(snapshot.manifest.localizedDisplayName(for: store.settings.language))
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(AppWindowTheme.primary)
                    Spacer()
                    Text(statusText(for: snapshot.runtime.phase))
                        .appFont(.metadata)
                        .foregroundStyle(statusColor(for: snapshot.runtime.phase))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var externalPluginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.externalPlugins)
                .appFont(.sectionSubtitle)
                .foregroundStyle(AppWindowTheme.primary)

            if store.externalPlugins.isEmpty {
                Text(copy.noExternalPlugins)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
            } else {
                ForEach(store.externalPlugins) { plugin in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .foregroundStyle(AppWindowTheme.secondary)
                            Text(plugin.manifest.localizedDisplayName(for: store.settings.language))
                                .appFont(.bodyEmphasis)
                                .foregroundStyle(AppWindowTheme.primary)
                            Text(plugin.manifest.version)
                                .appFont(.metadata)
                                .foregroundStyle(AppWindowTheme.secondary)
                            Spacer()
                            if plugin.hasConfigurationSchema {
                                Button {
                                    store.showPluginConfiguration(pluginID: plugin.id)
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .buttonStyle(.borderless)
                                .help(copy.configurePlugin)
                                .accessibilityLabel(copy.configurePlugin)
                            }
                            Toggle(
                                copy.externalPluginEnable,
                                isOn: Binding(
                                    get: { plugin.enabled },
                                    set: { store.setExternalPluginEnabled(pluginID: plugin.id, enabled: $0) }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!plugin.canToggle)
                        }

                        if let validationMessage = plugin.validationMessage {
                            Text(validationMessage)
                                .appFont(.metadata)
                                .foregroundStyle(AppWindowTheme.alert)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !plugin.enabled {
                            Text(copy.externalPluginDisabled)
                                .appFont(.metadata)
                                .foregroundStyle(AppWindowTheme.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            if !store.externalPluginIssues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(copy.pluginDiscoveryIssues, systemImage: "exclamationmark.triangle")
                        .appFont(.captionEmphasis)
                        .foregroundStyle(AppWindowTheme.alert)

                    ForEach(store.externalPluginIssues) { issue in
                        Text("\(issueLocation(issue)): \(issue.detail)")
                            .appFont(.metadata)
                            .foregroundStyle(AppWindowTheme.alert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(AppSurfacePanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button(copy.installExternalPlugin, action: store.chooseAndInstallExternalPlugin)

            if let externalPluginError = store.externalPluginError {
                Text(externalPluginError)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func statusText(for phase: PluginRuntimePhase) -> String {
        switch phase {
        case .idle: return copy.pluginIdle
        case .loading: return copy.pluginLoading
        case .ready: return copy.pluginReady
        case .unavailable: return copy.pluginUnavailable
        case .stale: return copy.pluginStale
        case .failed: return copy.pluginFailed
        }
    }

    private func statusColor(for phase: PluginRuntimePhase) -> Color {
        switch phase {
        case .ready: return AppWindowTheme.signal
        case .stale, .failed: return AppWindowTheme.alert
        case .idle, .loading, .unavailable: return AppWindowTheme.secondary
        }
    }

    private func issueLocation(_ issue: PluginDiscoveryIssue) -> String {
        let url = URL(fileURLWithPath: issue.path)
        if url.lastPathComponent == "plugin.json" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.lastPathComponent.isEmpty ? issue.path : url.lastPathComponent
    }
}
