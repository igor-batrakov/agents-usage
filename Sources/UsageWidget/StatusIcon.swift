import AppKit
import UsageCore

/// Menu bar icon in three styles:
/// - bars: one per enabled account, top to bottom in list order;
///   length is the menu bar window, color is the most loaded visible window;
/// - percentages: the same values as numbers;
/// - worst: a single percentage of the most loaded window across all accounts.
/// Color: the regular menu bar color, amber from 70%, red from 90%.
@MainActor
enum StatusIcon {
    struct Bar {
        var fill: Double?       // nil means no data
        var warning: NSColor?
        var stale: Bool         // the last poll failed, old data is shown
        var maxUsed: Double?
    }

    /// Balance-only services get no bar; their amount is in the tooltip.
    static func bars(_ store: UsageStore, now: Date = Date()) -> [Bar] {
        store.enabledAccounts.filter { !$0.balanceOnly(store.snapshot($0.id)) }.map { a in
            let s = store.snapshot(a.id)
            let max = a.maxUsed(s, at: now)
            return Bar(fill: a.barUsed(s, at: now), warning: max.flatMap(Theme.warning), stale: s.error != nil, maxUsed: max)
        }
    }

    /// Applies the style to the menu bar button: an image or text.
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
        // No enabled accounts: one empty bar, otherwise the icon would vanish and could not be clicked.
        // More than 8: one summary bar for the most loaded account; bars thinner than 1 pt are indistinguishable.
        let bars: [Bar] = if bars.isEmpty {
            [Bar(fill: nil, warning: nil, stale: false, maxUsed: nil)]
        } else if bars.count > 8 {
            [bars.max { ($0.maxUsed ?? -1) < ($1.maxUsed ?? -1) }!]
        } else {
            bars
        }
        let size = NSSize(width: 18, height: 16)
        // Thickness depends on the account count: up to three bars 3 pt each, more get thinner (about 1 pt at 8).
        let n = CGFloat(bars.count)
        let gap: CGFloat = n > 6 ? 1 : n > 3 ? 1.5 : 2.5
        let h = min(3, (size.height - gap * (n - 1)) / n)
        // Drawn on every display, so the colors adapt to a light or dark menu bar.
        let image = NSImage(size: size, flipped: true) { _ in
            var y = (size.height - (h * n + gap * (n - 1))) / 2
            for bar in bars {
                let track = NSRect(x: 0, y: y, width: size.width, height: h)
                // A warning tints the track too: otherwise, with an empty 5-hour window,
                // an exhausted week would not be visible.
                (bar.warning?.withAlphaComponent(0.45) ?? NSColor.labelColor.withAlphaComponent(0.22)).setFill()
                NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
                if let fill = bar.fill, fill > 0 {
                    // The minimum is a dot, so that 1% is visible.
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
