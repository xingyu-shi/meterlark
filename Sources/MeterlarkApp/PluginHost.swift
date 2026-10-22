import Foundation

struct DashboardPluginRuntimeSnapshot: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let runtime: PluginRuntimeState

    var id: String { manifest.id }
}

enum DashboardPluginProviderSelection {
    /// Merge host-provided providers with enabled external providers.
    /// An external provider with the same stable ID intentionally replaces a
    /// host provider so a migration cannot create duplicate dashboard cards.
    static func merging(
        base: [any DashboardPluginProvider],
        external: [any DashboardPluginProvider]
    ) -> [any DashboardPluginProvider] {
        var providersByID = [String: any DashboardPluginProvider]()
        for provider in base.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            providersByID[provider.manifest.id] = provider
        }
        for provider in external.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            providersByID[provider.manifest.id] = provider
        }
        return providersByID.values.sorted { $0.manifest.id < $1.manifest.id }
    }
}

/// Main-actor bridge between provider actors and the application UI.
///
/// The host owns one runtime per provider and coalesces refresh requests per
/// plugin. Providers still return only validated declarative documents; this
/// type never accepts or renders plugin view code.
@MainActor
final class DashboardPluginHost {
    typealias ChangeHandler = ([DashboardPluginRuntimeSnapshot]) -> Void

    private struct Registration {
        let manifest: PluginManifest
        let runtime: PluginDashboardRuntime
    }

    private var registrations: [String: Registration]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var providerGeneration = 0
    private var language: AppLanguage
    private(set) var snapshots: [DashboardPluginRuntimeSnapshot]
    var onChange: ChangeHandler?

    init(
        providers: [any DashboardPluginProvider],
        language: AppLanguage = .system
    ) {
        self.language = language
        let result = Self.makeRegistrations(providers)
        self.registrations = result.registrations
        self.snapshots = Self.makeSnapshots(result.registrations)
    }

    func replaceProviders(
        _ providers: [any DashboardPluginProvider],
        replacingIDs: Set<String> = []
    ) {
        providerGeneration += 1
        cancelRefreshes()
        let previousRegistrations = registrations
        let previousSnapshots = snapshots
        let result = Self.makeRegistrations(
            providers,
            previous: previousRegistrations,
            replacingIDs: replacingIDs
        )
        registrations = result.registrations
        snapshots = Self.makeSnapshots(
            result.registrations,
            previousSnapshots: previousSnapshots,
            preservedIDs: result.preservedIDs
        )
        publish()
    }

    /// Re-materializes cached dashboard documents in the selected language.
    /// Changing the app language must not cause another HTTP request or plugin
    /// process launch.
    func setLanguage(_ language: AppLanguage) {
        self.language = language
        for index in snapshots.indices {
            let snapshot = snapshots[index]
            guard let document = snapshot.runtime.document,
                  let dashboard = try? document.makeModel(
                      for: snapshot.manifest,
                      language: language
                  ) else {
                continue
            }
            snapshots[index] = DashboardPluginRuntimeSnapshot(
                manifest: snapshot.manifest,
                runtime: materializedState(
                    snapshot.runtime,
                    document: document,
                    dashboard: dashboard
                )
            )
        }
        publish()
    }

    func refreshAll(now: Date = Date()) {
        for pluginID in registrations.keys.sorted() {
            refresh(pluginID: pluginID, now: now)
        }
    }

    func refresh(pluginID: String, now: Date = Date()) {
        guard refreshTasks[pluginID] == nil,
              let registration = registrations[pluginID] else {
            return
        }

        if let index = snapshots.firstIndex(where: { $0.id == pluginID }) {
            let current = snapshots[index].runtime
            snapshots[index] = DashboardPluginRuntimeSnapshot(
                manifest: registration.manifest,
                runtime: PluginRuntimeState(
                    pluginID: pluginID,
                    phase: .loading,
                    dashboard: current.dashboard,
                    document: current.document,
                    message: nil,
                    updatedAt: current.updatedAt
                )
            )
            publish()
        }

        let runtime = registration.runtime
        let generation = providerGeneration
        let language = self.language
        refreshTasks[pluginID] = Task { @MainActor [weak self] in
            let state = await runtime.refresh(now: now, language: language)
            guard let self, self.providerGeneration == generation else { return }
            self.refreshTasks[pluginID] = nil
            self.replace(state: state, manifest: registration.manifest)
        }
    }

