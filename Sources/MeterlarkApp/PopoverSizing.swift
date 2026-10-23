import AppKit
import SwiftUI

struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the usable screen height to SwiftUI and keeps the hosting
/// window's content height equal to the popover's resolved height.
///
/// A `MenuBarExtra(.window)` window does not shrink when its SwiftUI root
/// gets shorter; it keeps the larger size and centers the root inside it,
/// leaving empty bands above and below the dashboard. Pass `windowHeight`
/// to resize that window directly. Pass `nil` when another owner sizes the
/// window, such as the dashboard layout preview.
struct PopoverWindowSizer: NSViewRepresentable {
    let windowHeight: Double?
    let onScreenHeightChange: (Double) -> Void

    func makeNSView(context: Context) -> SizerView {
        let view = SizerView()
        view.isHidden = true
        view.onScreenHeightChange = onScreenHeightChange
        view.windowHeight = windowHeight
        return view
    }

    func updateNSView(_ nsView: SizerView, context: Context) {
        nsView.onScreenHeightChange = onScreenHeightChange
        nsView.windowHeight = windowHeight
        nsView.reportHeight()
        nsView.scheduleWindowFit()
    }

    final class SizerView: NSView {
        var onScreenHeightChange: ((Double) -> Void)?
        var windowHeight: Double?
        private var lastHeight: Double?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenDidChange),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenDidChange),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            // The menu bar window is reused across openings; fit it again
            // each time it is shown.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            reportHeight()
            scheduleWindowFit()
        }

        @objc private func screenDidChange(_ notification: Notification) {
            reportHeight()
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            scheduleWindowFit()
        }

        func reportHeight() {
            guard let screen = window?.screen else { return }
            // visibleFrame excludes the menu bar and Dock. Leave a little room
            // for the popover's surrounding chrome at the screen edges.
            let height = Double(max(1, screen.visibleFrame.height - 16))
            guard height != lastHeight else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.onScreenHeightChange?(height) }
        }

        /// Resizes outside the SwiftUI update pass, keeping the top edge
        /// pinned under the menu bar.
        func scheduleWindowFit() {
            guard windowHeight != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, let windowHeight, windowHeight.isFinite, windowHeight > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let height = CGFloat(windowHeight)
            guard abs(content.height - height) > 0.5 else { return }
            let target = NSRect(
                x: content.minX,
                y: content.maxY - height,
                width: content.width,
                height: height
            )
            window.setFrame(window.frameRect(forContentRect: target), display: true)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
