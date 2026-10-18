import SwiftUI
import UsageCore

struct PopoverView: View {
    let store: UsageStore
    @Bindable var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageView(store: store)
            if settings.formShown {
                Divider()
                SettingsForm(settings: settings)
            }
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
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            .help("Обновить (⌘R)")
            Button { settings.formShown.toggle() } label: {
                Image(systemName: settings.formShown ? "gearshape.fill" : "gearshape")
            }
            .keyboardShortcut(",")
            .help("Настройки")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Выйти")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}

private struct SettingsForm: View {
    @Bindable var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Обновлять") {
                Picker("", selection: $settings.interval) {
                    ForEach(Settings.intervals, id: \.self) { Text("\(Int($0 / 60)) мин").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            row("Панель") {
                Picker("", selection: $settings.panelMode) {
                    Text("выкл").tag(Settings.PanelMode.off)
                    Text("поверх окон").tag(Settings.PanelMode.floating)
                    Text("на столе").tag(Settings.PanelMode.desktop)
                }
                .pickerStyle(.segmented)
                .help("«на столе» — панель видна поверх обоев, окна её закрывают")
            }
            row("Автозапуск") {
                Toggle("", isOn: $settings.launchAtLogin)
                Spacer()
            }
        }
        .font(.system(size: 12))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 74, alignment: .leading)
            content().labelsHidden()
        }
    }
}
