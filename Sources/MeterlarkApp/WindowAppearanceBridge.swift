import AppKit
import SwiftUI

struct WindowAppearanceBridge: NSViewRepresentable {
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle

    func makeNSView(context: Context) -> AppearanceView {
        AppearanceView(appearance: appearance, surfaceStyle: surfaceStyle)
    }

    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.preferredAppAppearance = appearance
        nsView.preferredSurfaceStyle = surfaceStyle
        nsView.applyAppearance()
    }

    final class AppearanceView: NSView {
        var preferredAppAppearance: AppAppearance {
            didSet { applyAppearance() }
        }
        var preferredSurfaceStyle: AppSurfaceStyle {
            didSet { applySurfaceStyle() }
        }

        init(appearance: AppAppearance, surfaceStyle: AppSurfaceStyle) {
            self.preferredAppAppearance = appearance
            self.preferredSurfaceStyle = surfaceStyle
            super.init(frame: .zero)
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            guard let window else { return }
            applySurfaceStyle()
            if window.styleMask.contains(.titled) {
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
            }
            switch preferredAppAppearance {
            case .automatic:
                window.appearance = nil
            case .light:
                window.appearance = NSAppearance(named: .aqua)
            case .dark:
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }

        func applySurfaceStyle() {
            guard let window else { return }
            switch preferredSurfaceStyle {
            case .solid:
                window.isOpaque = true
                window.backgroundColor = NSColor.windowBackgroundColor
            case .glass:
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }
    }
}
