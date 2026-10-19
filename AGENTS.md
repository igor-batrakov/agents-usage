# Agents Usage: project rules

The contributor guide is [CONTRIBUTING.md](CONTRIBUTING.md); this file holds the rules for reviewers and agents.

A native macOS menu bar app (Swift, SwiftPM, no Xcode). It shows subscription limits for Claude Code, Codex,
Antigravity (agy), GitHub Copilot, Cursor and Kimi Code, plus OpenRouter and Moonshot balances: usage percentage
and reset time for each window, amounts as a balance line.

## Build and test

- `./test.sh` runs the tests (Swift Testing). The script supplies the paths to Testing.framework and the macro
  plugin from Command Line Tools: unlike Xcode, CLT does not find them on its own.
- `./build.sh` builds `build/Agents Usage.app` with an ad-hoc signature. `./build.sh install` copies it to
  `~/Applications` and launches it. `UNIVERSAL=1` builds arm64 + x86_64, `VERSION=` sets the Info.plist version.
- Release: `tools/release.sh v1.2.0`: universal build, `dist/Agents-Usage.zip` and `.dmg` (names without a version,
  `install.sh` downloads them from `releases/latest/download/`), `SHA256SUMS`, a GitHub release with notes from
  `docs/release-notes/<tag>.md`. There is no Developer ID signature: `install.sh` downloads with curl (no quarantine).
- Demo for the README screenshots: `open "Agents Usage.app" --args --demo [-language ru] [--demo-settings]`
  (`Demo.swift`): its own UserDefaults domain and made-up data; real settings, keys and notification state are
  left alone.
- The icon is `Resources/AppIcon.icns`, drawn by `tools/make-icon.swift`; rebuild it with `tools/make-icon.sh`.
  Do not change the bundle ID `ru.batrakov.UsageWidget` or the binary name `UsageWidget`: settings, accounts and
  the notification permission are tied to them.
- **No SwiftUI macros.** In the macOS 27 SDK `@State`/`@Entry` are macros, and CLT lacks the `SwiftUIMacros`
  plugin, so the build fails. UI state lives in `@Observable` models (the Observation macros are in CLT).

## Layout

- `Sources/UsageCore` has no UI and is covered by tests: models (`Provider` is a catalog type, `Account` an instance
  with its own settings), the catalog (`Catalog`), response parsers (`Parsers`), sources (`Sources.swift`),
  subprocess launching (`ProcessRunner`), `UsageStore` (parallel polling of enabled accounts, timer),
  `Alerts` (when to notify), `PollPolicy` (low-power polling), `KeyStore` (API keys in the Keychain).
- `Sources/UsageWidget` is AppKit (`NSStatusItem`, `NSPopover`, `NSPanel`, settings window) plus SwiftUI content.
  `Settings` holds all settings and the account list (JSON in UserDefaults, key `accounts`). `Notifier` delivers
  notifications, `HotKey` is the global shortcut (Carbon), `SystemState` reports lock, display sleep and battery.
- Translations live in `Resources/<code>.lproj/Localizable.strings`, the key is the English text. `Localization`
  (UsageCore) loads the selected language itself, not through `Bundle`, so the language switches in settings without
  a restart. The language list comes from the `*.lproj` directories found; `build.sh` fills `CFBundleLocalizations`.
  `tools/strings.py` collects the `L("…")` keys from the code and rebuilds `en.lproj` (the template for a new
  language); `LocalizationTests` checks the keys and `%@`/`%d`.
- Roadmap: [docs/plan-v2.md](docs/plan-v2.md).
- Fixtures in `Tests/UsageCoreTests/Fixtures` are real API responses, anonymized (no tokens, no account ids).

## Data sources: undocumented, may change

