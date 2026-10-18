import Foundation

public enum Format {
    /// «in 3d 4h», «in 1h 12m», «in 5m»; прошедший — «reset». По-русски — «через 3 д 4 ч».
    public static func resetIn(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("reset") }
        // Округляем вверх: «через 1 м» до самого сброса, без «через 0 м».
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

    /// Дата и время на выбранном в приложении языке, а не на языке системы.
    public static func date(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                            time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time, locale: Locale(identifier: Localization.shared.code)))
    }

    public static func percent(_ used: Double) -> String {
        "\(Int((used * 100).rounded()))%"
    }

    /// «$12.34», «¥5.00»; неизвестная валюта — «12.34 EUR». Точка, а не запятая: суммы с консолей
    /// вендоров, где их пишут так же.
    public static func money(_ amount: Double, _ currency: String) -> String {
        // Знак — по округлённой сумме: −0,001 — это «$0.00», а не «−$0.00».
        let cents = (amount * 100).rounded()
        let value = String(format: "%.2f", abs(cents) / 100), sign = cents < 0 ? "−" : ""
        switch currency {
        case "USD": return sign + "$" + value
        case "CNY": return sign + "¥" + value
        default: return "\(sign)\(value) \(currency)"
        }
    }
}
