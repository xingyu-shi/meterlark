import AppKit
import SwiftUI

struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PopoverScreenHeightReader: NSViewRepresentable {
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.isHidden = true
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenView, context: Context) {
        nsView.onChange = onChange
        nsView.reportHeight()
    }

    final class ScreenView: NSView {
        var onChange: ((Double) -> Void)?
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
            reportHeight()
        }

        @objc private func screenDidChange(_ notification: Notification) {
            reportHeight()
        }

        func reportHeight() {
            guard let screen = window?.screen else { return }
            // visibleFrame excludes the menu bar and Dock. Leave a little room
            // for the popover's surrounding chrome at the screen edges.
            let height = Double(max(1, screen.visibleFrame.height - 16))
            guard height != lastHeight else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.onChange?(height) }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