| Service | Source |
|---|---|
| Claude | Keychain `Claude Code-credentials` (with `CLAUDE_CONFIG_DIR`: `…-<sha256(NFC path)[0:8]>`, as in Claude Code 2.1.x) via `/usr/bin/security` → `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). The `limits` array, falling back to `five_hour`/`seven_day` |
| Codex | `codex app-server` (stdio JSON-RPC, `CODEX_HOME` for a second account): `initialize`, `initialized`, `account/rateLimits/read` |
| agy | `agy -p /usage --output-format json` → `command.data.groups[].buckets[]` (`remaining_fraction`) |
| Copilot | `gh auth token` → `GET api.github.com/copilot_internal/user` (`Authorization: token …` + editor headers) → `quota_snapshots.*.percent_remaining`, reset `quota_reset_date_utc`; unlimited ones and those with `entitlement` 0 are skipped |
| Cursor | `cursorAuth/accessToken` from `state.vscdb` (`/usr/bin/sqlite3 -readonly`) → cookie `WorkosCursorSessionToken=<sub tail>%3A%3A<jwt>` → `GET cursor.com/api/usage-summary`. Percentages are already percentages, money is in cents |
| Kimi Code | API key → `GET api.kimi.com/coding/v1/usages` (on 401, try `api.kimi.ai`): `usages.limit_*.used_ratio` or the `usage` counters (week) and `limits[0]` |
| OpenRouter | API key → `GET openrouter.ai/api/v1/key` (key budget, no reset date) and `/credits` (balance, optional) |
| Moonshot | API key → `GET api.moonshot.ai/v1/users/me/balance` (on 401, `api.moonshot.cn`, then yuan) → `data.available_balance` |

## Invariants (reviewers check these)

1. **We never refresh tokens ourselves.** Refresh tokens are single-use: refreshing behind a CLI's back logs out
   Claude Code or Codex. If a token has expired, show the previous data and a hint to run the CLI.
2. **Secrets stay in memory.** A token never goes to the log, UI, files or error texts. Fixtures contain no tokens
   and no account identifiers.
3. **Keychain only through `/usr/bin/security`**: it is in the ACL of the Claude Code item, while a direct
   `SecItemCopyMatching` would trigger an access prompt. API keys (`KeyStore`) are our own items, also through it:
   the app's ad-hoc signature changes with every build, so an ACL on the app would ask for access after every update.
   The key is written through stdin (`security -i`), not as an argument, since arguments show up in `ps`; it never
   reaches UserDefaults or the logs.
4. **Percentages always mean "used"**, as a 0…1 fraction. For Codex/agy it is `1 − remaining` where the API
   returns the remainder.
5. **Minimal resources.** Nothing runs between polls: no animations, no permanent redraw timers (only the "in N"
   label ticks, every 30 s and only while the view is on screen). Subprocesses live for seconds and are killed on
   timeout.
6. **A failed source never erases data**, neither other sources' nor its own previous data; it only sets an
   error text.
7. A GUI app does not get the shell PATH: binaries are looked up at explicit paths (`ProcessRunner.locate`).
8. **A disabled account is not polled**, its snapshot is dropped; the poll result of an account that was disabled,
   removed or given another directory during the poll is not stored.
9. **Hidden windows** are not shown and affect neither the icon color, nor scheduling the poll at reset, nor
   notifications.
10. **Window ids are stable** across polls (`LimitWindow.id`): hidden windows, the icon window and notification
    state are stored by them.
11. **At most one notification per window**, and only with permission granted (otherwise the system accepts it
    silently and the window counts as warned). The app only shows free Codex resets, it never spends them.
12. **Low-power polling** skips only scheduled polls (the timer, the one-off poll at reset while the screen is dark);
    manual ↻, "Check" and opening the popover always work.
13. **A balance-only service** (no limit windows) gets no bar in the menu bar; the amount goes to the tooltip.
    Money is in currency units (`Balance.amount`), cents are converted while parsing.
14. **Every UI string goes through `L("English")`**, the key as a single literal (`tools/strings.py` looks for it).
    In SwiftUI it is `Text(L("…"))`, not `Text("…")`: SwiftUI translates a literal itself, by the system language,
    bypassing the selected one. Texts from data (window titles, errors) are translated at poll time, so a language
    change triggers a poll. No global constants with `L()` (they would remember the language of the first access),
    only computed ones.
