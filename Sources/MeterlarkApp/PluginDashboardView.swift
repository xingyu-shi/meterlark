import SwiftUI

struct PluginDashboardView: View {
    let model: PluginDashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.lifecycle.kind {
            case .ready:
                blocks
            case .stale:
                lifecycleMessage
                blocks
            case .loading, .unavailable, .error:
                lifecycleMessage
            }
        }
    }

    @ViewBuilder
    private var blocks: some View {
        ForEach(model.blocks) { block in
            PluginDashboardBlockView(block: block)
        }
    }

    private var lifecycleMessage: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AppWindowTheme.secondary)
                .frame(width: 5, height: 5)
            Text(model.lifecycle.message?.text ?? model.lifecycle.kind.rawValue)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PluginDashboardBlockView: View {
    let block: PluginDashboardBlockModel

    var body: some View {
        switch block {
        case let .metricGrid(_, grid):
            MetricGrid(model: grid)
        case let .progressList(_, list):
            ProgressList(model: list)
        }
    }
}

struct PluginDashboardComponentView: View {
    let snapshot: DashboardPluginRuntimeSnapshot
    let blockID: String
    let title: String
    let columns: Int?
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(.sectionSubtitle)
                .foregroundStyle(AppWindowTheme.primary)

            if let dashboard = snapshot.runtime.dashboard,
               let block = dashboard.blocks.first(where: { $0.id == blockID }) {
                if snapshot.runtime.phase == .stale,
                   let message = snapshot.runtime.message,
                   !message.isEmpty {
                    lifecycleMessage(message, tint: AppWindowTheme.alert)
                }
                PluginDashboardBlockView(block: block.withColumns(columns))
            } else {
                lifecycleMessage(
                    snapshot.runtime.message ?? phaseText(snapshot.runtime.phase),
                    tint: snapshot.runtime.phase == .failed ? AppWindowTheme.alert : AppWindowTheme.secondary
                )
            }
        }
    }

    private func lifecycleMessage(_ message: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(message)
                .appFont(.metadata)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func phaseText(_ phase: PluginRuntimePhase) -> String {
        switch phase {
        case .idle: return copy.pluginIdle
        case .loading: return copy.pluginLoading
        case .ready: return copy.pluginReady
        case .unavailable: return copy.pluginUnavailable
        case .stale: return copy.pluginStale
        case .failed: return copy.pluginFailed
        }
    }
}

private extension PluginDashboardBlockModel {
    func withColumns(_ columns: Int?) -> PluginDashboardBlockModel {
        guard let columns else { return self }
        switch self {
        case let .metricGrid(id, grid):
            return .metricGrid(
                id: id,
                model: MetricGridModel(columns: columns, tiles: grid.tiles) ?? grid
            )
        case .progressList:
            return self
        }
    }
}
