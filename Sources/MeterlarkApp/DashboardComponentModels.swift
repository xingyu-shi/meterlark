import Foundation

enum DashboardAccessibility {
    static func joined(_ values: [String?]) -> String {
        values.compactMap { $0 }.reduce(into: [String]()) { result, value in
            guard result.last != value else { return }
            result.append(value)
        }
        .joined(separator: ", ")
    }
}

struct DashboardText: Equatable, Sendable {
    let text: String
    let accessibilityText: String?

    init(_ text: String, accessibilityText: String? = nil) {
        self.text = text
        self.accessibilityText = accessibilityText
    }

    var spokenText: String {
        accessibilityText ?? text
    }
}

enum DashboardValueKind: Equatable, Sendable {
    case text
    case integer
    case decimal
    case currency
}

enum DashboardValue: Equatable, Sendable {
    case text(DashboardText)
    case integer(value: Int64, display: DashboardText)
    case decimal(value: Double, display: DashboardText)
    case currency(value: Double, display: DashboardText)

    var kind: DashboardValueKind {
        switch self {
        case .text: return .text
        case .integer: return .integer
        case .decimal: return .decimal
        case .currency: return .currency
        }
    }

    var displayText: String {
        switch self {
        case let .text(value): return value.text
        case let .integer(_, display), let .decimal(_, display), let .currency(_, display):
            return display.text
        }
    }

    var accessibilityText: String {
        switch self {
        case let .text(value): return value.spokenText
        case let .integer(_, display), let .decimal(_, display), let .currency(_, display):
            return display.spokenText
        }
    }
}

struct MetricTileModel: Equatable, Identifiable, Sendable {
    let id: String
    let header: DashboardText
    let primary: DashboardValue
    let detail: DashboardText?

    init(
        id: String,
        header: DashboardText,
        primary: DashboardValue,
        detail: DashboardText? = nil
    ) {
        self.id = id
        self.header = header
        self.primary = primary
        self.detail = detail
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([header.spokenText, primary.accessibilityText, detail?.spokenText])
    }
}

struct MetricGridModel: Equatable, Sendable {
    let columns: Int
    let tiles: [MetricTileModel]

    init?(columns: Int, tiles: [MetricTileModel]) {
        guard columns > 0 else { return nil }
        guard Set(tiles.map(\.id)).count == tiles.count else { return nil }
        self.columns = columns
        self.tiles = tiles
    }
}

struct DashboardStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case normal
        case alert
        case disabled
        case noData

        var isAlerting: Bool { self == .alert }
    }

    let kind: Kind
    let text: DashboardText

    init(kind: Kind, text: DashboardText) {
        self.kind = kind
        self.text = text
    }
}

struct DashboardStatusBadge: Equatable, Sendable {
    let status: DashboardStatus
    let systemImage: String?

    init(status: DashboardStatus, systemImage: String? = nil) {
        self.status = status
        self.systemImage = systemImage
    }
}

struct ProgressListHeader: Equatable, Sendable {
    let title: DashboardText
    let subtitle: DashboardText?
    let trailingStatus: DashboardStatusBadge?

    init(
        title: DashboardText,
        subtitle: DashboardText? = nil,
        trailingStatus: DashboardStatusBadge? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingStatus = trailingStatus
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([
            title.spokenText,
            subtitle?.spokenText,
            trailingStatus?.status.text.spokenText
        ])
    }
}

struct ProgressItemModel: Equatable, Identifiable, Sendable {
    let id: String
    let label: DashboardText
    let current: Double
    let maximum: Double
    let value: DashboardText
    let status: DashboardStatus

    init?(
        id: String,
        label: DashboardText,
        current: Double,
        maximum: Double,
        value: DashboardText,
        status: DashboardStatus
    ) {
        guard current.isFinite, maximum.isFinite, maximum > 0 else { return nil }
        guard status.kind == .normal || status.kind == .alert else { return nil }
        self.id = id
        self.label = label
        self.current = current
        self.maximum = maximum
        self.value = value
        self.status = status
    }

    var progress: Double {
        min(max(current / maximum, 0), 1)
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([label.spokenText, value.spokenText, status.text.spokenText])
    }
}

struct ProgressUnavailableItemModel: Equatable, Identifiable, Sendable {
    let id: String
    let label: DashboardText
    let maximum: Double
    let message: DashboardText
    let status: DashboardStatus

    init?(
        id: String,
        label: DashboardText,
        maximum: Double,
        message: DashboardText,
        status: DashboardStatus
    ) {
        guard maximum.isFinite, maximum > 0, status.kind == .noData else { return nil }
        self.id = id
        self.label = label
        self.maximum = maximum
        self.message = message
        self.status = status
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([label.spokenText, message.spokenText, status.text.spokenText])
    }
}

struct ValueItemModel: Equatable, Identifiable, Sendable {
    let id: String
    let label: DashboardText
    let value: DashboardText
    let status: DashboardStatus

    init(id: String, label: DashboardText, value: DashboardText, status: DashboardStatus) {
        self.id = id
        self.label = label
        self.value = value
        self.status = status
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([label.spokenText, value.spokenText, status.text.spokenText])
    }
}

struct StatusItemModel: Equatable, Identifiable, Sendable {
    let id: String
    let label: DashboardText
    let message: DashboardText
    let status: DashboardStatus

    init(id: String, label: DashboardText, message: DashboardText, status: DashboardStatus) {
        self.id = id
        self.label = label
        self.message = message
        self.status = status
    }

    var accessibilityText: String {
        DashboardAccessibility.joined([label.spokenText, message.spokenText, status.text.spokenText])
    }
}

enum ProgressListItemModel: Equatable, Identifiable, Sendable {
    case progress(ProgressItemModel)
    case progressUnavailable(ProgressUnavailableItemModel)
    case value(ValueItemModel)
    case status(StatusItemModel)

    var id: String {
        switch self {
        case let .progress(item): return item.id
        case let .progressUnavailable(item): return item.id
        case let .value(item): return item.id
        case let .status(item): return item.id
        }
    }

    var accessibilityText: String {
        switch self {
        case let .progress(item): return item.accessibilityText
        case let .progressUnavailable(item): return item.accessibilityText
        case let .value(item): return item.accessibilityText
        case let .status(item): return item.accessibilityText
        }
    }
}

struct ProgressListModel: Equatable, Sendable {
    let header: ProgressListHeader
    let items: [ProgressListItemModel]
    /// The title rendered for the current host language. Keeping this small
    /// presentation value on the model lets layout consumers use the same
    /// localized materialization as the dashboard without depending on the
    /// plugin localization schema.
    let layoutTitle: String

    init?(header: ProgressListHeader, items: [ProgressListItemModel], layoutTitle: String? = nil) {
        guard Set(items.map(\.id)).count == items.count else { return nil }
        self.header = header
        self.items = items
        self.layoutTitle = layoutTitle ?? header.title.text
    }
}
