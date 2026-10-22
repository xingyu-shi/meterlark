import Foundation

enum PluginDashboardProtocol {
    static let currentVersion = 1
}

/// Resource limits shared by manifest mappings and provider-returned
/// dashboard documents. Both transports eventually render the same host UI,
/// so they must have the same structural bounds.
enum PluginDashboardLimits {
    static let maximumBlocks = 16
    static let maximumMetricTiles = 16
    static let maximumMetricColumns = 4
    static let maximumProgressItems = 64
}

enum PluginDashboardValidationError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case pluginIDMismatch(expected: String, actual: String)
    case duplicateIdentifier(String)
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidSystemImage(String)
    case invalidNumericValue(String)
    case invalidStatus(String)
    case limitExceeded(String, Int)
    case missingLifecycleMessage
    case invalidBlock(String)
}

extension PluginDashboardValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocolVersion(version):
            return "Unsupported dashboard protocol version: \(version)"
        case let .pluginIDMismatch(expected, actual):
            return "Dashboard plugin ID '\(actual)' does not match discovered plugin '\(expected)'."
        case let .duplicateIdentifier(identifier):
            return "Duplicate dashboard identifier: \(identifier)"
        case let .invalidIdentifier(path):
            return "Invalid dashboard identifier at \(path)."
        case let .invalidText(path):
            return "Invalid dashboard text at \(path)."
        case let .invalidSystemImage(path):
            return "Invalid system image at \(path)."
        case let .invalidNumericValue(path):
            return "Invalid numeric value at \(path)."
        case let .invalidStatus(path):
            return "Invalid status at \(path)."
        case let .limitExceeded(path, maximum):
            return "Dashboard content at \(path) exceeds the host limit of \(maximum)."
        case .missingLifecycleMessage:
            return "A non-ready lifecycle state requires a message."
        case let .invalidBlock(path):
            return "Invalid dashboard block at \(path)."
        }
    }
}

enum PluginDashboardFieldValidation {
    static func identifier(_ value: String, path: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw PluginDashboardValidationError.invalidIdentifier(path)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PluginDashboardValidationError.invalidIdentifier(path)
        }
    }

    static func text(_ value: String, path: String, maximumUTF8Length: Int = 500) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumUTF8Length,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginDashboardValidationError.invalidText(path)
        }
    }

    static func systemImage(_ value: String, path: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 100,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginDashboardValidationError.invalidSystemImage(path)
        }
    }
}

struct PluginTextPayload: Codable, Equatable, Sendable {
    let text: String
    let accessibilityText: String?
    let localizedText: PluginLocalizedText?
    let localizedAccessibilityText: PluginLocalizedText?

    init(text: String, accessibilityText: String? = nil) {
        self.text = text
        self.accessibilityText = accessibilityText
        self.localizedText = nil
        self.localizedAccessibilityText = nil
    }

    init(
        localizedText: PluginLocalizedText,
        accessibilityText: PluginLocalizedText? = nil
    ) {
        self.text = localizedText.fallback
        self.accessibilityText = accessibilityText?.fallback
        self.localizedText = localizedText.translations.isEmpty ? nil : localizedText
        self.localizedAccessibilityText = accessibilityText?.translations.isEmpty == false
            ? accessibilityText
            : nil
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case accessibilityText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let localizedText = try container.decode(PluginLocalizedText.self, forKey: .text)
        let localizedAccessibilityText = try container.decodeIfPresent(
            PluginLocalizedText.self,
            forKey: .accessibilityText
        )
        self.text = localizedText.fallback
        self.accessibilityText = localizedAccessibilityText?.fallback
        self.localizedText = localizedText.translations.isEmpty ? nil : localizedText
        self.localizedAccessibilityText = localizedAccessibilityText?.translations.isEmpty == false
            ? localizedAccessibilityText
            : nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localizedText ?? PluginLocalizedText(text), forKey: .text)
        let accessibility = localizedAccessibilityText ?? accessibilityText.map { PluginLocalizedText($0) }
        try container.encodeIfPresent(accessibility, forKey: .accessibilityText)
    }

    func makeModel(path: String, language: AppLanguage = .english) throws -> DashboardText {
        let displayText = localizedText ?? PluginLocalizedText(text)
        guard PluginLocalizedTextValidation.invalidPath(
            displayText,
            path: path,
            maximumUTF8Length: 500,
            trimWhitespace: true
        ) == nil else {
            throw PluginDashboardValidationError.invalidText(path)
        }
        let accessibleText = localizedAccessibilityText ?? accessibilityText.map { PluginLocalizedText($0) }
        if let accessibleText,
           PluginLocalizedTextValidation.invalidPath(
               accessibleText,
               path: "\(path).accessibilityText",
               maximumUTF8Length: 500,
               trimWhitespace: true
           ) != nil {
            throw PluginDashboardValidationError.invalidText("\(path).accessibilityText")
        }
        return DashboardText(
            displayText.resolve(for: language),
            accessibilityText: accessibleText?.resolve(for: language)
        )
    }
}

