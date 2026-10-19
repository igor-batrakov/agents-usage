import AppKit
import SwiftUI
import UsageCore

/// Settings tab: version, update check, project links.
struct AboutTab: View {
    @Bindable var settings: Settings
    let updater: Updater

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(verbatim: "Agents Usage").font(.title2.weight(.semibold))
                Text(L("Version %@", updater.current ?? "dev"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(L("Subscription limits of your AI coding agents in the menu bar."))
                .foregroundStyle(.secondary)
            updates
                .padding(.top, 6)
            HStack(spacing: 18) {
                Button(L("GitHub")) { NSWorkspace.shared.open(Updates.repoURL) }
                Button(L("Release notes")) { NSWorkspace.shared.open(Updates.releasesURL) }
                Button(L("Report a problem")) { NSWorkspace.shared.open(Updates.issuesURL) }
            }
            .buttonStyle(.link)
            Spacer()
            Text(verbatim: "© 2026 Igor Batrakov · " + L("MIT License"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var updates: some View {
        VStack(spacing: 10) {
            if let release = updater.available {
                UpdateRow(updater: updater, release: release)
                    .frame(width: 340)
            }
            HStack(spacing: 8) {
                Button(L("Check for Updates")) { Task { await updater.check() } }
                    .disabled(Demo.isOn || updater.current == nil || updater.status == .checking
                              || updater.status == .installing)
                switch updater.status {
                case .checking:
                    ProgressView().controlSize(.small)
                case .upToDate:
                    Text(L("You have the latest version.")).foregroundStyle(.secondary)
                case .failed(let text) where updater.available == nil:
                    Text(text).foregroundStyle(Color(nsColor: Theme.amber)).lineLimit(2)
                default:
                    EmptyView()
                }
            }
            .font(.callout)
            Toggle(L("Check for updates automatically"), isOn: $settings.checkUpdates)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }
}

/// "Version X is available" with Update: in the popover and on the About tab.
struct UpdateRow: View {
    let updater: Updater
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                // The text opens the release notes: a separate "What's new" button does not fit the popover.
                Button(L("Version %@ is available", release.version)) { NSWorkspace.shared.open(release.url) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .help(L("What's new"))
                Spacer(minLength: 4)
                if updater.status == .installing {
                    ProgressView().controlSize(.small)
                    Text(L("Updating…")).foregroundStyle(.secondary)
                } else {
                    Button(L("Update")) { updater.install() }
                        .controlSize(.small)
                        .disabled(!updater.canInstall)
                        .help(L("Download and install it, the app restarts"))
                }
            }
            if case .failed(let text) = updater.status {
                Text(text).font(.caption).foregroundStyle(Color(nsColor: Theme.amber)).lineLimit(2)
            }
        }
        .font(.system(size: 12))
    }
}
