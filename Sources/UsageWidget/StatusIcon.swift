import AppKit
import UsageCore

/// Иконка строки меню: три полоски (Claude, Codex, agy сверху вниз).
/// Длина — по 5-часовому окну, цвет — по самому напряжённому окну сервиса:
/// обычный цвет строки меню, янтарный от 70%, красный от 90%.
@MainActor
enum StatusIcon {
    struct Bar {
        var fill: Double?       // nil — данных нет
        var warning: NSColor?
        var stale: Bool         // последний опрос упал, показаны старые данные
    }

    static func bars(_ store: UsageStore, now: Date = Date()) -> [Bar] {
        Provider.allCases.map { p in
            let s = store.snapshot(p)
            return Bar(fill: s.shortUsed(at: now),
                       warning: s.maxUsed(at: now).flatMap(Theme.warning),
                       stale: s.error != nil)
        }
    }

    static func image(_ bars: [Bar]) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        // Рисуется при каждом отображении — цвета подстраиваются под светлую/тёмную строку меню.
        let image = NSImage(size: size, flipped: true) { _ in
            let h: CGFloat = 3, gap: CGFloat = 2.5
            var y = (size.height - (h * 3 + gap * 2)) / 2
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
        Provider.allCases.map { p in
            let s = store.snapshot(p)
            guard let used = s.shortUsed(at: now) else { return "\(p.title): нет данных" }
            return "\(p.title): \(Format.percent(used))" + (s.error != nil ? " (устарело)" : "")
        }.joined(separator: "\n")
    }
}