enum PluginLifecycleKind: String, Codable, Equatable, Sendable {
    case ready
    case loading
    case unavailable
    case error
    case stale
}

struct PluginLifecyclePayload: Codable, Equatable, Sendable {
    let kind: PluginLifecycleKind
    let message: PluginTextPayload?

    func makeModel(language: AppLanguage = .english) throws -> PluginLifecycleModel {
        guard kind == .ready || message != nil else {
            throw PluginDashboardValidationError.missingLifecycleMessage
        }
        return PluginLifecycleModel(
            kind: kind,
            message: try message?.makeModel(path: "lifecycle.message", language: language)
        )
    }
}

struct PluginLifecycleModel: Equatable, Sendable {
    let kind: PluginLifecycleKind
    let message: DashboardText?
}

enum PluginStatusKind: String, Codable, Equatable, Sendable {
    case normal
    case alert
    case disabled
    case noData

    var dashboardKind: DashboardStatus.Kind {
        switch self {
        case .normal: return .normal
        case .alert: return .alert
        case .disabled: return .disabled
        case .noData: return .noData
        }
    }
}

struct PluginStatusPayload: Codable, Equatable, Sendable {
    let kind: PluginStatusKind
    let text: PluginTextPayload

    func makeModel(path: String, language: AppLanguage = .english) throws -> DashboardStatus {
        DashboardStatus(
            kind: kind.dashboardKind,
            text: try text.makeModel(path: "\(path).text", language: language)
        )
    }
}

struct PluginStatusBadgePayload: Codable, Equatable, Sendable {
    let status: PluginStatusPayload
    let systemImage: String?

    func makeModel(path: String, language: AppLanguage = .english) throws -> DashboardStatusBadge {
        if let systemImage {
            try PluginDashboardFieldValidation.systemImage(systemImage, path: "\(path).systemImage")
        }
        return DashboardStatusBadge(
            status: try status.makeModel(path: "\(path).status", language: language),
            systemImage: systemImage
        )
    }
}

struct PluginMetricValuePayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case text
        case integer
        case decimal
        case currency
    }

    let kind: Kind
    let display: PluginTextPayload

    private let integerValue: Int64?
    private let decimalValue: Double?

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case display
    }

    init(text display: PluginTextPayload) {
        kind = .text
        self.display = display
        integerValue = nil
        decimalValue = nil
    }

    init(integer value: Int64, display: PluginTextPayload) {
        kind = .integer
        self.display = display
        integerValue = value
        decimalValue = nil
    }

    init(decimal value: Double, display: PluginTextPayload) {
        kind = .decimal
        self.display = display
        integerValue = nil
        decimalValue = value
    }

    init(currency value: Double, display: PluginTextPayload) {
        kind = .currency
        self.display = display
        integerValue = nil
        decimalValue = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        display = try container.decode(PluginTextPayload.self, forKey: .display)

        switch kind {
        case .text:
            guard !container.contains(.value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Text values must not contain a numeric value."
                )
            }
            integerValue = nil
            decimalValue = nil
        case .integer:
            integerValue = try container.decode(Int64.self, forKey: .value)
            decimalValue = nil
        case .decimal, .currency:
            integerValue = nil
            decimalValue = try container.decode(Double.self, forKey: .value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(display, forKey: .display)
        switch kind {
        case .text:
            break
        case .integer:
            try container.encode(integerValue, forKey: .value)
        case .decimal, .currency:
            try container.encode(decimalValue, forKey: .value)
        }
    }

    func makeModel(path: String, language: AppLanguage = .english) throws -> DashboardValue {
        let display = try display.makeModel(path: "\(path).display", language: language)
        switch kind {
        case .text:
            return .text(display)
        case .integer:
            guard let integerValue else {
                throw PluginDashboardValidationError.invalidNumericValue("\(path).value")
            }
            return .integer(value: integerValue, display: display)
        case .decimal:
            guard let decimalValue, decimalValue.isFinite else {
                throw PluginDashboardValidationError.invalidNumericValue("\(path).value")
            }
            return .decimal(value: decimalValue, display: display)
        case .currency:
            guard let decimalValue, decimalValue.isFinite else {
                throw PluginDashboardValidationError.invalidNumericValue("\(path).value")
            }
            return .currency(value: decimalValue, display: display)
        }
    }
}

