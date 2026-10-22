import AppKit
import SwiftUI

struct ModelCatalogProjectionRevision: Equatable {
    let customPricingRevision: String?
    let modelCatalogRevision: String?
    let modelCatalogEntryProjectionRevision: String?
}

private struct ModelCatalogFilterCacheKey: Equatable {
    let projectionRevision: ModelCatalogProjectionRevision
    let query: String
    let provider: String
    let modality: String
    let capability: ModelCatalogCapabilityFilter
    let priceRange: ModelCatalogPriceRange
    let contextRange: ModelCatalogContextRange
}

/// Caches the last filter projection. SwiftUI can reevaluate a view body for
/// every keystroke, including the 250 ms period where the applied query has
/// not changed yet. The raw query is deliberately not part of this key: only
/// the debounced `appliedQuery` changes the result set.
final class ModelCatalogFilterCache {
    private var key: ModelCatalogFilterCacheKey?
    private var value: [ModelCatalogEntry] = []

    func filteredEntries(
        _ entries: [ModelCatalogEntry],
        projectionRevision: ModelCatalogProjectionRevision,
        query: String,
        provider: String,
        modality: String,
        capability: ModelCatalogCapabilityFilter,
        priceRange: ModelCatalogPriceRange,
        contextRange: ModelCatalogContextRange
    ) -> [ModelCatalogEntry] {
        let nextKey = ModelCatalogFilterCacheKey(
            projectionRevision: projectionRevision,
            query: query,
            provider: provider,
            modality: modality,
            capability: capability,
            priceRange: priceRange,
            contextRange: contextRange
        )
        if key == nextKey {
            return value
        }

        value = ModelCatalogFilter.filter(
            entries,
            query: query,
            provider: provider,
            modality: modality,
            capability: capability,
            priceRange: priceRange,
            contextRange: contextRange
        )
        key = nextKey
        return value
    }
}

/// Window-owned state is kept outside the value view so replacing an
/// NSHostingView root during a catalog refresh does not reset the user's
/// search, filters, or selected model.
final class ModelCatalogViewState: ObservableObject {
    @Published var query = ""
    @Published var appliedQuery = ""
    @Published var selectedID: String?
    @Published var selectedProvider = ""
    @Published var selectedModality = ""
    @Published var selectedCapability: ModelCatalogCapabilityFilter = .any
    @Published var selectedPriceRange: ModelCatalogPriceRange = .any
    @Published var selectedContextRange: ModelCatalogContextRange = .any

    fileprivate let filterCache = ModelCatalogFilterCache()
}

struct ModelCatalogView: View {
    let entries: [ModelCatalogEntry]
    let language: AppLanguage
    let interfaceTextSize: InterfaceTextSize
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle
    let projectionRevision: ModelCatalogProjectionRevision
    @ObservedObject private var state: ModelCatalogViewState

    init(
        entries: [ModelCatalogEntry],
        language: AppLanguage,
        state: ModelCatalogViewState,
        projectionRevision: ModelCatalogProjectionRevision,
        interfaceTextSize: InterfaceTextSize = .standard,
        appearance: AppAppearance = .automatic,
        surfaceStyle: AppSurfaceStyle = .solid
    ) {
        self.entries = entries
        self.language = language
        self.interfaceTextSize = interfaceTextSize
        self.appearance = appearance
        self.surfaceStyle = surfaceStyle
        self.projectionRevision = projectionRevision
        self._state = ObservedObject(wrappedValue: state)
    }

    private var copy: L10n { L10n(language: language) }

    private var filteredEntries: [ModelCatalogEntry] {
        state.filterCache.filteredEntries(
            entries,
            projectionRevision: projectionRevision,
            query: state.appliedQuery,
            provider: state.selectedProvider,
            modality: state.selectedModality,
            capability: state.selectedCapability,
            priceRange: state.selectedPriceRange,
            contextRange: state.selectedContextRange
        )
    }

