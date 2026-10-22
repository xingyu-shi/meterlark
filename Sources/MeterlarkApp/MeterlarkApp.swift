import AppKit
import SwiftUI

@main
struct MeterlarkApp: App {
    @StateObject private var store: MonitorStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            try LegacyDataMigration.prepare()
        } catch {
            let copy = L10n(language: .system)
            let alert = NSAlert()
            alert.messageText = copy.dataMigrationFailedTitle
            alert.informativeText = copy.dataMigrationFailedMessage
            alert.addButton(withTitle: copy.quitApp)
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        let externalPlugins = ExternalPluginRegistry()
        // The host starts empty. External packages become providers only
        // after they are installed, configured, and explicitly enabled.
        let host = DashboardPluginHost(providers: [])
        _store = StateObject(wrappedValue: MonitorStore(
            pluginHost: host,
            externalPluginRegistry: externalPlugins
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(store: store)
        } label: {
            MenuBarFormatView(
                format: store.menuBarFormat,
                cost: store.snapshot.primaryEstimatedCost,
                isAlerting: store.budgetStatus.needsAttention,
                notificationUnreadCount: store.settings.notificationFeedEnabled
                    ? store.notificationUnreadCount
                    : 0
            )
            .fixedSize(horizontal: true, vertical: true)
            .help(store.menuBarHelpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(store.menuBarHelpText)
        }
        .menuBarExtraStyle(.window)
    }
}
