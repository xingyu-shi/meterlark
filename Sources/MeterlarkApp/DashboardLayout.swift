import Foundation

enum DashboardBuiltInComponent: String, Equatable, Sendable {
    case summary
    case budget
    case daily
    case modelCatalog

    var id: String { "builtIn.\(rawValue)" }
}

enum DashboardComponentAvailability {
    static func includesModelCatalog(activeCatalogProviderCount: Int) -> Bool {
        activeCatalogProviderCount > 0
    }
}

enum DashboardLegacyComponentID {
    /// Layouts from the first model-catalog release may still contain this
    /// identifier. DashboardLayout.normalized(for:) drops it because it is no
    /// longer an available resident component.
    static let notificationFeed = "builtIn.notificationFeed"
}

enum DashboardPluginBlockKind: String, Equatable, Sendable {
    case metricGrid
    case progressList
}

enum DashboardLayoutComponentKind: Equatable, Sendable {
    case builtIn(DashboardBuiltInComponent)
    case pluginBlock(
        pluginID: String,
        blockID: String,
        blockKind: DashboardPluginBlockKind,
        itemCount: Int,
        defaultColumns: Int?
    )

    var columnRange: ClosedRange<Int>? {
        switch self {
        case .builtIn(.summary):
            return 1...4
        case let .pluginBlock(_, _, blockKind, itemCount, _):
            guard blockKind == .metricGrid else { return nil }
            return 1...max(1, min(4, itemCount))
        case .builtIn(.budget), .builtIn(.daily), .builtIn(.modelCatalog):
            return nil
        }
    }

    var defaultColumns: Int? {
        switch self {
        case .builtIn(.summary):
            return 2
        case let .pluginBlock(_, _, _, _, columns):
            return columns
        case .builtIn(.budget), .builtIn(.daily), .builtIn(.modelCatalog):
            return nil
        }
    }
}

struct DashboardLayoutComponent: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: DashboardLayoutComponentKind

    init(builtIn component: DashboardBuiltInComponent, title: String) {
        self.id = component.id
        self.title = title
        self.kind = .builtIn(component)
    }

    init(
        pluginID: String,
        blockID: String,
        title: String,
        blockKind: DashboardPluginBlockKind,
        itemCount: Int,
        defaultColumns: Int?
    ) {
        self.id = DashboardLayoutComponent.pluginComponentID(
            pluginID: pluginID,
            blockID: blockID
        )
        self.title = title
        self.kind = .pluginBlock(
            pluginID: pluginID,
            blockID: blockID,
            blockKind: blockKind,
            itemCount: itemCount,
            defaultColumns: defaultColumns
        )
    }

    var columnRange: ClosedRange<Int>? { kind.columnRange }

    var defaultColumns: Int? { kind.defaultColumns }

    static func pluginComponentID(pluginID: String, blockID: String) -> String {
        // Plugin and block IDs may both contain dots. A reserved separator
        // plus byte lengths makes the pair injective while keeping the ID
        // stable and readable. The old `plugin.<plugin>.<block>` form is
        // migrated by DashboardLayout.normalized(for:).
        "plugin~\(pluginID.utf8.count)~\(pluginID)~\(blockID.utf8.count)~\(blockID)"
    }

    static func legacyPluginComponentID(pluginID: String, blockID: String) -> String {
        "plugin.\(pluginID).\(blockID)"
    }
}

struct DashboardLayoutBlockDescriptor: Equatable, Sendable {
    let id: String
    let title: String
    let kind: DashboardPluginBlockKind
    let itemCount: Int
    let defaultColumns: Int?
}

enum DashboardLayoutValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidComponentIdentifier(String)
    case duplicateComponentIdentifier(String)
    case invalidColumns(String)
    case invalidPopoverHeight
}

extension DashboardLayoutValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported dashboard layout version: \(version)"
        case let .invalidComponentIdentifier(identifier):
            return "Dashboard component identifier is invalid: \(identifier)"
        case let .duplicateComponentIdentifier(field):
            return "Dashboard layout contains a duplicate identifier at \(field)."
        case let .invalidColumns(identifier):
            return "Dashboard layout columns are invalid for \(identifier)."
        case .invalidPopoverHeight:
            return "Dashboard popover height is invalid."
        }
    }
}

