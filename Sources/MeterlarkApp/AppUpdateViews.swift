import SwiftUI

struct CheckForAppUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    let copy: L10n

    var body: some View {
        Button(action: updater.checkForUpdates) {
            Label(copy.checkForAppUpdates, systemImage: "arrow.down.circle")
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

struct AppUpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    let copy: L10n

    var body: some View {
        Section(copy.appUpdates) {
            LabeledContent(copy.settingsCurrentVersion, value: currentVersion)
            if let version = updater.availableVersion {
                Text(copy.appUpdateAvailable(version)).foregroundStyle(AppWindowTheme.signal)
            }
            LabeledContent(copy.settingsLastUpdateCheck) {
                if let date = updater.lastUpdateCheckDate {
                    Text(date, format: .dateTime.month().day().hour().minute().locale(copy.language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")))
                } else {
                    Text(copy.settingsNotChecked)
                }
            }
            CheckForAppUpdatesButton(updater: updater, copy: copy)

            Toggle(isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: updater.setAutomaticallyChecksForUpdates
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.automaticallyCheckForAppUpdates)
                    Text(copy.settingsAutomaticChecksHelp)
                        .appFont(.caption)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!updater.isAvailable)

            Toggle(isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: updater.setAutomaticallyDownloadsUpdates
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.automaticallyInstallAppUpdates)
                    Text(copy.automaticAppUpdatesHelp)
                        .appFont(.caption)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!updater.allowsAutomaticUpdates)
        }
    }

    private var currentVersion: String {
        guard updater.isAvailable else { return "—" }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

}

struct AppUpdateNotice: View {
    @ObservedObject var updater: AppUpdater
    let copy: L10n

    var body: some View {
        if let version = updater.availableVersion {
            Button(action: updater.checkForUpdates) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(copy.appUpdateAvailable(version))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(copy.updateApp)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right")
                }
                .appFont(.caption)
                .padding(10)
                .foregroundStyle(AppWindowTheme.signal)
                .background(AppSurfacePanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
