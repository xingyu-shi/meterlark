import Foundation

protocol DashboardPluginProvider: Sendable {
    var manifest: PluginManifest { get }
    func fetchDashboard() async throws -> PluginDashboardDocument
}

struct DashboardPluginProviderLoader {
    func loadDocument(from provider: any DashboardPluginProvider) async throws -> PluginDashboardDocument {
        try await provider.fetchDashboard()
    }

    func load(
        from provider: any DashboardPluginProvider,
        language: AppLanguage = .english
    ) async throws -> PluginDashboardModel {
        let document = try await loadDocument(from: provider)
        return try document.makeModel(for: provider.manifest, language: language)
    }
}
