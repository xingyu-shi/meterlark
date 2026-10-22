import AppKit
import SwiftUI

struct LoginItemSetupView: View {
    let appURL: URL
    let status: LaunchAtLoginStatus
    let copy: L10n
    let openSettings: () -> Void

    static func dragItem(for appURL: URL) -> NSItemProvider {
        NSItemProvider(object: appURL as NSURL)
    }

    private var appIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
            .resizable()
            .frame(width: 80, height: 80)
            .accessibilityLabel("Meterlark")
    }

    var body: some View {
        VStack(spacing: 16) {
            if status == .requiresApproval {
                appIcon
            } else {
                appIcon
                    .onDrag { Self.dragItem(for: appURL) } preview: {
                        appIcon
                    }
                    .help(copy.launchAtLoginDragIcon)
                    .accessibilityHint(copy.launchAtLoginDragIcon)
            }
            Text(status == .requiresApproval
                 ? copy.launchAtLoginApprovalMessage
                 : copy.launchAtLoginManualSetupMessage)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy.openLoginItems, action: openSettings)
                .controlSize(.large)
        }
        .padding(24)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Keeps the drag source visible while System Settings has focus. System
/// status is observed only while this guide is open; adding the app closes it.
@MainActor
final class LoginItemSetupController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var statusTimer: Timer?
    private var statusChanged: ((LaunchAtLoginStatus) -> Void)?
    private var displayedStatus: LaunchAtLoginStatus?

    func show(language: AppLanguage, statusChanged: @escaping (LaunchAtLoginStatus) -> Void) {
        close()
        self.statusChanged = statusChanged
        let copy = L10n(language: language)
        let status = LaunchAtLoginService.currentStatus()
        statusChanged(status)
        LaunchAtLoginService.openSettings()
        guard !status.isEnabled else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = copy.launchAtLogin
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel
        updateContent(status: status, copy: copy)
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil else { return }
                let current = LaunchAtLoginService.currentStatus()
                self.statusChanged?(current)
                if current.isEnabled {
                    self.close()
                } else if current != self.displayedStatus {
                    self.updateContent(status: current, copy: copy)
                }
            }
        }
    }

    func close() {
        statusTimer?.invalidate()
        statusTimer = nil
        panel?.orderOut(nil)
        panel = nil
        statusChanged = nil
        displayedStatus = nil
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    private func updateContent(status: LaunchAtLoginStatus, copy: L10n) {
        guard let panel else { return }
        displayedStatus = status
        let host = NSHostingView(rootView: LoginItemSetupView(
            appURL: Bundle.main.bundleURL,
            status: status,
            copy: copy,
            openSettings: { LaunchAtLoginService.openSettings() }
        ))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    deinit {
        statusTimer?.invalidate()
    }
}