    private var providers: [String] {
        entries.compactMap(\.provider).reduce(into: Set<String>()) { $0.insert($1) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var modalities: [String] {
        entries.flatMap(\.modalities).reduce(into: Set<String>()) { $0.insert($1) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var activeFilterCount: Int {
        (state.selectedProvider.isEmpty ? 0 : 1)
            + (state.selectedModality.isEmpty ? 0 : 1)
            + (state.selectedCapability == .any ? 0 : 1)
            + (state.selectedPriceRange == .any ? 0 : 1)
            + (state.selectedContextRange == .any ? 0 : 1)
    }

    private var hasActiveFilters: Bool { activeFilterCount > 0 }

    private var selectedEntry: ModelCatalogEntry? {
        guard let selectedID = state.selectedID else { return filteredEntries.first }
        return filteredEntries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        AppWindowShell(
            title: copy.modelCatalogTitle,
            subtitle: copy.modelCatalogSubtitle,
            mark: .symbol("square.grid.2x2.fill"),
            interfaceTextSize: interfaceTextSize,
            appearance: appearance,
            surfaceStyle: surfaceStyle,
            width: interfaceTextSize.modelCatalogWidth,
            height: interfaceTextSize.modelCatalogHeight
        ) {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(copy.modelCatalogModels(filteredEntries.count, entries.count))
                            .appFont(.metadata)
                            .foregroundStyle(AppWindowTheme.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)

                    filterBar

                    Divider()

                    if filteredEntries.isEmpty {
                        Text(copy.modelCatalogNoResults)
                            .appFont(.body)
                            .foregroundStyle(AppWindowTheme.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredEntries, selection: $state.selectedID) { entry in
                            ModelCatalogListRow(entry: entry, language: language)
                                .tag(entry.id)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .background(AppSurfacePanelBackground())
                    }
                }
                .background(AppSurfacePanelBackground())
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 330)
            } detail: {
                if let selectedEntry {
                    ModelCatalogDetailView(entry: selectedEntry, language: language)
                } else {
                    Text(copy.modelCatalogSelect)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .searchable(text: $state.query, placement: .sidebar, prompt: copy.modelCatalogSearchPrompt)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppWindowTheme.canvas)
        }
        .onAppear {
            reconcileRemovedFilters()
            selectFirstFilteredEntry()
        }
        .onChange(of: entries) { _ in
            // Keep the detail pane usable when the selected model disappears
            // during a catalog refresh. Reconcile provider/modality filters as
            // well so a removed remote value cannot strand the list at zero.
            reconcileRemovedFilters()
            selectFirstFilteredEntry()
        }
        .task(id: state.query) {
            guard !state.query.isEmpty else {
                state.appliedQuery = ""
                return
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                state.appliedQuery = state.query
            } catch {
                // A newer keystroke cancels this pending search update.
            }
        }
        .onChange(of: state.appliedQuery) { _ in
            selectFirstFilteredEntry()
        }
        .onChange(of: state.selectedProvider) { _ in
            selectFirstFilteredEntry()
        }
        .onChange(of: state.selectedModality) { _ in
            selectFirstFilteredEntry()
        }
        .onChange(of: state.selectedCapability) { _ in
            selectFirstFilteredEntry()
        }
        .onChange(of: state.selectedPriceRange) { _ in
            selectFirstFilteredEntry()
        }
        .onChange(of: state.selectedContextRange) { _ in
            selectFirstFilteredEntry()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Menu {
                    filterChoice(copy.modelCatalogAllProviders, selected: state.selectedProvider.isEmpty) {
                        state.selectedProvider = ""
                    }
                    ForEach(providers, id: \.self) { provider in
                        filterChoice(provider, selected: state.selectedProvider == provider) {
                            state.selectedProvider = provider
                        }
                    }
                } label: {
                    Label(copy.modelCatalogProviderFilter, systemImage: "server.rack")
                }

                Menu {
                    filterChoice(copy.modelCatalogAnyModality, selected: state.selectedModality.isEmpty) {
                        state.selectedModality = ""
                    }
                    ForEach(modalities, id: \.self) { modality in
                        filterChoice(modality, selected: state.selectedModality == modality) {
                            state.selectedModality = modality
                        }
                    }
                } label: {
                    Label(copy.modelCatalogModalityFilter, systemImage: "circle.grid.2x2")
                }

                Menu {
                    filterChoice(copy.modelCatalogAnyCapability, selected: state.selectedCapability == .any) {
                        state.selectedCapability = .any
                    }
                    ForEach(ModelCatalogCapabilityFilter.allCases.filter { $0 != .any }) { capability in
                        filterChoice(capability.label(copy), selected: state.selectedCapability == capability) {
                            state.selectedCapability = capability
                        }
                    }
                } label: {
                    Label(copy.modelCatalogCapabilityFilter, systemImage: "checkmark.seal")
                }

                Menu {
                    filterChoice(copy.modelCatalogAnyPrice, selected: state.selectedPriceRange == .any) {
                        state.selectedPriceRange = .any
                    }
                    ForEach(ModelCatalogPriceRange.allCases.filter { $0 != .any }) { range in
                        filterChoice(range.label(copy), selected: state.selectedPriceRange == range) {
                            state.selectedPriceRange = range
                        }
                    }
                } label: {
                    Label(copy.modelCatalogPriceFilter, systemImage: "dollarsign.circle")
                }

                Menu {
                    filterChoice(copy.modelCatalogAnyContext, selected: state.selectedContextRange == .any) {
                        state.selectedContextRange = .any
                    }
                    ForEach(ModelCatalogContextRange.allCases.filter { $0 != .any }) { range in
                        filterChoice(range.label(copy), selected: state.selectedContextRange == range) {
                            state.selectedContextRange = range
                        }
                    }
                } label: {
                    Label(copy.modelCatalogContextFilter, systemImage: "text.alignleft")
                }

                Divider()
                Button {
                    clearFilters()
                } label: {
                    Label(copy.modelCatalogClearFilters, systemImage: "xmark.circle")
                }
                .disabled(!hasActiveFilters)
            } label: {
                Label(
                    activeFilterCount == 0 ? copy.modelCatalogFilters : "\(copy.modelCatalogFilters) · \(activeFilterCount)",
                    systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
            .menuStyle(.borderlessButton)
            .appFont(.metadataEmphasis)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func filterChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark" : "circle")
        }
    }

    private func clearFilters() {
        state.selectedProvider = ""
        state.selectedModality = ""
        state.selectedCapability = .any
        state.selectedPriceRange = .any
        state.selectedContextRange = .any
    }

    private func reconcileRemovedFilters() {
        let validProviders = Set(providers)
        let validModalities = Set(modalities)
        if !state.selectedProvider.isEmpty,
           !validProviders.contains(state.selectedProvider) {
            state.selectedProvider = ""
        }
        if !state.selectedModality.isEmpty,
           !validModalities.contains(state.selectedModality) {
            state.selectedModality = ""
        }
    }

    private func selectFirstFilteredEntry() {
        guard state.selectedID == nil || !filteredEntries.contains(where: { $0.id == state.selectedID }) else { return }
        state.selectedID = filteredEntries.first?.id
    }
}

enum ModelCatalogCapabilityFilter: String, CaseIterable, Identifiable {
    case any = ""
    case functionCalling = "supports_function_calling"
    case vision = "supports_vision"
    case reasoning = "supports_reasoning"
    case promptCaching = "supports_prompt_caching"
    case toolChoice = "supports_tool_choice"
    case structuredOutput = "supports_native_structured_output"
    case pdf = "supports_pdf_input"
    case audio = "supports_audio_input"
    case computerUse = "supports_computer_use"
    case webSearch = "supports_web_search"

    var id: String { rawValue }

    func label(_ copy: L10n) -> String {
        switch self {
        case .any: return copy.modelCatalogAnyCapability
        case .functionCalling: return copy.modelCatalogFunctionCalling
        case .vision: return copy.modelCatalogVision
        case .reasoning: return copy.modelCatalogReasoning
        case .promptCaching: return copy.modelCatalogPromptCaching
        case .toolChoice: return copy.modelCatalogToolChoice
        case .structuredOutput: return copy.modelCatalogStructuredOutput
        case .pdf: return copy.modelCatalogPDF
        case .audio: return copy.modelCatalogAudio
        case .computerUse: return copy.modelCatalogComputerUse
        case .webSearch: return copy.modelCatalogWebSearch
        }
    }
}

enum ModelCatalogPriceRange: String, CaseIterable, Identifiable {
    case any
    case under1
    case oneTo5
    case fiveTo20
    case over20

    var id: String { rawValue }

    func label(_ copy: L10n) -> String {
        switch self {
        case .any: return copy.modelCatalogAnyPrice
        case .under1: return copy.modelCatalogPriceUnder1
        case .oneTo5: return copy.modelCatalogPrice1To5
        case .fiveTo20: return copy.modelCatalogPrice5To20
        case .over20: return copy.modelCatalogPriceOver20
        }
    }

    func matches(inputCostPerToken: Double?) -> Bool {
        guard self != .any else { return true }
        guard let inputCostPerToken, inputCostPerToken.isFinite, inputCostPerToken >= 0 else { return false }
        let price = inputCostPerToken * 1_000_000
        switch self {
        case .any: return true
        case .under1: return price < 1
        case .oneTo5: return price >= 1 && price < 5
        case .fiveTo20: return price >= 5 && price < 20
        case .over20: return price >= 20
        }
    }
}

enum ModelCatalogContextRange: String, CaseIterable, Identifiable {
    case any
    case under32
    case thirtyTwoTo128
    case oneTwentyEightTo200
    case over200

    var id: String { rawValue }

    func label(_ copy: L10n) -> String {
        switch self {
        case .any: return copy.modelCatalogAnyContext
        case .under32: return copy.modelCatalogContextUnder32
        case .thirtyTwoTo128: return copy.modelCatalogContext32To128
        case .oneTwentyEightTo200: return copy.modelCatalogContext128To200
        case .over200: return copy.modelCatalogContextOver200
        }
    }

    func matches(maxInputTokens: Int64?) -> Bool {
        guard self != .any else { return true }
        guard let maxInputTokens else { return false }
        switch self {
        case .any: return true
        case .under32: return maxInputTokens < 32_000
        case .thirtyTwoTo128: return maxInputTokens >= 32_000 && maxInputTokens < 128_000
        case .oneTwentyEightTo200: return maxInputTokens >= 128_000 && maxInputTokens < 200_000
        case .over200: return maxInputTokens >= 200_000
        }
    }
}

enum ModelCatalogFilter {
    static func filter(
        _ entries: [ModelCatalogEntry],
        query: String,
        provider: String,
        modality: String,
        capability: ModelCatalogCapabilityFilter,
        priceRange: ModelCatalogPriceRange,
        contextRange: ModelCatalogContextRange
    ) -> [ModelCatalogEntry] {
        let queryTokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        return entries.filter { entry in
            let matchesQuery = queryTokens.allSatisfy { entry.searchableText.contains($0) }
            let matchesProvider = provider.isEmpty || entry.provider?.caseInsensitiveCompare(provider) == .orderedSame
            let matchesModality = modality.isEmpty || entry.modalities.contains { $0.caseInsensitiveCompare(modality) == .orderedSame }
            let matchesCapability = capability == .any || entry.capabilityKeys.contains(capability.rawValue)
            let matchesPrice = priceRange.matches(inputCostPerToken: entry.pricing.inputCostPerToken)
            let matchesContext = contextRange.matches(maxInputTokens: entry.maxInputTokens)
            return matchesQuery && matchesProvider && matchesModality && matchesCapability && matchesPrice && matchesContext
        }
    }
}

private struct ModelCatalogListRow: View {
    let entry: ModelCatalogEntry
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.modelName)
                .appFont(.bodyEmphasis)
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(entry.source == .custom ? copy.modelCatalogCustomSource : copy.modelCatalogRemoteSource)
                Text("·")
                Text(entry.provider ?? "—")
                if let mode = entry.mode {
                    Text("·")
                    Text(mode)
                }
                Spacer(minLength: 0)
                Text(rateText(entry.pricing.inputCostPerToken))
            }
            .appFont(.metadata)
            .foregroundStyle(AppWindowTheme.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.modelName)
    }

    private func rateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "—" }
        return "$" + NumberFormatter.modelCatalogRate.string(from: NSNumber(value: rate * 1_000_000))!
    }
}

