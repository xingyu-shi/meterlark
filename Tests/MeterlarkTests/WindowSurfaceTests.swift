import AppKit
import SwiftUI
import XCTest
@testable import MeterlarkApp

@MainActor
final class WindowSurfaceTests: XCTestCase {
    func testSolidSurfacePaintsOpaquePixelsAndOptsOutOfVibrancy() throws {
        let view = NativeSolidBackground.SolidView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        view.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.1)
        view.appearance = NSAppearance(named: .aqua)

        let color = try renderedColor(of: view)

        XCTAssertTrue(view.isOpaque)
        XCTAssertFalse(view.allowsVibrancy)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 1.0 / 255)
        XCTAssertEqual(color.redComponent, 0.2, accuracy: 1.0 / 255)
        XCTAssertEqual(color.greenComponent, 0.4, accuracy: 1.0 / 255)
        XCTAssertEqual(color.blueComponent, 0.6, accuracy: 1.0 / 255)
    }

    func testSolidSurfaceResolvesSystemColorsForLightAndDarkAppearance() throws {
        let view = NativeSolidBackground.SolidView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        view.color = NSColor(AppWindowTheme.canvas)
        view.appearance = NSAppearance(named: .aqua)
        let light = try renderedColor(of: view)
        view.appearance = NSAppearance(named: .darkAqua)
        let dark = try renderedColor(of: view)

        XCTAssertEqual(light.alphaComponent, 1, accuracy: 1.0 / 255)
        XCTAssertEqual(dark.alphaComponent, 1, accuracy: 1.0 / 255)
        XCTAssertGreaterThan(light.redComponent, dark.redComponent)
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

    private func renderedColor(of view: NSView) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        return try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    }
}
