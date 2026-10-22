import SwiftUI

struct AppTypography {
    enum Role {
        case display
        case title
        case catalogTitle
        case section
        case sectionSubtitle
        case body
        case bodyEmphasis
        case bodyAlert
        case caption
        case captionEmphasis
        case metadata
        case metadataEmphasis
        case metric
        case chartValue
        case chartValueEmphasis
        case button
        case chartControlIcon
        case chartControlChevron
        case icon
        case hash
    }

    let textSize: InterfaceTextSize

    private var scale: CGFloat { CGFloat(textSize.scale) }

    func font(for role: Role) -> Font {
        switch role {
        case .display:
            return system(size: 34, weight: .bold)
        case .title:
            return system(size: 21, weight: .semibold)
        case .catalogTitle:
            return system(size: 22, weight: .bold)
        case .section:
            return system(size: 15, weight: .bold)
        case .sectionSubtitle:
            return system(size: 13, weight: .bold)
        case .body:
            return system(size: 12, weight: .medium)
        case .bodyEmphasis:
            return system(size: 12, weight: .semibold)
        case .bodyAlert:
            return system(size: 12, weight: .bold)
        case .caption:
            return system(size: 11, weight: .medium)
        case .captionEmphasis:
            return system(size: 11, weight: .semibold)
        case .metadata:
            return system(size: 10.5, weight: .medium)
        case .metadataEmphasis:
            return system(size: 10.5, weight: .semibold)
        case .metric:
            return system(size: 20, weight: .bold)
        case .chartValue:
            return system(size: 11, weight: .bold)
        case .chartValueEmphasis:
            return system(size: 13, weight: .bold)
        case .button:
            return system(size: 11, weight: .bold)
        case .chartControlIcon:
            return .system(size: 11 * scale, weight: .semibold)
        case .chartControlChevron:
            return .system(size: max(8, 8 * scale), weight: .bold)
        case .icon:
            return .system(size: max(10, 10 * scale), weight: .semibold)
        case .hash:
            return .system(size: 10.5 * scale, weight: .regular, design: .monospaced)
        }
    }

    private func system(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size * scale, weight: weight, design: .rounded)
    }
}

private struct InterfaceTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: InterfaceTextSize = .standard
}

extension EnvironmentValues {
    var interfaceTextSize: InterfaceTextSize {
        get { self[InterfaceTextSizeEnvironmentKey.self] }
        set { self[InterfaceTextSizeEnvironmentKey.self] = newValue }
    }
}

extension View {
    func appInterfaceTextSize(_ textSize: InterfaceTextSize) -> some View {
        environment(\.interfaceTextSize, textSize)
    }

    func appFont(_ role: AppTypography.Role) -> some View {
        modifier(AppFontModifier(role: role))
    }

    func appControlHeight() -> some View {
        modifier(AppControlHeightModifier())
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.interfaceTextSize) private var interfaceTextSize
    let role: AppTypography.Role

    func body(content: Content) -> some View {
        content.font(AppTypography(textSize: interfaceTextSize).font(for: role))
    }
}

private struct AppControlHeightModifier: ViewModifier {
    @Environment(\.interfaceTextSize) private var interfaceTextSize

    func body(content: Content) -> some View {
        content.frame(height: CGFloat(interfaceTextSize.controlHeight))
    }
}
