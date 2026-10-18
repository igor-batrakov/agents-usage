import SwiftUI
import UsageCore

/// Высота содержимого — чтобы область с прокруткой была не выше нужного.
/// Модель вместо @State (SwiftUI-макросов в Command Line Tools нет, см. Settings.selectedAccountID);
/// живёт в корневом виде поповера или панели, которые создаются один раз.
@MainActor @Observable
final class ContentHeight {
    var value: CGFloat = 0
}

/// Общий контент поповера и плавающей панели: блок на каждый включённый аккаунт.
/// Подписи «через N» тикают раз в 30 с и только пока вид на экране.
/// Выше `maxHeight` — прокрутка (аккаунтов может быть много, а окно не должно уходить за экран).
struct UsageView: View {
    let store: UsageStore
    let height: ContentHeight
    let maxHeight: CGFloat
    var compact = false
    /// Какие аккаунты показывать (у панели — свой набор).
    var include: (Account) -> Bool = { _ in true }

    var body: some View {
        let accounts = store.enabledAccounts.filter(include)
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                    if accounts.isEmpty {
                        Text("Нет включённых сервисов — добавьте их в настройках")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { account in
                        AccountSection(account: account, snapshot: store.snapshot(account.id),
                                       now: context.date, compact: compact)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.value = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height.value, 20), maxHeight))
    }

    /// Предел высоты: видимая область экрана минус запас на рамку, футер и отступы.
    static func screenLimit(reserve: CGFloat) -> CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 900) - reserve)
    }
}

private struct AccountSection: View {
    let account: Account
    let snapshot: Snapshot
    let now: Date
    let compact: Bool

    private var provider: Provider { account.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            header
            if snapshot.report != nil {
                let windows = account.visibleWindows(snapshot)
                if windows.isEmpty {
                    Text("все окна скрыты").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups(windows), id: \.name) { group in
                    if let name = group.name {
                        Text(name.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    ForEach(group.windows) { window in
                        LimitRow(window: window, provider: provider, now: now,
                                 stale: snapshot.error != nil, compact: compact)
                    }
                }
            } else if snapshot.error == nil {
                Text("загрузка…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent(provider)).frame(width: 7, height: 7)
            title
            if let plan = snapshot.report?.plan {
                Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: Theme.amber))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            }
        }
    }

    /// Имя аккаунта; если у вендора есть страница лимитов — это ссылка на неё.
    @ViewBuilder private var title: some View {
        let text = HStack(spacing: 3) {
            Text(account.name).font(.system(size: compact ? 12 : 13, weight: .semibold))
            if account.resolvedUsageURL != nil {
                Image(systemName: "arrow.up.right").font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if let url = account.resolvedUsageURL {
            Button { NSWorkspace.shared.open(url) } label: { text }
                .buttonStyle(.plain)
                .help("Открыть страницу лимитов: \(url.host() ?? url.absoluteString)")
                // pointerStyle, а не NSCursor.push/pop: поповер закрывается по клику, и pop
                // не случился бы — курсор-рука залип бы.
                .pointerStyle(.link)
        } else {
            text
        }
    }

    /// Окна подряд с одинаковой группой — одна секция (у agy: Gemini, Claude и GPT, Argon).
    private func groups(_ windows: [LimitWindow]) -> [(name: String?, windows: [LimitWindow])] {
        var result: [(name: String?, windows: [LimitWindow])] = []
        for w in windows {
            if let last = result.last, last.name == w.group {
                result[result.count - 1].windows.append(w)
            } else {
                result.append((w.group, [w]))
            }
        }
        return result
    }
}

private struct LimitRow: View {
    let window: LimitWindow
    let provider: Provider
    let now: Date
    let stale: Bool
    let compact: Bool

    var body: some View {
        let used = window.used(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title).font(.system(size: compact ? 11.5 : 12))
                if let reset = window.resetsAt {
                    Text(Format.resetIn(reset, now: now))
                        .font(.system(size: compact ? 10.5 : 11))
                        .foregroundStyle(.secondary)
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer(minLength: 4)
                Text(Format.percent(used))
                    .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                    .monospacedDigit()
            }
            Bar(fraction: used, color: Theme.bar(used, provider))
                .frame(height: compact ? 4 : 5)
        }
        .opacity(stale ? 0.5 : 1)
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if fraction > 0 {
                    Capsule().fill(color)
                        .frame(width: max(geo.size.height, geo.size.width * fraction))
                }
            }
        }
    }
}
