import Foundation

/// Разбор ответов трёх источников в общий `UsageReport`. Чистые функции — под тесты.
public enum Parsers {

    // MARK: Claude — GET api.anthropic.com/api/oauth/usage

    public static func claude(_ data: Data, plan: String?) throws -> UsageReport {
        let root = try object(data)
        var windows: [LimitWindow] = []

        // Новый формат: массив `limits` с видом окна и моделью (например, «Fable»).
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            for limit in limits {
                guard let percent = number(limit["percent"]) else { continue }
                let kind = limit["kind"] as? String ?? "limit"
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let title: String
                switch kind {
                case "session": title = "5 часов"
                case "weekly_all": title = "Неделя"
                case "weekly_scoped": title = "Неделя · \(model ?? "модель")"
                default: title = model.map { "\(kind) · \($0)" } ?? kind
                }
                windows.append(LimitWindow(
                    // id стабилен между опросами: по нему запоминаются скрытые окна и окно для иконки.
                    id: "claude-\(kind)" + (model.map { "-\($0)" } ?? ""),
                    title: title,
                    used: percent / 100,
                    resetsAt: isoDate(limit["resets_at"]),
                    isShort: kind == "session",
                    duration: kind == "session" ? fiveHours : kind.hasPrefix("weekly") ? week : nil))
            }
        } else {
            // Старый формат: именованные окна с `utilization` 0–100.
            let named: [(String, String, Bool)] = [
                ("five_hour", "5 часов", true),
                ("seven_day", "Неделя", false),
                ("seven_day_opus", "Неделя · Opus", false),
                ("seven_day_sonnet", "Неделя · Sonnet", false),
            ]
            for (key, title, short) in named {
                guard let w = root[key] as? [String: Any], let u = number(w["utilization"]) else { continue }
                windows.append(LimitWindow(id: "claude-\(key)", title: title, used: u / 100,
                                           resetsAt: isoDate(w["resets_at"]), isShort: short,
                                           duration: short ? fiveHours : week))
            }
        }
        guard !windows.isEmpty else { throw UsageError.message("в ответе нет окон лимита") }
        return UsageReport(windows: windows, plan: plan)
    }

    /// «max» + «default_claude_max_5x» → «Max 5x».
    public static func claudePlan(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        var plan = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let tier, let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            plan += " " + tier[range]
        }
        return plan
    }

    // MARK: Codex — app-server account/rateLimits/read

    public static func codex(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        if let error = root["error"] as? [String: Any] {
            throw UsageError.message(error["message"] as? String ?? "ошибка app-server")
        }
        guard let result = root["result"] as? [String: Any] else { throw UsageError.message("нет result") }

        // Основной лимит первым, затем дополнительные (если появятся отдельные лимиты моделей).
        var snapshots: [[String: Any]] = []
        if let main = result["rateLimits"] as? [String: Any] { snapshots.append(main) }
        if let byId = result["rateLimitsByLimitId"] as? [String: [String: Any]] {
            let mainId = snapshots.first?["limitId"] as? String
            for key in byId.keys.sorted() where key != mainId { snapshots.append(byId[key]!) }
        }

        var windows: [LimitWindow] = []
        var plan: String?
        for (index, snap) in snapshots.enumerated() {
            let limitId = snap["limitId"] as? String ?? "codex"
            let prefix = index == 0 ? nil : (snap["limitName"] as? String ?? limitId)
            if plan == nil, let p = snap["planType"] as? String { plan = p.prefix(1).uppercased() + p.dropFirst() }
            for key in ["primary", "secondary"] {
                guard let w = snap[key] as? [String: Any], let pct = number(w["usedPercent"]) else { continue }
                let mins = number(w["windowDurationMins"]).map(Int.init)
                let base = windowTitle(minutes: mins)
                windows.append(LimitWindow(
                    id: "codex-\(limitId)-\(key)",
                    title: prefix.map { "\(base) · \($0)" } ?? base,
                    used: pct / 100,
                    resetsAt: number(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
                    isShort: (mins ?? 0) <= 300,
                    duration: mins.map { TimeInterval($0 * 60) }))
            }
        }
        guard !windows.isEmpty else { throw UsageError.message("в ответе нет окон лимита") }
        return UsageReport(windows: windows, plan: plan, freeResets: codexFreeResets(result))
    }

    /// `rateLimitResetCredits`: бесплатные полные сбросы. Считаем только доступные; нет ни одного — nil.
    static func codexFreeResets(_ result: [String: Any]) -> FreeResets? {
        guard let root = result["rateLimitResetCredits"] as? [String: Any] else { return nil }
        let available = (root["credits"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "available" }
        let count = number(root["availableCount"]).map(Int.init) ?? available.count
        guard count > 0 else { return nil }
        let next = available.compactMap { number($0["expiresAt"]) }.min().map { Date(timeIntervalSince1970: $0) }
        return FreeResets(count: count, nextExpiry: next)
    }

    static func windowTitle(minutes: Int?) -> String {
        switch minutes {
        case 300: "5 часов"
        case 10080: "Неделя"
        case let m? where m % 1440 == 0: "\(m / 1440) дн."
        case let m? where m % 60 == 0: "\(m / 60) ч"
        case let m?: "\(m) мин"
        case nil: "Лимит"
        }
    }

    // MARK: agy — `agy -p /usage --output-format json`

    public static func agy(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        guard let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]]
        else {
            let status = root["status"] as? String ?? "?"
            throw UsageError.message("agy не вернул квоты (status \(status))")
        }
        var windows: [LimitWindow] = []
        for group in groups {
            let groupName = agyGroupTitle(group["name"] as? String ?? "")
            // agy отдаёт неделю раньше 5 часов; у остальных сервисов короткое окно первым — выравниваем.
            let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                .sorted { ($0["window"] as? String == "5h") && ($1["window"] as? String != "5h") }
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let remaining = number(bucket["remaining_fraction"]) else { continue }
                let window = bucket["window"] as? String ?? ""
                let title: String
                switch window {
                case "5h": title = "5 часов"
                case "weekly": title = "Неделя"
                default: title = bucket["name"] as? String ?? window
                }
                windows.append(LimitWindow(
                    id: "agy-\(bucket["id"] as? String ?? "\(groupName)-\(window)")",
                    title: title,
                    group: groupName,
                    used: 1 - remaining,
                    resetsAt: isoDate(bucket["reset_time"]),
                    isShort: window == "5h",
                    duration: window == "5h" ? fiveHours : window == "weekly" ? week : nil))
            }
        }
        guard !windows.isEmpty else { throw UsageError.message("в ответе нет окон лимита") }
        return UsageReport(windows: windows, plan: nil)
    }

    static func agyGroupTitle(_ name: String) -> String {
        switch name.lowercased() {
        case "gemini models": "Gemini"
        case "claude and gpt models": "Claude и GPT"
        case let n where n.hasPrefix("gemini 4 "): String(name.dropFirst("Gemini 4 ".count))
        default: name
        }
    }

    // MARK: helpers

    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("ответ не JSON")
        }
        return obj
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber where !(n === kCFBooleanTrue || n === kCFBooleanFalse): n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        // У Claude — микросекунды (`.394710+00:00`), их ISO8601DateFormatter не понимает.
        // Отрезаем дробную часть: точность до секунды достаточна.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
