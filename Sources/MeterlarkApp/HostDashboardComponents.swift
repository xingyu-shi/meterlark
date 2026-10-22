import SwiftUI

struct ModelCatalogDashboardView: View {
    @ObservedObject var store: MonitorStore

    private var copy: L10n { L10n(language: store.settings.language) }

    var body: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(copy.modelCatalogTitle, systemImage: "square.grid.2x2.fill")
                        .appFont(.sectionSubtitle)
                        .foregroundStyle(AppWindowTheme.primary)
                    Spacer(minLength: 0)
                    Text(statusLabel)
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(statusColor)
                }
                HStack(spacing: 18) {
                    summaryValue(copy.modelCatalogRecordCount, value: "\(store.modelCatalogStatus.recordCount)")
                    summaryValue(copy.modelCatalogProviderCount, value: "\(store.modelCatalogStatus.providerCount)")
                    Spacer(minLength: 0)
                    Button(copy.searchModels) {
                        store.showModelCatalog()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.hasModelCatalogEntries && !store.hasCustomPricing)
                }
                if let error = store.modelCatalogStatus.lastError {
                    Text(error)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.alert)
                        .lineLimit(2)
                } else if store.modelCatalogStatus.phase == .idle {
                    Text(copy.modelCatalogWaiting)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                }
            }
        }
    }

    private func summaryValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
            Text(value)
                .appFont(.bodyEmphasis)
                .foregroundStyle(AppWindowTheme.primary)
        }
    }

    private var statusLabel: String {
        switch store.modelCatalogStatus.phase {
        case .idle: return copy.pluginIdle
        case .loading: return copy.pluginLoading
        case .ready: return copy.pluginReady
        case .stale: return copy.pluginStale
        case .failed: return copy.pluginFailed
        }
    }

    private var statusColor: Color {
        switch store.modelCatalogStatus.phase {
        case .ready: return AppWindowTheme.signal
        case .stale, .failed: return AppWindowTheme.alert
        case .idle, .loading: return AppWindowTheme.secondary
        }
    }
}