struct DashboardLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    // A plugin ID and a dashboard block ID are each allowed up to 128 bytes;
    // the unambiguous namespaced form adds separators and length fields.
    static let maximumIdentifierUTF8Length = 512

    var layoutVersion: Int
    var componentOrder: [String]
    var hiddenComponentIDs: [String]
    var componentColumns: [String: Int]

    static let `default` = DashboardLayout()

    init(
        layoutVersion: Int = Self.currentVersion,
        componentOrder: [String] = [],
        hiddenComponentIDs: [String] = [],
        componentColumns: [String: Int] = [:]
    ) {
        self.layoutVersion = layoutVersion
        self.componentOrder = componentOrder
        self.hiddenComponentIDs = hiddenComponentIDs
        self.componentColumns = componentColumns
    }

    private enum CodingKeys: String, CodingKey {
        case layoutVersion
        case componentOrder
        case hiddenComponentIDs
        case componentColumns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? Self.currentVersion
        componentOrder = try container.decodeIfPresent([String].self, forKey: .componentOrder) ?? []
        hiddenComponentIDs = try container.decodeIfPresent([String].self, forKey: .hiddenComponentIDs) ?? []
        componentColumns = try container.decodeIfPresent([String: Int].self, forKey: .componentColumns) ?? [:]
    }

    func validate() throws {
        guard layoutVersion == Self.currentVersion else {
            throw DashboardLayoutValidationError.unsupportedVersion(layoutVersion)
        }
        try validateIdentifiers(componentOrder, field: "componentOrder")
        try validateIdentifiers(hiddenComponentIDs, field: "hiddenComponentIDs")
        for (identifier, columns) in componentColumns {
            guard Self.isValidIdentifier(identifier) else {
                throw DashboardLayoutValidationError.invalidComponentIdentifier(identifier)
            }
            guard columns > 0 else {
                throw DashboardLayoutValidationError.invalidColumns(identifier)
            }
        }
    }

    /// Aligns a persisted layout with the components that are currently
    /// available. Unknown components are ignored for this projection, while
    /// new components are appended in host/provider order.
    func normalized(for components: [DashboardLayoutComponent]) -> DashboardLayout {
        let availableIDs = components.map(\.id)
        let availableSet = Set(availableIDs)
        let aliases = Self.componentIdentifierAliases(for: components)
        let legacyByCurrentID = aliases.reduce(into: [String: String]()) { result, pair in
            result[pair.value] = pair.key
        }
        let order = Self.stableOrder(
            requested: componentOrder.map { aliases[$0] ?? $0 },
            available: availableIDs
        )
        var hidden = [String]()
        var seenHidden = Set<String>()
        for identifier in hiddenComponentIDs.map({ aliases[$0] ?? $0 })
        where availableSet.contains(identifier) {
            if seenHidden.insert(identifier).inserted {
                hidden.append(identifier)
            }
        }
        var columns = [String: Int]()

        for component in components {
            let persistedIdentifier = legacyByCurrentID[component.id]
            let raw = componentColumns[component.id] ?? persistedIdentifier.flatMap {
                componentColumns[$0]
            }
            guard let raw, raw > 0,
                  let range = component.columnRange else {
                continue
            }
            columns[component.id] = min(max(raw, range.lowerBound), range.upperBound)
        }

        return DashboardLayout(
            layoutVersion: Self.currentVersion,
            componentOrder: order,
            hiddenComponentIDs: hidden,
            componentColumns: columns
        )
    }

    func isVisible(_ componentID: String) -> Bool {
        !hiddenComponentIDs.contains(componentID)
    }

    func columns(for componentID: String, default defaultColumns: Int) -> Int {
        componentColumns[componentID] ?? defaultColumns
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumIdentifierUTF8Length else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func componentIdentifierAliases(
        for components: [DashboardLayoutComponent]
    ) -> [String: String] {
        var candidates = [String: [String]]()
        for component in components {
            guard case let .pluginBlock(pluginID, blockID, _, _, _) = component.kind else {
                continue
            }
            let legacyID = DashboardLayoutComponent.legacyPluginComponentID(
                pluginID: pluginID,
                blockID: blockID
            )
            candidates[legacyID, default: []].append(component.id)
        }

        // A legacy ID can itself be ambiguous. In that case there is no safe
        // way to infer which block an old persisted setting targeted, so drop
        // the alias and let both components receive their normal defaults.
        return candidates.reduce(into: [String: String]()) { result, entry in
            guard entry.value.count == 1, let currentID = entry.value.first else { return }
            result[entry.key] = currentID
        }
    }

    private func validateIdentifiers(_ identifiers: [String], field: String) throws {
        var seen = Set<String>()
        for identifier in identifiers {
            guard Self.isValidIdentifier(identifier) else {
                throw DashboardLayoutValidationError.invalidComponentIdentifier(identifier)
            }
            guard seen.insert(identifier).inserted else {
                throw DashboardLayoutValidationError.duplicateComponentIdentifier(field)
            }
        }
    }

    private static func stableOrder(requested: [String], available: [String]) -> [String] {
        let availableSet = Set(available)
        var seen = Set<String>()
        var result = [String]()
        for identifier in requested where availableSet.contains(identifier) {
            if seen.insert(identifier).inserted {
                result.append(identifier)
            }
        }
        for identifier in available where seen.insert(identifier).inserted {
            result.append(identifier)
        }
        return result
    }
}

