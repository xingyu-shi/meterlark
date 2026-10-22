import AppKit
import SwiftUI
import XCTest
@testable import MeterlarkApp

@MainActor
final class WindowSurfaceTests: XCTestCase {
    func testHostedBackgroundRemovesBlurAfterSwitchingFromGlassToSolid() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AppSurfaceBackground(style: .glass))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(of: host, matching: NSVisualEffectView.self).isEmpty)

        host.rootView = AppSurfaceBackground(style: .solid)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(of: host, matching: NSVisualEffectView.self).isEmpty)
    }

    func testWindowSwitchesFromGlassBackToOpaqueSolid() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let bridge = WindowAppearanceBridge.AppearanceView(appearance: .light, surfaceStyle: .glass)
        window.contentView = bridge
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0)

        bridge.preferredSurfaceStyle = .solid
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 1)

        bridge.preferredSurfaceStyle = .glass
        XCTAssertFalse(window.isOpaque)
        bridge.preferredAppAppearance = .dark
        bridge.preferredSurfaceStyle = .solid
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 1)
    }

    private func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? []
        } + view.subviews.flatMap { descendants(of: $0, matching: type) }
    }
}