    func cancelRefreshes() {
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
    }

    deinit {
        refreshTasks.values.forEach { $0.cancel() }
    }

    private func replace(state: PluginRuntimeState, manifest: PluginManifest) {
        guard let index = snapshots.firstIndex(where: { $0.id == manifest.id }) else { return }
        let localizedState: PluginRuntimeState = {
            guard let document = state.document,
                  let dashboard = try? document.makeModel(for: manifest, language: language) else {
                return state
            }
            return materializedState(
                state,
                document: document,
                dashboard: dashboard
            )
        }()
        snapshots[index] = DashboardPluginRuntimeSnapshot(manifest: manifest, runtime: localizedState)
        publish()
    }

    private func materializedState(
        _ state: PluginRuntimeState,
        document: PluginDashboardDocument,
        dashboard: PluginDashboardModel
    ) -> PluginRuntimeState {
        // A failed refresh keeps the last successful (usually `.ready`)
        // document so the card remains useful. Its refresh error lives on the
        // runtime state, not in that cached document. Do not replace that
        // diagnostic with the cached lifecycle message when re-materializing
        // the document for a language change or a host update.
        let message: String?
        if state.phase == .stale, dashboard.lifecycle.kind == .ready {
            message = state.message
        } else {
            message = dashboard.lifecycle.message?.text
        }

        return PluginRuntimeState(
            pluginID: state.pluginID,
            phase: state.phase,
            dashboard: dashboard,
            document: document,
            message: message,
            updatedAt: state.updatedAt
        )
    }

    private func publish() {
        onChange?(snapshots)
    }

    private static func makeRegistrations(
        _ providers: [any DashboardPluginProvider],
        previous: [String: Registration] = [:],
        replacingIDs: Set<String> = []
    ) -> (registrations: [String: Registration], preservedIDs: Set<String>) {
        var registrations = [String: Registration]()
        var preservedIDs = Set<String>()
        for provider in providers.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            // Discovery rejects duplicate IDs. Keeping the first deterministic
            // registration also protects callers that assemble providers
            // programmatically.
            guard registrations[provider.manifest.id] == nil else { continue }
            if !replacingIDs.contains(provider.manifest.id),
               let old = previous[provider.manifest.id],
               old.manifest == provider.manifest {
                registrations[provider.manifest.id] = old
                preservedIDs.insert(provider.manifest.id)
            } else {
                registrations[provider.manifest.id] = Registration(
                    manifest: provider.manifest,
                    runtime: PluginDashboardRuntime(provider: provider)
                )
            }
        }
        return (registrations, preservedIDs)
    }

    private static func makeSnapshots(
        _ registrations: [String: Registration],
        previousSnapshots: [DashboardPluginRuntimeSnapshot] = [],
        preservedIDs: Set<String> = []
    ) -> [DashboardPluginRuntimeSnapshot] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousSnapshots.map { ($0.id, $0) })
        return registrations.values
            .sorted { $0.manifest.id < $1.manifest.id }
            .map { registration in
                if preservedIDs.contains(registration.manifest.id),
                   let previous = previousByID[registration.manifest.id] {
                    return previous
                }
                return DashboardPluginRuntimeSnapshot(
                    manifest: registration.manifest,
                    runtime: PluginRuntimeState(
                        pluginID: registration.manifest.id,
                        phase: .idle,
                        dashboard: nil,
                        document: nil,
                        message: nil,
                        updatedAt: nil
                    )
                )
            }
    }
}
