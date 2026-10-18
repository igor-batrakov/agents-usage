import SwiftUI
import UsageCore

/// Общий контент поповера и плавающей панели: блок на каждый сервис.
/// Подписи «через N» тикают раз в 30 с и только пока вид на экране.
struct UsageView: View {
    let store: UsageStore
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    ProviderSection(provider: provider, snapshot: store.snapshot(provider),
                                    now: context.date, compact: compact)
                }
            }
        }
    }
}

private struct ProviderSection: View {
    let provider: Provider
    let snapshot: Snapshot
    let now: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            header
            if let windows = snapshot.report?.windows {
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
            Text(provider.title).font(.system(size: compact ? 12 : 13, weight: .semibold))
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
