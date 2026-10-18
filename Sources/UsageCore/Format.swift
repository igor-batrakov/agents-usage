import Foundation

public enum Format {
    /// «через 3 д 4 ч», «через 1 ч 12 м», «через 5 м», «сейчас».
    public static func resetIn(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "сброшен" }
        // Округляем вверх: «через 1 м» до самого сброса, без «через 0 м».
        let total = Int((seconds / 60).rounded(.up))
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return h > 0 ? "через \(d) д \(h) ч" : "через \(d) д" }
        if h > 0 { return m > 0 ? "через \(h) ч \(m) м" : "через \(h) ч" }
        return "через \(m) м"
    }

    /// «только что», «5 мин назад», «2 ч назад».
    public static func ago(_ date: Date, now: Date) -> String {
        let mins = Int(now.timeIntervalSince(date) / 60)
        if mins < 1 { return "только что" }
        if mins < 60 { return "\(mins) мин назад" }
        return "\(mins / 60) ч назад"
    }

    public static func percent(_ used: Double) -> String {
        "\(Int((used * 100).rounded()))%"
    }
}
