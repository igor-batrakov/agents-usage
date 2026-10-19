import Foundation

public enum Format {
    /// "in 3d 4h", "in 1h 12m", "in 5m"; in the past, "reset". Translated through `L()`.
    public static func resetIn(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("reset") }
        // Round up: "in 1m" right until the reset, never "in 0m".
        let total = Int((seconds / 60).rounded(.up))
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        let parts = d > 0 ? [L("%dd", d)] + (h > 0 ? [L("%dh", h)] : [])
            : h > 0 ? [L("%dh", h)] + (m > 0 ? [L("%dm", m)] : [])
            : [L("%dm", m)]
        return L("in %@", parts.joined(separator: " "))
    }

    /// «just now», «5 min ago», «2 h ago».
    public static func ago(_ date: Date, now: Date) -> String {
        let mins = Int(now.timeIntervalSince(date) / 60)
        if mins < 1 { return L("just now") }
        if mins < 60 { return L("%d min ago", mins) }
        return L("%d h ago", mins / 60)
    }

    /// Date and time in the language chosen in the app, not the system language.
    public static func date(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                            time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time, locale: Locale(identifier: Localization.shared.code)))
    }

    public static func percent(_ used: Double) -> String {
        "\(Int((used * 100).rounded()))%"
    }

    /// "$12.34", "¥5.00"; unknown currency: "12.34 EUR". A dot, not a comma, as on the vendor
    /// consoles the amounts come from.
    public static func money(_ amount: Double, _ currency: String) -> String {
        // Sign follows the rounded amount: -0.001 is "$0.00", not "-$0.00".
        let cents = (amount * 100).rounded()
        let value = String(format: "%.2f", abs(cents) / 100), sign = cents < 0 ? "−" : ""
        switch currency {
        case "USD": return sign + "$" + value
        case "CNY": return sign + "¥" + value
        default: return "\(sign)\(value) \(currency)"
        }
    }
}
