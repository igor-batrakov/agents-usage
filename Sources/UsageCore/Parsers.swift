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
                case "session": title = L("5 hours")
                case "weekly_all": title = L("Week")
                case "weekly_scoped": title = L("Week") + " · " + (model ?? L("model"))
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
                ("five_hour", L("5 hours"), true),
                ("seven_day", L("Week"), false),
                ("seven_day_opus", L("Week") + " · Opus", false),
                ("seven_day_sonnet", L("Week") + " · Sonnet", false),
            ]
            for (key, title, short) in named {
                guard let w = root[key] as? [String: Any], let u = number(w["utilization"]) else { continue }
                windows.append(LimitWindow(id: "claude-\(key)", title: title, used: u / 100,
                                           resetsAt: isoDate(w["resets_at"]), isShort: short,
                                           duration: short ? fiveHours : week))
            }
        }
        guard !windows.isEmpty else { throw UsageError.message(L("no limit windows in the response")) }
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
            throw UsageError.message(error["message"] as? String ?? L("app-server error"))
        }
        guard let result = root["result"] as? [String: Any] else { throw UsageError.message(L("no result in the response")) }

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
        guard !windows.isEmpty else { throw UsageError.message(L("no limit windows in the response")) }
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
        case 300: L("5 hours")
        case 10080: L("Week")
        case let m? where m % 1440 == 0: L("%d days", m / 1440)
        case let m? where m % 60 == 0: L("%d hours", m / 60)
        case let m?: L("%d min", m)
        case nil: L("Limit")
        }
    }

    // MARK: agy — `agy -p /usage --output-format json`

    public static func agy(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        guard let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]]
        else {
            let status = root["status"] as? String ?? "?"
            throw UsageError.message(L("agy returned no quotas (status %@)", status))
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
                case "5h": title = L("5 hours")
                case "weekly": title = L("Week")
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
        guard !windows.isEmpty else { throw UsageError.message(L("no limit windows in the response")) }
        return UsageReport(windows: windows, plan: nil)
    }

    static func agyGroupTitle(_ name: String) -> String {
        switch name.lowercased() {
        case "gemini models": "Gemini"
        case "claude and gpt models": L("Claude and GPT")
        case let n where n.hasPrefix("gemini 4 "): String(name.dropFirst("Gemini 4 ".count))
        default: name
        }
    }

    // MARK: Copilot — GET api.github.com/copilot_internal/user

    /// Месячные квоты. Безлимитные и с нулевым объёмом (премиум на бесплатном плане) — пропуск.
    public static func copilot(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        let reset = isoDate(root["quota_reset_date_utc"])
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        var windows: [LimitWindow] = []
        for (key, title) in [("premium_interactions", L("Premium requests")), ("chat", L("Chat")), ("completions", L("Completions"))] {
            guard let quota = snapshots[key] as? [String: Any], quota["unlimited"] as? Bool != true,
                  let entitlement = number(quota["entitlement"]), entitlement > 0,
                  let remaining = number(quota["percent_remaining"]) else { continue }
            windows.append(LimitWindow(id: "copilot-\(key)", title: title, used: 1 - remaining / 100,
                                       resetsAt: reset, isShort: false, duration: monthBefore(reset)))
        }
        guard !windows.isEmpty else { throw UsageError.message(L("no Copilot quotas in the response")) }
        let sku = root["access_type_sku"] as? String ?? ""
        let plan = sku.contains("free") ? "Free" : (root["copilot_plan"] as? String).map(capitalized)
        return UsageReport(windows: windows, plan: plan)
    }

    // MARK: Cursor — GET cursor.com/api/usage-summary

    /// Проценты в ответе — уже проценты (0.36 — это 0,36%), деньги — в центах.
    public static func cursor(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        let start = isoDate(root["billingCycleStart"]), end = isoDate(root["billingCycleEnd"])
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
        let usage = root["individualUsage"] as? [String: Any] ?? [:]
        let plan = usage["plan"] as? [String: Any] ?? [:]
        var windows: [LimitWindow] = []
        func add(_ id: String, _ title: String, _ used: Double?) {
            guard let used else { return }
            windows.append(LimitWindow(id: "cursor-\(id)", title: title, used: used, resetsAt: end,
                                       isShort: false, duration: duration))
        }
        let ratio = number(plan["used"]).flatMap { u in number(plan["limit"]).flatMap { $0 > 0 ? u / $0 : nil } }
        add("plan", L("Included in plan"), number(plan["totalPercentUsed"]).map { $0 / 100 } ?? ratio)
        add("auto", "Auto", number(plan["autoPercentUsed"]).map { $0 / 100 })
        add("api", L("API models"), number(plan["apiPercentUsed"]).map { $0 / 100 })

        var balances: [Balance] = []
        if let onDemand = usage["onDemand"] as? [String: Any], onDemand["enabled"] as? Bool == true,
           let used = number(onDemand["used"]) {
            if let limit = number(onDemand["limit"]), limit > 0 {
                add("on-demand", L("On-demand"), used / limit)
            } else {
                balances.append(Balance(id: "cursor-on-demand", title: L("On-demand"), amount: used / 100, currency: "USD"))
            }
        }
        guard !windows.isEmpty || !balances.isEmpty else { throw UsageError.message(L("no Cursor data in the response")) }
        let membership = (root["membershipType"] as? String).map(capitalized)
        return UsageReport(windows: windows, plan: membership, balances: balances)
    }

    // MARK: Kimi Code — GET api.kimi.com/coding/v1/usages

    /// Новый формат — доли `usages.limit_*.used_ratio`; старый — счётчики-строки `usage` (неделя)
    /// и `limits[0]` (короткое окно). id окон одинаковы в обоих: по ним хранятся скрытые окна.
    public static func kimi(_ data: Data) throws -> UsageReport {
        let root = try object(data)
        var windows: [LimitWindow] = []
        if let pools = root["usages"] as? [String: Any] {
            for (key, id, title, duration) in [("limit_5h", "5h", L("5 hours"), fiveHours), ("limit_7d", "week", L("Week"), week),
                                               ("limit_month_total", "month", L("Month"), nil as TimeInterval?)] {
                guard let pool = pools[key] as? [String: Any], let ratio = number(pool["used_ratio"]) else { continue }
                let reset = isoDate(pool["reset_time"])
                windows.append(LimitWindow(id: "kimi-\(id)", title: title, used: ratio, resetsAt: reset,
                                           isShort: id == "5h", duration: duration ?? monthBefore(reset)))
            }
        } else {
            if let limit = (root["limits"] as? [[String: Any]])?.first,
               let detail = limit["detail"] as? [String: Any], let used = countRatio(detail) {
                let w = limit["window"] as? [String: Any] ?? [:]
                let unit: Double = switch w["timeUnit"] as? String {
                case "TIME_UNIT_HOUR": 60
                case "TIME_UNIT_DAY": 1440
                default: 1
                }
                let minutes = number(w["duration"]).map { Int($0 * unit) }
                windows.append(LimitWindow(id: minutes == 300 ? "kimi-5h" : "kimi-limit-\(minutes ?? 0)",
                                           title: windowTitle(minutes: minutes), used: used,
                                           resetsAt: resetDate(detail), isShort: (minutes ?? 0) <= 300,
                                           duration: minutes.map { TimeInterval($0 * 60) }))
            }
            if let weekly = root["usage"] as? [String: Any], let used = countRatio(weekly) {
                windows.append(LimitWindow(id: "kimi-week", title: L("Week"), used: used, resetsAt: resetDate(weekly),
                                           isShort: false, duration: week))
            }
        }
        guard !windows.isEmpty else { throw UsageError.message(L("no limit windows in the response")) }
        let level = ((root["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
        let plan = level.flatMap { ["LEVEL_FREE": "Adagio", "LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato",
                                    "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro"][$0] }
        return UsageReport(windows: windows, plan: plan)
    }

    /// `used/limit`, без `used` — `(limit − remaining)/limit`; лимит ≤ 0 — окна нет.
    static func countRatio(_ d: [String: Any]) -> Double? {
        guard let limit = number(d["limit"]), limit > 0 else { return nil }
        if let used = number(d["used"]) { return used / limit }
        return number(d["remaining"]).map { (limit - $0) / limit }
    }

    static func resetDate(_ d: [String: Any]) -> Date? {
        ["resetTime", "resetAt", "reset_time", "reset_at"].lazy.compactMap { isoDate(d[$0]) }.first
    }

    // MARK: OpenRouter — GET openrouter.ai/api/v1/key и /credits

    /// `key` — бюджет ключа (доллары): окно, если лимит задан, иначе траты ключа. Даты сброса
    /// API не даёт — только период. `credits` — баланс счёта; nil — запрос не удался.
    public static func openRouter(key: Data, credits: Data?) throws -> UsageReport {
        guard let k = try object(key)["data"] as? [String: Any] else { throw UsageError.message(L("no data in the response")) }
        var windows: [LimitWindow] = []
        var balances: [Balance] = []
        if let limit = number(k["limit"]), limit > 0 {
            let reset = k["limit_reset"] as? String
            let used = number(k["limit_remaining"]).map { limit - min(max($0, 0), limit) }
                ?? reset.flatMap { number(k["usage_\($0)"]) } ?? number(k["usage"]) ?? 0
            let title = switch reset {
            case "daily": L("Key · day")
            case "weekly": L("Key · week")
            case "monthly": L("Key · month")
            default: L("Key · limit")
            }
            windows.append(LimitWindow(id: "openrouter-key", title: title, used: used / limit, resetsAt: nil, isShort: false))
        }
        if let credits {
            // Ответ есть, но не разобрать — ошибка, а не «баланса нет»: иначе показанный баланс пропал бы молча.
            guard let c = try object(credits)["data"] as? [String: Any],
                  let total = number(c["total_credits"]), let spent = number(c["total_usage"])
            else { throw UsageError.message(L("no balance in the /credits response")) }
            balances.append(Balance(id: "openrouter-credits", title: L("Balance"), amount: max(0, total - spent), currency: "USD"))
        }
        if windows.isEmpty, balances.isEmpty, let usage = number(k["usage"]) {
            balances.append(Balance(id: "openrouter-key-usage", title: L("Spent by key"), amount: usage, currency: "USD"))
        }
        guard !windows.isEmpty || !balances.isEmpty else { throw UsageError.message(L("no OpenRouter data in the response")) }
        return UsageReport(windows: windows, plan: nil, balances: balances)
    }

    // MARK: Moonshot — GET api.moonshot.ai/v1/users/me/balance

    /// Только баланс; валюта — по домену: .ai — доллары, .cn — юани.
    public static func moonshot(_ data: Data, currency: String) throws -> UsageReport {
        let root = try object(data)
        if let code = number(root["code"]), code != 0 {
            throw UsageError.message(root["scode"] as? String ?? L("API error: %d", Int(code)))
        }
        guard let d = root["data"] as? [String: Any], let available = number(d["available_balance"]) else {
            throw UsageError.message(L("no balance in the response"))
        }
        return UsageReport(windows: [], plan: nil, balances: [
            Balance(id: "moonshot-balance", title: L("Balance"), amount: available, currency: currency),
        ])
    }

    // MARK: helpers

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Длина месячного окна, кончающегося в `end` (календарный месяц, UTC): для метки темпа.
    static func monthBefore(_ end: Date?) -> TimeInterval? {
        guard let end else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: -1, to: end).map { end.timeIntervalSince($0) }
    }

    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message(L("response is not JSON"))
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
