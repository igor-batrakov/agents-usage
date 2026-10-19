import SwiftUI
import UsageCore

/// Popover: data and quick actions; detailed settings are in a separate window.
struct PopoverView: View {
    let store: UsageStore
    @Bindable var settings: Settings
    let updater: Updater
    let openSettings: () -> Void
    private let height = ContentHeight()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageView(store: store, height: height, maxHeight: UsageView.screenLimit(reserve: 150),
                      showPace: settings.showPace)
            if let release = updater.available {
                Divider()
                UpdateRow(updater: updater, release: release)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 310)
        .id(settings.language ?? "")  // new language: rebuild, L() strings are evaluated at build time
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if store.isRefreshing {
                        Text(L("refreshing…"))
                    } else if let last = store.lastRefresh {
                        Text(L("updated %@", Format.ago(last, now: context.date)))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if !settings.autoRefresh {
                Text("· " + L("paused")).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.amber))
            }
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(store.isRefreshing)
                .help(L("Refresh (⌘R)"))
            Button { settings.autoRefresh.toggle() } label: {
                Image(systemName: settings.autoRefresh ? "pause.circle" : "play.circle")
            }
            .help(settings.autoRefresh ? L("Pause auto-refresh") : L("Resume auto-refresh"))
            Button { settings.panelEnabled.toggle() } label: {
                Image(systemName: settings.panelEnabled ? "macwindow.badge.plus" : "macwindow")
            }
            .help(settings.panelEnabled ? L("Hide the desktop panel") : L("Show the desktop panel"))
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help(L("Settings (⌘,)"))
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help(L("Quit (⌘Q)"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}
