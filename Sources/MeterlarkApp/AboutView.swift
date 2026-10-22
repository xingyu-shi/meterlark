import AppKit
import SwiftUI

struct AboutView: View {
    let language: AppLanguage
    let interfaceTextSize: InterfaceTextSize
    let appearance: AppAppearance
    let surfaceStyle: AppSurfaceStyle

    init(
        language: AppLanguage,
        interfaceTextSize: InterfaceTextSize = .standard,
        appearance: AppAppearance = .automatic,
        surfaceStyle: AppSurfaceStyle = .solid
    ) {
        self.language = language
        self.interfaceTextSize = interfaceTextSize
        self.appearance = appearance
        self.surfaceStyle = surfaceStyle
    }

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        AppWindowShell(
            title: "Meterlark",
            subtitle: copy.aboutSubtitle,
            mark: .brand,
            interfaceTextSize: interfaceTextSize,
            appearance: appearance,
            surfaceStyle: surfaceStyle,
            width: interfaceTextSize.aboutWindowWidth,
            height: interfaceTextSize.aboutWindowHeight,
            contentPadding: 22
        ) {
            VStack(alignment: .leading, spacing: 14) {
                AppWindowCard(padding: 15) {
                    VStack(alignment: .leading, spacing: 11) {
                        detailRow(copy.version, AppMetadata.version)
                        detailRow(copy.build, AppMetadata.build)
                        detailRow(copy.bundledCCUsage, AppMetadata.bundledCCUsageVersion)
                        hashRow
                    }
                }

                Text(copy.aboutDetails)
                    .appFont(.caption)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hashRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(copy.bundledCCUsageHash)
                .appFont(.caption)
                .foregroundStyle(AppWindowTheme.secondary)
            Text(AppMetadata.bundledCCUsageSHA256)
                .appFont(.hash)
                .foregroundStyle(AppWindowTheme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(AppMetadata.bundledCCUsageSHA256)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .appFont(.caption)
                .foregroundStyle(AppWindowTheme.secondary)
                .frame(width: interfaceTextSize == .largest ? 142 : interfaceTextSize == .extraLarge ? 134 : interfaceTextSize == .large ? 126 : 118, alignment: .leading)

            Text(value)
                .appFont(.body)
                .foregroundStyle(AppWindowTheme.primary)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}
