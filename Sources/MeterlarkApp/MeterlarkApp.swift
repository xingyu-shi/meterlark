import AppKit
import SwiftUI

@main
struct MeterlarkApp: App {
    @StateObject private var store: MonitorStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
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
                .onAppear(perform: store.refreshLaunchAtLoginStatus)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.refreshLaunchAtLoginStatus()
                }
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