struct PluginMetricTilePayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let header: PluginTextPayload
    let primary: PluginMetricValuePayload
    let detail: PluginTextPayload?

    func makeModel(path: String, language: AppLanguage = .english) throws -> MetricTileModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        return MetricTileModel(
            id: id,
            header: try header.makeModel(path: "\(path).header", language: language),
            primary: try primary.makeModel(path: "\(path).primary", language: language),
            detail: try detail?.makeModel(path: "\(path).detail", language: language)
        )
    }
}

struct PluginMetricGridPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let columns: Int
    let tiles: [PluginMetricTilePayload]

    func makeModel(path: String, language: AppLanguage = .english) throws -> MetricGridModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        guard (1...PluginDashboardLimits.maximumMetricColumns).contains(columns) else {
            throw PluginDashboardValidationError.invalidBlock("\(path).columns")
        }
        guard tiles.count <= PluginDashboardLimits.maximumMetricTiles else {
            throw PluginDashboardValidationError.limitExceeded(
                "\(path).tiles",
                PluginDashboardLimits.maximumMetricTiles
            )
        }
        let models = try tiles.enumerated().map { index, tile in
            try tile.makeModel(path: "\(path).tiles[\(index)]", language: language)
        }
        guard let model = MetricGridModel(columns: columns, tiles: models) else {
            if Set(models.map(\.id)).count != models.count {
                throw PluginDashboardValidationError.duplicateIdentifier("\(path).tiles")
            }
            throw PluginDashboardValidationError.invalidBlock(path)
        }
        return model
    }
}

struct PluginProgressListHeaderPayload: Codable, Equatable, Sendable {
    let title: PluginTextPayload
    let subtitle: PluginTextPayload?
    let trailingStatus: PluginStatusBadgePayload?

    func makeModel(path: String, language: AppLanguage = .english) throws -> ProgressListHeader {
        ProgressListHeader(
            title: try title.makeModel(path: "\(path).title", language: language),
            subtitle: try subtitle?.makeModel(path: "\(path).subtitle", language: language),
            trailingStatus: try trailingStatus?.makeModel(path: "\(path).trailingStatus", language: language)
        )
    }
}

struct PluginProgressItemPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: PluginTextPayload
    let current: Double
    let maximum: Double
    let value: PluginTextPayload
    let status: PluginStatusPayload

    func makeModel(path: String, language: AppLanguage = .english) throws -> ProgressItemModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        guard current.isFinite, maximum.isFinite, maximum > 0 else {
            throw PluginDashboardValidationError.invalidNumericValue("\(path).current/maximum")
        }
        let statusModel = try status.makeModel(path: "\(path).status", language: language)
        guard statusModel.kind == .normal || statusModel.kind == .alert else {
            throw PluginDashboardValidationError.invalidStatus("\(path).status")
        }
        guard let model = ProgressItemModel(
            id: id,
            label: try label.makeModel(path: "\(path).label", language: language),
            current: current,
            maximum: maximum,
            value: try value.makeModel(path: "\(path).value", language: language),
            status: statusModel
        ) else {
            throw PluginDashboardValidationError.invalidBlock(path)
        }
        return model
    }
}

struct PluginProgressUnavailableItemPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: PluginTextPayload
    let maximum: Double
    let message: PluginTextPayload
    let status: PluginStatusPayload

    func makeModel(path: String, language: AppLanguage = .english) throws -> ProgressUnavailableItemModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        guard maximum.isFinite, maximum > 0 else {
            throw PluginDashboardValidationError.invalidNumericValue("\(path).maximum")
        }
        let statusModel = try status.makeModel(path: "\(path).status", language: language)
        guard statusModel.kind == .noData else {
            throw PluginDashboardValidationError.invalidStatus("\(path).status")
        }
        guard let model = ProgressUnavailableItemModel(
            id: id,
            label: try label.makeModel(path: "\(path).label", language: language),
            maximum: maximum,
            message: try message.makeModel(path: "\(path).message", language: language),
            status: statusModel
        ) else {
            throw PluginDashboardValidationError.invalidBlock(path)
        }
        return model
    }
}

struct PluginValueItemPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: PluginTextPayload
    let value: PluginTextPayload
    let status: PluginStatusPayload

    func makeModel(path: String, language: AppLanguage = .english) throws -> ValueItemModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        return ValueItemModel(
            id: id,
            label: try label.makeModel(path: "\(path).label", language: language),
            value: try value.makeModel(path: "\(path).value", language: language),
            status: try status.makeModel(path: "\(path).status", language: language)
        )
    }
}

struct PluginStatusItemPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: PluginTextPayload
    let message: PluginTextPayload
    let status: PluginStatusPayload

    func makeModel(path: String, language: AppLanguage = .english) throws -> StatusItemModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        return StatusItemModel(
            id: id,
            label: try label.makeModel(path: "\(path).label", language: language),
            message: try message.makeModel(path: "\(path).message", language: language),
            status: try status.makeModel(path: "\(path).status", language: language)
        )
    }
}

enum PluginProgressListItemPayload: Codable, Equatable, Identifiable, Sendable {
    case progress(PluginProgressItemPayload)
    case progressUnavailable(PluginProgressUnavailableItemPayload)
    case value(PluginValueItemPayload)
    case status(PluginStatusItemPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case label
        case current
        case maximum
        case value
        case status
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "progress": self = .progress(try PluginProgressItemPayload(from: decoder))
        case "progressUnavailable": self = .progressUnavailable(try PluginProgressUnavailableItemPayload(from: decoder))
        case "value": self = .value(try PluginValueItemPayload(from: decoder))
        case "status": self = .status(try PluginStatusItemPayload(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown progress-list item type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .progress(item):
            try container.encode("progress", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.label, forKey: .label)
            try container.encode(item.current, forKey: .current)
            try container.encode(item.maximum, forKey: .maximum)
            try container.encode(item.value, forKey: .value)
            try container.encode(item.status, forKey: .status)
        case let .progressUnavailable(item):
            try container.encode("progressUnavailable", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.label, forKey: .label)
            try container.encode(item.maximum, forKey: .maximum)
            try container.encode(item.message, forKey: .message)
            try container.encode(item.status, forKey: .status)
        case let .value(item):
            try container.encode("value", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.label, forKey: .label)
            try container.encode(item.value, forKey: .value)
            try container.encode(item.status, forKey: .status)
        case let .status(item):
            try container.encode("status", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.label, forKey: .label)
            try container.encode(item.message, forKey: .message)
            try container.encode(item.status, forKey: .status)
        }
    }

    var id: String {
        switch self {
        case let .progress(item): return item.id
        case let .progressUnavailable(item): return item.id
        case let .value(item): return item.id
        case let .status(item): return item.id
        }
    }

    func makeModel(path: String, language: AppLanguage = .english) throws -> ProgressListItemModel {
        switch self {
        case let .progress(item): return .progress(try item.makeModel(path: path, language: language))
        case let .progressUnavailable(item): return .progressUnavailable(try item.makeModel(path: path, language: language))
        case let .value(item): return .value(try item.makeModel(path: path, language: language))
        case let .status(item): return .status(try item.makeModel(path: path, language: language))
        }
    }

}

struct PluginProgressListPayload: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let header: PluginProgressListHeaderPayload
    let items: [PluginProgressListItemPayload]

