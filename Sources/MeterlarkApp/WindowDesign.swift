import AppKit
import SwiftUI

enum AppWindowHeaderMark: Equatable {
    case brand
    case symbol(String)
}

enum AppWindowTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let signal = Color(nsColor: .systemGreen)
    static let alert = Color(nsColor: .systemRed)
    static let accent = Color(nsColor: .controlAccentColor)

}

private struct AppSurfaceStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppSurfaceStyle = .solid
}

extension EnvironmentValues {
    var appSurfaceStyle: AppSurfaceStyle {
        get { self[AppSurfaceStyleEnvironmentKey.self] }
        set { self[AppSurfaceStyleEnvironmentKey.self] = newValue }
    }
}

struct AppSurfaceBackground: View {
    let style: AppSurfaceStyle

    var body: some View {
        AppSurfaceLayer(
            style: style,
            solidColor: AppWindowTheme.canvas,
            material: .hudWindow,
            blendingMode: .behindWindow,
            tintOpacity: 0.08
        )
        .ignoresSafeArea()
    }
}

struct AppSurfacePanelBackground: View {
    @Environment(\.appSurfaceStyle) private var style
    let opacity: Double

    init(opacity: Double = 1) {
        self.opacity = opacity
    }

    var body: some View {
        AppSurfaceLayer(
            style: style,
            solidColor: AppWindowTheme.panel,
            material: .popover,
            blendingMode: .withinWindow,
            tintOpacity: 0.02
        )
        .opacity(opacity)
    }
}

struct AppSurfaceLayer: View {
    let style: AppSurfaceStyle
    let solidColor: Color
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let tintOpacity: Double

    @ViewBuilder
    var body: some View {
        switch style {
        case .solid:
            NativeSolidBackground(color: NSColor(solidColor))
        case .glass:
            NativeVisualEffectBackground(material: material, blendingMode: blendingMode)
                .overlay(solidColor.opacity(tintOpacity))
        }
    }
}

struct NativeSolidBackground: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> SolidView {
        let view = SolidView()
        view.color = color
        return view
    }

    func updateNSView(_ nsView: SolidView, context: Context) {
        nsView.color = color
    }

    final class SolidView: NSView {
        var color: NSColor = .windowBackgroundColor {
            didSet { needsDisplay = true }
        }

        // Menu-bar popovers live inside a system material container. A solid
        // surface must draw opaque pixels without participating in vibrancy.
        override var isOpaque: Bool { true }
        override var allowsVibrancy: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                resolved.withAlphaComponent(1).setFill()
                bounds.fill(using: .copy)
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}

private struct NativeVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .followsWindowActiveState
        nsView.isEmphasized = false
    }
}

struct AppWindowShell<Content: View>: View {
    let title: String
    let subtitle: String
    let mark: AppWindowHeaderMark
    let interfaceTextSize: InterfaceTextSize
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle
    let width: Double
    let height: Double
    let contentPadding: CGFloat
    let content: Content

    init(
        title: String,
        subtitle: String,
        mark: AppWindowHeaderMark,
        interfaceTextSize: InterfaceTextSize,
        appearance: AppAppearance,
        surfaceStyle: AppSurfaceStyle,
        width: Double,
        height: Double,
        contentPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mark = mark
        self.interfaceTextSize = interfaceTextSize
        self.appearance = appearance
        self.surfaceStyle = surfaceStyle
        self.width = width
        self.height = height
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            AppWindowHeader(title: title, subtitle: subtitle, mark: mark)
            Divider()
                .overlay(AppWindowTheme.separator)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(contentPadding)
        }
        .frame(width: CGFloat(width), height: CGFloat(height), alignment: .top)
        .background(AppSurfaceBackground(style: surfaceStyle))
        .background(WindowAppearanceBridge(appearance: appearance, surfaceStyle: surfaceStyle))
        .preferredColorScheme(preferredColorScheme)
        .appInterfaceTextSize(interfaceTextSize)
        .environment(\.appSurfaceStyle, surfaceStyle)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppWindowCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(AppSurfacePanelBackground())
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppWindowTheme.separator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AppWindowHeader: View {
    let title: String
    let subtitle: String
    let mark: AppWindowHeaderMark

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            markView
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .appFont(.title)
                    .foregroundStyle(AppWindowTheme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .appFont(.body)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .brand:
            BrandMark(size: 34)
        case let .symbol(name):
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
                .background(AppSurfacePanelBackground().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppWindowTheme.separator, lineWidth: 0.5)
                )
                .overlay {
                    Image(systemName: name)
                        .appFont(.icon)
                        .foregroundStyle(AppWindowTheme.accent)
                }
                .frame(width: 34, height: 34)
        }
    }
}