private struct ModelCatalogDetailView: View {
    let entry: ModelCatalogEntry
    let language: AppLanguage

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let description = entry.description, !description.isEmpty {
                    CatalogSection(title: copy.modelCatalogDescription) {
                        Text(description.trimmingCharacters(in: .whitespacesAndNewlines))
                            .appFont(.body)
                            .foregroundStyle(AppWindowTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                pricingSection
                tieredPricingSection
                limitsSection
                detailsSection
                capabilitiesSection
            }
            .padding(24)
        }
        .background(AppWindowTheme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.modelName)
                .appFont(.catalogTitle)
                .foregroundStyle(AppWindowTheme.primary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                CatalogSemanticTag.providerView(entry.provider ?? copy.modelCatalogNoValue)
                if let mode = entry.mode {
                    CatalogSemanticTag.modeView(mode)
                }
                ForEach(entry.modalities, id: \.self) { modality in
                    CatalogSemanticTag.modalityView(modality)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pricingSection: some View {
        CatalogSection(title: copy.modelCatalogPricing) {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 12
            ) {
                CatalogRateCell(title: copy.input, value: entry.rateValue(for: "input_cost_per_token"))
                CatalogRateCell(title: copy.output, value: entry.rateValue(for: "output_cost_per_token"))
                CatalogRateCell(title: copy.cacheWrite, value: entry.rateValue(for: "cache_creation_input_token_cost"))
                CatalogRateCell(title: copy.cacheRead, value: entry.rateValue(for: "cache_read_input_token_cost"))
            }
        }
    }

    private var limitsSection: some View {
        CatalogSection(title: copy.modelCatalogLimits) {
            CatalogKeyValueGrid(rows: [
                (copy.modelCatalogContext, formatTokens(entry.maxInputTokens)),
                (copy.modelCatalogMaxOutput, formatTokens(entry.maxOutputTokens)),
                (copy.modelCatalogMaxTokens, formatTokens(entry.maxTokens))
            ])
        }
    }

    @ViewBuilder
    private var tieredPricingSection: some View {
        let tiers = entry.pricingSchedule?.tiers ?? []

        if !tiers.isEmpty {
            CatalogSection(title: copy.modelCatalogReferencePricing) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(copy.modelCatalogReferencePricingNote)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(Array(tiers.enumerated()), id: \.offset) { _, tier in
                            let threshold = NumberFormat.threshold(tier.threshold)
                            CatalogRateCell(title: "\(copy.input) > \(threshold)", value: tier.rates.input)
                            CatalogRateCell(title: "\(copy.output) > \(threshold)", value: tier.rates.output)
                            CatalogRateCell(title: "\(copy.cacheWrite) > \(threshold)", value: tier.rates.cacheCreation)
                            CatalogRateCell(title: "\(copy.cacheRead) > \(threshold)", value: tier.rates.cacheRead)
                        }
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        CatalogSection(title: copy.modelCatalogDetails) {
            CatalogKeyValueGrid(rows: [
                (copy.modelCatalogSource, entry.source == .custom ? copy.modelCatalogCustomSource : copy.modelCatalogRemoteSource),
                (copy.modelCatalogProvider, entry.provider ?? copy.modelCatalogNoValue),
                (copy.modelCatalogProviderID, entry.providerID ?? copy.modelCatalogNoValue),
                (copy.modelCatalogRoute, entry.route ?? copy.modelCatalogNoValue),
                (copy.modelCatalogMode, entry.mode ?? copy.modelCatalogNoValue),
                (copy.modelCatalogVersion, entry.version ?? copy.modelCatalogNoValue),
                (copy.modelCatalogModality, entry.modalities.isEmpty ? copy.modelCatalogNoValue : entry.modalities.joined(separator: ", ")),
                ("Key", entry.key ?? copy.modelCatalogNoValue),
                (copy.modelCatalogRecordIdentity, entry.recordIdentity ?? copy.modelCatalogNoValue)
            ])
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        if !entry.capabilityKeys.isEmpty {
            CatalogSection(title: copy.modelCatalogCapabilities) {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(entry.capabilityKeys, id: \.self) { key in
                        Label(capabilityLabel(key), systemImage: "checkmark.circle.fill")
                            .appFont(.caption)
                            .foregroundStyle(AppWindowTheme.signal)
                    }
                }
            }
        }
    }

    private func capabilityLabel(_ key: String) -> String {
        switch key {
        case "supports_vision": return copy.modelCatalogVision
        case "supports_function_calling": return copy.modelCatalogFunctionCalling
        case "supports_reasoning": return copy.modelCatalogReasoning
        case "supports_prompt_caching": return copy.modelCatalogPromptCaching
        case "supports_tool_choice": return copy.modelCatalogToolChoice
        case "supports_native_structured_output": return copy.modelCatalogStructuredOutput
        case "supports_pdf_input": return copy.modelCatalogPDF
        case "supports_audio_input": return copy.modelCatalogAudio
        case "supports_computer_use": return copy.modelCatalogComputerUse
        case "supports_web_search": return copy.modelCatalogWebSearch
        default: return key
        }
    }

    private func formatTokens(_ value: Int64?) -> String {
        guard let value else { return copy.modelCatalogNoValue }
        return NumberFormat.compact(value)
    }
}

private struct CatalogSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        AppWindowCard {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .appFont(.captionEmphasis)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum CatalogSemanticTag {
    case provider(String)
    case modality(String)
    case mode(String)

    private var normalizedText: String {
        switch self {
        case let .provider(value), let .modality(value), let .mode(value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    fileprivate var title: String {
        switch self {
        case let .provider(value):
            switch normalizedText {
            case "vertex_ai": return "Vertex AI"
            case "openrouter": return "OpenRouter"
            case "amazon-bedrock", "amazon_bedrock": return "Amazon Bedrock"
            case "zai": return "Z.AI"
            default: return value
            }
        case let .modality(value), let .mode(value):
            return value
        }
    }

    fileprivate var icon: String {
        switch self {
        case .provider:
            switch normalizedText {
            case "openai": return "sparkles"
            case "anthropic": return "a.circle.fill"
            case "google", "vertex_ai": return "globe.americas.fill"
            case "azure": return "cloud.fill"
            case "amazon", "amazon-bedrock", "amazon_bedrock": return "shippingbox.fill"
            case "openrouter": return "arrow.triangle.branch"
            case "deepseek": return "bolt.horizontal.circle.fill"
            case "qwen": return "q.circle.fill"
            case "zai", "glm": return "wand.and.stars"
            default: return "server.rack"
            }
        case .modality:
            switch normalizedText {
            case "text": return "text.alignleft"
            case "vision", "image": return "eye.fill"
            case "audio": return "waveform"
            case "video": return "video.fill"
            default: return "circle.fill"
            }
        case .mode:
            switch normalizedText {
            case "chat": return "bubble.left.and.bubble.right.fill"
            case "completion": return "text.bubble.fill"
            case "embedding": return "square.stack.3d.up.fill"
            default: return "slider.horizontal.3"
            }
        }
    }

    fileprivate var tint: NSColor {
        switch self {
        case .provider:
            switch normalizedText {
            case "openai": return .systemBlue
            case "anthropic": return .systemPurple
            case "google", "vertex_ai": return .systemBlue
            case "azure": return .systemTeal
            case "amazon", "amazon-bedrock", "amazon_bedrock": return .systemOrange
            case "openrouter": return .systemIndigo
            case "deepseek": return .systemTeal
            case "qwen": return .systemOrange
            case "zai", "glm": return .systemPurple
            default: return .secondaryLabelColor
            }
        case .modality:
            switch normalizedText {
            case "text": return .systemIndigo
            case "vision", "image": return .systemCyan
            case "audio": return .systemOrange
            case "video": return .systemPink
            default: return .secondaryLabelColor
            }
        case .mode:
            return .secondaryLabelColor
        }
    }

    @ViewBuilder
    static func providerView(_ value: String) -> some View {
        CatalogTagView(tag: .provider(value))
    }

    @ViewBuilder
    static func modalityView(_ value: String) -> some View {
        CatalogTagView(tag: .modality(value))
    }

    @ViewBuilder
    static func modeView(_ value: String) -> some View {
        CatalogTagView(tag: .mode(value))
    }
}

private struct CatalogTagView: View {
    let tag: CatalogSemanticTag

    var body: some View {
        Label(tag.title, systemImage: tag.icon)
            .appFont(.metadataEmphasis)
            .foregroundStyle(Color(nsColor: tag.tint))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: tag.tint).opacity(0.11))
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: tag.tint).opacity(0.22), lineWidth: 0.8)
            )
            .clipShape(Capsule())
    }
}

private struct CatalogRateCell: View {
    let title: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
            Text(rateText)
                .appFont(.bodyEmphasis)
                .foregroundStyle(AppWindowTheme.primary)
        }
    }

    private var rateText: String {
        guard let value, value.isFinite else { return "—" }
        return "$" + (NumberFormatter.modelCatalogRate.string(from: NSNumber(value: value * 1_000_000)) ?? "0")
    }
}

private struct CatalogKeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0)
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                    Text(row.1)
                        .appFont(.caption)
                        .foregroundStyle(AppWindowTheme.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private extension NumberFormatter {
    static let modelCatalogRate: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter
    }()
}
