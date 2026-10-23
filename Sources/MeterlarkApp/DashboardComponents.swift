import AppKit
import SwiftUI

struct MetricGrid: View {
    let model: MetricGridModel

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: model.columns),
            spacing: 1
        ) {
            ForEach(model.tiles) { tile in
                MetricTile(model: tile)
            }
        }
    }
}

struct MetricTile: View {
    let model: MetricTileModel

    var body: some View {
        // Narrow columns shrink text onto one line instead of wrapping, so
        // every tile in a row keeps the same height.
        VStack(alignment: .leading, spacing: 5) {
            Text(model.header.text)
                .appFont(.metadataEmphasis)
                .foregroundStyle(DashboardComponentColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(model.primary.displayText)
                .appFont(.metric)
                .foregroundStyle(DashboardComponentColor.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .dashboardNumericValueTransition(value: model.primary)
            if let detail = model.detail {
                Text(detail.text)
                    .appFont(.metadata)
                    .foregroundStyle(DashboardComponentColor.subtle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(11)
        .background(AppSurfacePanelBackground())
        .overlay(Rectangle().stroke(DashboardComponentColor.line, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText)
    }
}

struct ProgressList: View {
    let model: ProgressListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            ForEach(model.items) { item in
                row(item)
            }
        }
        .padding(12)
        .background(AppSurfacePanelBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardComponentColor.line, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.header.title.text)
                    .appFont(.sectionSubtitle)
                    .foregroundStyle(DashboardComponentColor.primary)
                    .textCase(.uppercase)
                    .tracking(1.1)
                Spacer()
                if let badge = model.header.trailingStatus {
                    statusBadge(badge)
                }
            }
            if let subtitle = model.header.subtitle {
                Text(subtitle.text)
                    .appFont(.metadata)
                    .foregroundStyle(DashboardComponentColor.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.header.accessibilityText)
    }

    @ViewBuilder
    private func statusBadge(_ badge: DashboardStatusBadge) -> some View {
        Group {
            if let systemImage = badge.systemImage {
                Label(badge.status.text.text, systemImage: systemImage)
            } else {
                Text(badge.status.text.text)
            }
        }
        .appFont(.metadataEmphasis)
        .foregroundStyle(color(for: badge.status.kind, fallback: .muted))
    }

    @ViewBuilder
    private func row(_ item: ProgressListItemModel) -> some View {
        switch item {
        case let .progress(progress):
            progressRow(progress)
        case let .progressUnavailable(progress):
            unavailableProgressRow(progress)
        case let .value(value):
            valueRow(value)
        case let .status(status):
            statusRow(status)
        }
    }

    private func progressRow(_ item: ProgressItemModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label.text)
                    .appFont(.captionEmphasis)
                    .foregroundStyle(color(for: item.status.kind, fallback: .muted))
                Spacer()
                Text(item.value.text)
                    .appFont(item.status.kind.isAlerting ? .bodyAlert : .bodyEmphasis)
                    .foregroundStyle(color(for: item.status.kind, fallback: .primary))
                    .dashboardNumericValueTransition(value: item.value.text)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DashboardComponentColor.line.opacity(0.35))
                    Capsule()
                        .fill(color(for: item.status.kind, fallback: .signal))
                        .frame(width: geometry.size.width * item.progress)
                }
            }
            .frame(height: 3)
            .animation(.easeInOut(duration: 0.65), value: item.progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func unavailableProgressRow(_ item: ProgressUnavailableItemModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label.text)
                    .appFont(.captionEmphasis)
                    .foregroundStyle(color(for: item.status.kind, fallback: .muted))
                Spacer()
                Text(item.message.text)
                    .appFont(.caption)
                    .foregroundStyle(color(for: item.status.kind, fallback: .muted))
            }
            GeometryReader { _ in
                Capsule()
                    .fill(DashboardComponentColor.line.opacity(0.35))
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func valueRow(_ item: ValueItemModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(item.label.text)
                .appFont(.captionEmphasis)
                .foregroundStyle(color(for: item.status.kind, fallback: .muted))
            Spacer()
            Text(item.value.text)
                .appFont(.bodyEmphasis)
                .foregroundStyle(color(for: item.status.kind, fallback: .primary))
                .dashboardNumericValueTransition(value: item.value.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func statusRow(_ item: StatusItemModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(item.label.text)
                .appFont(.captionEmphasis)
                .foregroundStyle(color(for: item.status.kind, fallback: .muted))
            Spacer()
            Text(item.message.text)
                .appFont(.caption)
                .foregroundStyle(color(for: item.status.kind, fallback: .muted))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func color(
        for status: DashboardStatus.Kind,
        fallback: DashboardComponentColor.Value
    ) -> Color {
        switch status {
        case .alert: return DashboardComponentColor.alert
        case .disabled, .noData: return DashboardComponentColor.muted
        case .normal: return fallback.color
        }
    }
}

private enum DashboardComponentColor {
    enum Value {
        case muted
        case primary
        case signal

        var color: Color {
            switch self {
            case .muted: return DashboardComponentColor.muted
            case .primary: return DashboardComponentColor.primary
            case .signal: return DashboardComponentColor.signal
            }
        }
    }

    static let primary = AppWindowTheme.primary
    static let muted = AppWindowTheme.secondary
    static let subtle = AppWindowTheme.tertiary
    static let line = AppWindowTheme.separator
    static let signal = AppWindowTheme.signal
    static let alert = AppWindowTheme.alert
}

private extension View {
    func dashboardNumericValueTransition<Value: Equatable>(value: Value) -> some View {
        contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.55), value: value)
    }
}