struct DashboardLayoutStore {
    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseURL = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
    }

    var fileURL: URL {
        baseURL.appendingPathComponent("DashboardLayout.json", isDirectory: false)
    }

    func load() throws -> DashboardLayout? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let layout = try JSONDecoder().decode(DashboardLayout.self, from: Data(contentsOf: fileURL))
        try layout.validate()
        return layout
    }

    func loadOrDefault() -> DashboardLayout {
        (try? load()) ?? .default
    }

    func save(_ layout: DashboardLayout) throws {
        try layout.validate()
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(layout).write(to: fileURL, options: [.atomic])
    }

    func remove() throws {
        try? fileManager.removeItem(at: fileURL)
    }
}

enum DashboardLayoutMetrics {
    static func estimatedPopoverHeight(
        components: [DashboardLayoutComponent],
        layout: DashboardLayout = .default,
        interfaceTextSize: InterfaceTextSize
    ) -> Double {
        let scale = interfaceTextSize.scale
        let visibleHeight = components.reduce(0.0) { total, component in
            total + estimatedHeight(
                for: component,
                layout: layout,
                interfaceTextSize: interfaceTextSize
            )
        }
        let shell = (64 + 70) * scale
        let padding = interfaceTextSize.contentPadding * 2
        let spacing = Double(max(0, components.count + 1)) * interfaceTextSize.sectionSpacing
        let estimated = shell + padding + spacing + visibleHeight
        return min(
            MonitorSettings.maximumPopoverHeight,
            max(MonitorSettings.minimumPopoverHeight, ceil(estimated))
        )
    }

    private static func estimatedHeight(
        for component: DashboardLayoutComponent,
        layout: DashboardLayout,
        interfaceTextSize: InterfaceTextSize
    ) -> Double {
        let scale = interfaceTextSize.scale
        switch component.kind {
        case .builtIn(.summary):
            let columns = layout.columns(for: component.id, default: component.defaultColumns ?? 2)
            let rows = Double((4 + columns - 1) / columns)
            return rows * (interfaceTextSize.summaryTileHeight + 36) + 8
        case .builtIn(.budget):
            return 122 * scale
        case .builtIn(.daily):
            return (295 * scale) + interfaceTextSize.detailPreviewHeight
        case .builtIn(.modelCatalog):
            return 116 * scale
        case let .pluginBlock(_, _, kind, itemCount, columns):
            switch kind {
            case .metricGrid:
                let columnCount = layout.columns(for: component.id, default: columns ?? 2)
                let rows = Double(max(1, (max(1, itemCount) + columnCount - 1) / columnCount))
                return rows * (interfaceTextSize.summaryTileHeight + 36) + 28 * scale
            case .progressList:
                return (64 + Double(max(1, itemCount)) * 39) * scale
            }
        }
    }
}

extension PluginDashboardTemplateBlock {
    var layoutKind: DashboardPluginBlockKind {
        switch self {
        case .metricGrid: return .metricGrid
        case .progressList: return .progressList
        }
    }

    var layoutItemCount: Int {
        switch self {
        case let .metricGrid(grid): return grid.tiles.count
        case let .progressList(list): return list.items.count
        }
    }

    var layoutColumns: Int? {
        switch self {
        case let .metricGrid(grid): return grid.columns
        case .progressList: return nil
        }
    }
}

extension PluginDashboardBlockModel {
    /// A model does not carry a separate block title for metric grids, while
    /// progress lists expose their provider-defined header title. The layout
    /// editor still needs a stable human-readable label, so use the block ID
    /// as the metric-grid fallback.
    var layoutTitle: String {
        switch self {
        case let .metricGrid(id, _):
            return id
        case let .progressList(_, list):
            return list.layoutTitle
        }
    }

    var layoutKind: DashboardPluginBlockKind {
        switch self {
        case .metricGrid: return .metricGrid
        case .progressList: return .progressList
        }
    }

    var layoutItemCount: Int {
        switch self {
        case let .metricGrid(_, grid): return grid.tiles.count
        case let .progressList(_, list): return list.items.count
        }
    }

    var layoutColumns: Int? {
        switch self {
        case let .metricGrid(_, grid): return grid.columns
        case .progressList: return nil
        }
    }
}