    func makeModel(path: String, language: AppLanguage = .english) throws -> ProgressListModel {
        try PluginDashboardFieldValidation.identifier(id, path: "\(path).id")
        guard items.count <= PluginDashboardLimits.maximumProgressItems else {
            throw PluginDashboardValidationError.limitExceeded(
                "\(path).items",
                PluginDashboardLimits.maximumProgressItems
            )
        }
        let itemModels = try items.enumerated().map { index, item in
            try item.makeModel(path: "\(path).items[\(index)]", language: language)
        }
        guard Set(itemModels.map(\.id)).count == itemModels.count else {
            throw PluginDashboardValidationError.duplicateIdentifier("\(path).items")
        }
        guard let model = ProgressListModel(
            header: try header.makeModel(path: "\(path).header", language: language),
            items: itemModels
        ) else {
            throw PluginDashboardValidationError.invalidBlock(path)
        }
        return model
    }
}

enum PluginDashboardBlockPayload: Codable, Equatable, Identifiable, Sendable {
    case metricGrid(PluginMetricGridPayload)
    case progressList(PluginProgressListPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case columns
        case tiles
        case header
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "metricGrid": self = .metricGrid(try PluginMetricGridPayload(from: decoder))
        case "progressList": self = .progressList(try PluginProgressListPayload(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown dashboard block type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .metricGrid(block):
            try container.encode("metricGrid", forKey: .type)
            try container.encode(block.id, forKey: .id)
            try container.encode(block.columns, forKey: .columns)
            try container.encode(block.tiles, forKey: .tiles)
        case let .progressList(block):
            try container.encode("progressList", forKey: .type)
            try container.encode(block.id, forKey: .id)
            try container.encode(block.header, forKey: .header)
            try container.encode(block.items, forKey: .items)
        }
    }

    var id: String {
        switch self {
        case let .metricGrid(block): return block.id
        case let .progressList(block): return block.id
        }
    }

    func makeModel(path: String, language: AppLanguage = .english) throws -> PluginDashboardBlockModel {
        switch self {
        case let .metricGrid(block):
            return .metricGrid(id: block.id, model: try block.makeModel(path: path, language: language))
        case let .progressList(block):
            return .progressList(id: block.id, model: try block.makeModel(path: path, language: language))
        }
    }

}

struct PluginDashboardDocument: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let pluginID: String
    let lifecycle: PluginLifecyclePayload
    let blocks: [PluginDashboardBlockPayload]

    func makeModel(
        for manifest: PluginManifest,
        language: AppLanguage = .english
    ) throws -> PluginDashboardModel {
        try manifest.validate()
        guard protocolVersion == PluginDashboardProtocol.currentVersion else {
            throw PluginDashboardValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard pluginID == manifest.id else {
            throw PluginDashboardValidationError.pluginIDMismatch(expected: manifest.id, actual: pluginID)
        }
        guard blocks.count <= PluginDashboardLimits.maximumBlocks else {
            throw PluginDashboardValidationError.limitExceeded(
                "blocks",
                PluginDashboardLimits.maximumBlocks
            )
        }

        let blockModels = try blocks.enumerated().map { index, block in
            try block.makeModel(path: "blocks[\(index)]", language: language)
        }
        guard Set(blockModels.map(\.id)).count == blockModels.count else {
            throw PluginDashboardValidationError.duplicateIdentifier("blocks")
        }
        return PluginDashboardModel(
            pluginID: pluginID,
            lifecycle: try lifecycle.makeModel(language: language),
            blocks: blockModels
        )
    }
}

struct PluginDashboardModel: Equatable, Sendable {
    let pluginID: String
    let lifecycle: PluginLifecycleModel
    let blocks: [PluginDashboardBlockModel]
}

enum PluginDashboardBlockModel: Equatable, Identifiable, Sendable {
    case metricGrid(id: String, model: MetricGridModel)
    case progressList(id: String, model: ProgressListModel)

    var id: String {
        switch self {
        case let .metricGrid(id, _), let .progressList(id, _): return id
        }
    }
}
