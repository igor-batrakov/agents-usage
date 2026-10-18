import SwiftUI
import UsageCore

/// Поповер — данные и быстрые действия; детальные настройки — в отдельном окне.
struct PopoverView: View {
    let store: UsageStore
    @Bindable var settings: Settings
    let openSettings: () -> Void
    private let height = ContentHeight()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageView(store: store, height: height, maxHeight: UsageView.screenLimit(reserve: 120),
                      showPace: settings.showPace)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 310)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if store.isRefreshing {
                        Text("обновляю…")
                    } else if let last = store.lastRefresh {
                        Text("обновлено \(Format.ago(last, now: context.date))")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if !settings.autoRefresh {
                Text("· пауза").font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.amber))
            }
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(store.isRefreshing)
                .help("Обновить (⌘R)")
            Button { settings.autoRefresh.toggle() } label: {
                Image(systemName: settings.autoRefresh ? "pause.circle" : "play.circle")
            }
            .help(settings.autoRefresh ? "Приостановить автообновление" : "Возобновить автообновление")
            Button { settings.panelEnabled.toggle() } label: {
                Image(systemName: settings.panelEnabled ? "macwindow.badge.plus" : "macwindow")
            }
            .help(settings.panelEnabled ? "Скрыть панель на столе" : "Показать панель на столе")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("Настройки (⌘,)")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Выйти (⌘Q)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}
