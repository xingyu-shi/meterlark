import Foundation

enum PluginRuntimePhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable
    case stale
    case failed
}

struct PluginRuntimeState: Equatable, Sendable {
    let pluginID: String
    let phase: PluginRuntimePhase
    let dashboard: PluginDashboardModel?
    /// The validated, language-independent dashboard document. Keeping this
    /// alongside the rendered model lets the host switch language without
    /// issuing another provider request.
    let document: PluginDashboardDocument?
    let message: String?
    let updatedAt: Date?
}

actor PluginDashboardRuntime {
    private let provider: any DashboardPluginProvider
    private let loader: DashboardPluginProviderLoader
    private var lastSuccessfulDashboard: PluginDashboardModel?
    private var lastSuccessfulDocument: PluginDashboardDocument?
    private var lastSuccessfulAt: Date?

    private(set) var state: PluginRuntimeState

    init(provider: any DashboardPluginProvider, loader: DashboardPluginProviderLoader = DashboardPluginProviderLoader()) {
        self.provider = provider
        self.loader = loader
        self.state = PluginRuntimeState(
            pluginID: provider.manifest.id,
            phase: .idle,
            dashboard: nil,
            document: nil,
            message: nil,
            updatedAt: nil
        )
    }

    func refresh(
        now: Date = Date(),
        language: AppLanguage = .english
    ) async -> PluginRuntimeState {
        state = PluginRuntimeState(
            pluginID: provider.manifest.id,
            phase: .loading,
            dashboard: state.dashboard,
            document: state.document,
            message: nil,
            updatedAt: lastSuccessfulAt
        )

        do {
            let document = try await loader.loadDocument(from: provider)
            let dashboard = try document.makeModel(for: provider.manifest, language: language)
            let phase: PluginRuntimePhase
            switch dashboard.lifecycle.kind {
            case .ready:
                phase = .ready
                lastSuccessfulDashboard = dashboard
                lastSuccessfulDocument = document
                lastSuccessfulAt = now
            case .stale:
                phase = .stale
            case .unavailable:
                phase = .unavailable
            case .loading:
                phase = .loading
            case .error:
                phase = .failed
            }
            state = PluginRuntimeState(
                pluginID: provider.manifest.id,
                phase: phase,
                dashboard: dashboard,
                document: document,
                message: dashboard.lifecycle.message?.text,
                updatedAt: lastSuccessfulAt
            )
        } catch {
            let message = Self.safeMessage(for: error)
            if let lastSuccessfulDashboard {
                state = PluginRuntimeState(
                    pluginID: provider.manifest.id,
                    phase: .stale,
                    dashboard: lastSuccessfulDashboard,
                    document: lastSuccessfulDocument,
                    message: message,
                    updatedAt: lastSuccessfulAt
                )
            } else {
                state = PluginRuntimeState(
                    pluginID: provider.manifest.id,
                    phase: .failed,
                    dashboard: nil,
                    document: nil,
                    message: message,
                    updatedAt: nil
                )
            }
        }
        return state
    }

    private static func safeMessage(for error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Plugin refresh failed." }
        return String(message.prefix(240))
    }
}
