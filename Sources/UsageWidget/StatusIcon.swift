import AppKit
import UsageCore

/// Иконка строки меню в трёх видах:
/// - полоски — по одной на включённый аккаунт, сверху вниз в порядке списка;
///   длина — окно для строки меню, цвет — самое напряжённое видимое окно;
/// - проценты — те же значения числами;
/// - худший — один процент самого напряжённого окна среди всех аккаунтов.
/// Цвет: обычный цвет строки меню, янтарный от 70%, красный от 90%.
@MainActor
enum StatusIcon {
    struct Bar {
        var fill: Double?       // nil — данных нет
        var warning: NSColor?
        var stale: Bool         // последний опрос упал, показаны старые данные
        var maxUsed: Double?
    }

    /// Сервисы только с балансом полоски не получают — их сумма в подсказке.
    static func bars(_ store: UsageStore, now: Date = Date()) -> [Bar] {
        store.enabledAccounts.filter { !$0.balanceOnly(store.snapshot($0.id)) }.map { a in
            let s = store.snapshot(a.id)
            let max = a.maxUsed(s, at: now)
            return Bar(fill: a.barUsed(s, at: now), warning: max.flatMap(Theme.warning), stale: s.error != nil, maxUsed: max)
        }
    }

    /// Применяет вид к кнопке строки меню: картинка или текст.
    static func apply(_ style: Settings.IconStyle, bars: [Bar], to button: NSStatusBarButton) {
        switch style {
        case .bars:
            button.attributedTitle = NSAttributedString()
            button.image = image(bars)
        case .percents:
            button.image = nil
            button.attributedTitle = text(bars.map { ($0.fill, $0.warning, $0.stale) })
        case .worst:
            button.image = nil
            let worst = bars.filter { $0.maxUsed != nil }.max { $0.maxUsed! < $1.maxUsed! }
            let used = worst?.maxUsed
            button.attributedTitle = text([(used, used.flatMap(Theme.warning), worst?.stale ?? false)])
        }
    }

    private static func text(_ values: [(Double?, NSColor?, Bool)]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let result = NSMutableAttributedString()
        for (i, (value, warning, stale)) in values.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: " · ", attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let color = (warning ?? .labelColor).withAlphaComponent(stale ? 0.5 : 1)
            result.append(NSAttributedString(string: value.map { "\(Int(($0 * 100).rounded()))" } ?? "–",
                                             attributes: [.font: font, .foregroundColor: color]))
        }
        if values.isEmpty { result.append(NSAttributedString(string: "–", attributes: [.font: font])) }
        return result
    }

    static func image(_ bars: [Bar]) -> NSImage {
        // Без включённых аккаунтов — одна пустая полоска: иначе иконка пропала бы и по ней не кликнуть.
        // Больше 8 — одна сводная полоска по самому напряжённому: тоньше 1 pt полоски не различить.
        let bars: [Bar] = if bars.isEmpty {
            [Bar(fill: nil, warning: nil, stale: false, maxUsed: nil)]
        } else if bars.count > 8 {
            [bars.max { ($0.maxUsed ?? -1) < ($1.maxUsed ?? -1) }!]
        } else {
            bars
        }
        let size = NSSize(width: 18, height: 16)
        // Толщина под число аккаунтов: до трёх полосок — по 3 pt, больше — тоньше (при 8 — около 1 pt).
        let n = CGFloat(bars.count)
        let gap: CGFloat = n > 6 ? 1 : n > 3 ? 1.5 : 2.5
        let h = min(3, (size.height - gap * (n - 1)) / n)
        // Рисуется при каждом отображении — цвета подстраиваются под светлую/тёмную строку меню.
        let image = NSImage(size: size, flipped: true) { _ in
            var y = (size.height - (h * n + gap * (n - 1))) / 2
            for bar in bars {
                let track = NSRect(x: 0, y: y, width: size.width, height: h)
                // Предупреждение тонирует и подложку: иначе при пустом 5-часовом окне
                // исчерпанная неделя была бы не видна.
                (bar.warning?.withAlphaComponent(0.45) ?? NSColor.labelColor.withAlphaComponent(0.22)).setFill()
                NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
                if let fill = bar.fill, fill > 0 {
                    // Минимум — кружок, чтобы 1% был виден.
                    let w = max(h, size.width * fill)
                    let color = bar.warning ?? NSColor.labelColor
                    color.withAlphaComponent(bar.stale ? 0.4 : 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
                }
                y += h + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func tooltip(_ store: UsageStore, now: Date = Date()) -> String {
        let lines = store.enabledAccounts.map { a in
            let s = store.snapshot(a.id)
            if a.balanceOnly(s), let b = s.report?.balances.first {
                return "\(a.name): \(Format.money(b.amount, b.currency))" + (s.error != nil ? " (" + L("stale") + ")" : "")
            }
            guard let used = a.barUsed(s, at: now) else { return "\(a.name): " + L("no data") }
            return "\(a.name): \(Format.percent(used))" + (s.error != nil ? " (" + L("stale") + ")" : "")
        }
        return lines.isEmpty ? L("No services enabled") : lines.joined(separator: "\n")
    }
}
