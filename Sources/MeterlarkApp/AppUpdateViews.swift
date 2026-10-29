import SwiftUI

struct AppUpdateMenu: View {
    @ObservedObject var updater: AppUpdater
    let copy: L10n

    var body: some View {
        Section(copy.appUpdates) {
            Button(action: updater.checkForUpdates) {
                Label(copy.checkForAppUpdates, systemImage: "arrow.down.circle")
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle(copy.automaticallyCheckForAppUpdates, isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: updater.setAutomaticallyChecksForUpdates
            ))
            .disabled(!updater.isAvailable)

            Toggle(copy.automaticallyInstallAppUpdates, isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: updater.setAutomaticallyDownloadsUpdates
            ))
            .disabled(!updater.allowsAutomaticUpdates)
            .help(copy.automaticAppUpdatesHelp)
        }
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
