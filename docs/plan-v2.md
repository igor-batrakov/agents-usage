# Plan v2: services, settings, panel

Three stages, one PR each: foundation, additions, new vendors.

## Decisions

- Services are a **catalog** (source types in code) plus **accounts** (instances: several per service, for
  example a second `CLAUDE_CONFIG_DIR`). "Remove" deletes an account, "disable" keeps it but hides it.
- A disabled account is **not polled**; once enabled, it is polled right away.
- Clicking a service opens the **vendor's usage page** in the browser; the URL is editable in settings.
- The popover is for quick actions only; detailed settings live in a separate window with tabs.
- Kimi Code uses an **API key** from the Kimi console (the CLI is left alone: its refresh token is single-use).
- Gemini CLI is not supported: Google turned off sign-in for personal accounts on 18.06.2026, Antigravity
  replaces it.
- Anthropic/OpenAI API balances are not supported: the API exposes no balance, and spending needs an
  organization admin key.

## Stage 1: foundation

- `ProviderKind` (catalog): name, accent, how to detect it (CLI/file/key), usage page link, support for
  multiple accounts, account parameters.
- `Account`: id, kind, name, enabled, order, parameters (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), hidden windows,
  menu bar window, custom link. Stored as JSON in UserDefaults; v1 migration creates accounts for the CLIs found.
- Only enabled accounts are polled; an auto-refresh toggle (also the pause in the popover) and an interval of
  1 / 5 / 15 / 30 min. With auto-refresh off, only ↻ (and the first poll at launch).
- Popover: the service title is a link; footer: updated time, ↻, pause, panel on/off, settings, quit.
- Settings window (TabView):
  - **General**: interval, launch at login, icon style (bars / percentages / worst only);
  - **Services**: a list with drag to reorder, toggle, "+" from the catalog, "−"; account details: name,
    parameters, visible windows, menu bar window, link, "Check";
  - **Panel**: on/off, level, anchor (4 corners / free) and margin, opacity, click-through
    (in both modes), set of services.
- Panel: close button on hover; the anchor holds when the screen changes; dragging switches it to "free".

Done.

## Stage 2: additions

- Pace marker on the bar (elapsed fraction of the window; windows get a length).
- Notifications: threshold (90% by default) and "window reset"; at most once per window.
- Free Codex resets (`rateLimitResetCredits`): count and nearest expiry, as a link.
- Low-power polling: skip while the screen is locked or the display sleeps, poll after unlock if the data is
  stale; on battery the interval is ×3. Popover hotkey.

Done, followed by the Agents Usage name and icon.

How it was built:
- Pace: `LimitWindow.duration` (Claude: session 5 h, weekly 7 days; Codex: `windowDurationMins`; agy:
  `5h`/`weekly`), `pace(at:)`; a tick on the bar, a toggle in General.
- Notifications: `Alerts.evaluate` (UsageCore, covered by tests): "window → its reset time" state in UserDefaults
  (`alertState`); reset notifications only for windows that reached the threshold, and no later than an hour after
  the reset. Evaluated only with permission granted: without it the system silently accepts a notification, and the
  window would count as warned.
- Codex resets: `UsageReport.freeResets` (available `credits`, nearest `expiresAt`); the app never spends them.
- Low-power polling: `PollPolicy.timerShouldPoll` through `UsageStore.timerGate`; lock via
  `CGSessionCopyCurrentDictionary`, display sleep via `CGDisplayIsAsleep`, battery via
  `IOPSGetProvidingPowerSourceType`, all checked at tick time. After sleep and unlock, one catch-up poll for all
  wake notifications (`catchUp`): right away if a window reset passed that the fresh snapshot has not seen yet
  (`hasPassedReset`), otherwise if the data is stale.
- Hotkey: Carbon `RegisterEventHotKey` (no Accessibility permission needed), choice of ⌃⌥L / ⌃⌥U / none.

## Stage 3: new vendors

| Service | Source (checked 18.10) | Shown |
|---|---|---|
| GitHub Copilot | `GET api.github.com/copilot_internal/user`, `gh` token (`Authorization: token …` + editor headers): 200 | `quota_snapshots.{premium_interactions,chat,completions}`: used = 1 − percent_remaining/100, reset `quota_reset_date_utc`; `unlimited` and entitlement 0 are skipped |
| Cursor | `GET cursor.com/api/usage-summary`, cookie `WorkosCursorSessionToken=<userId>%3A%3A<jwt>` from `state.vscdb` (`cursorAuth/accessToken`, read-only): 200. `api2.cursor.sh` is blocked by Cloudflare (1010) | `individualUsage.plan` (totalPercentUsed, used/limit), `onDemand`, reset `billingCycleEnd` |
| Kimi Code | `GET api.kimi.com/coding/v1/usages`, Bearer API key | `usage` (week), `limits[]` (5 h), `boosterWallet` |
| OpenRouter | `GET openrouter.ai/api/v1/key` (+ `/credits`), Bearer key | $ balance, key budget with reset |
| Moonshot | `GET api.moonshot.ai/v1/users/me/balance` (.cn for Chinese keys) | `available_balance` |

A money metric (a balance, or spending against a limit, with currency) is a new kind shown next to the limit window.

Usage page links: Claude `https://claude.ai/settings/usage`, Codex
`https://chatgpt.com/codex/settings/usage` (to verify), Copilot `https://github.com/settings/copilot/features`,
Cursor `https://cursor.com/dashboard/spending`, OpenRouter `https://openrouter.ai/activity`,
Moonshot `https://platform.moonshot.ai/console/account`, Kimi Code `https://www.kimi.com/code/console` (to verify),
agy has no web page (to clarify).

Reference for cross-checking endpoints: [steipete/CodexBar](https://github.com/steipete/CodexBar).

How it was built:
- Copilot: the `gh auth token` token (gh stores and refreshes it), not a separate OAuth sign-in as in CodexBar.
  On the free plan the premium quota is zero and is not shown. Windows are monthly, pace follows the calendar month.
- Cursor: the token from `state.vscdb` via `/usr/bin/sqlite3 -readonly`; windows "Included in plan", Auto and API
  models per billing period; on-demand with a limit is a window, without a limit it is the amount spent.
- Kimi Code, OpenRouter, Moonshot: an API key per account in the Keychain (`KeyStore`, via `/usr/bin/security`),
  with a key field and a "Get a key" link in the service settings. The key region (`.ai`/`.com` or `.cn`)
  is not asked for: on a 401 from the international URL, the second one is tried.
- Money metric: `UsageReport.balances` (`Balance`: amount in currency units). A balance-only service gets no
  menu bar bar.
- Copilot and Cursor were checked live on free plans. Kimi, OpenRouter and Moonshot follow the CodexBar response
  samples; a live check comes once keys are configured.
