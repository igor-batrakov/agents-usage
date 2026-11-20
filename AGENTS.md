# Agents Usage: project rules

The contributor guide is [CONTRIBUTING.md](CONTRIBUTING.md); this file holds the rules for reviewers and agents.

A native macOS menu bar app (Swift, SwiftPM, no Xcode). It shows subscription limits for Claude Code, Codex,
Antigravity (agy), GitHub Copilot, Cursor and Kimi Code, plus OpenRouter and Moonshot balances and Google Cloud
spending: usage percentage and reset time for each window, amounts as a balance line.

## Build and test

- `./test.sh` runs the tests (Swift Testing). The script supplies the paths to Testing.framework and the macro
  plugin from Command Line Tools: unlike Xcode, CLT does not find them on its own.
- `./build.sh` builds `build/Agents Usage.app` with an ad-hoc signature. `./build.sh install` copies it to
  `~/Applications` and launches it. `UNIVERSAL=1` builds arm64 + x86_64, `VERSION=` sets the Info.plist version.
- Release: `tools/release.sh v1.2.0`: universal build, `dist/Agents-Usage.zip` and `.dmg` (names without a version,
  `install.sh` downloads them from `releases/latest/download/`), `SHA256SUMS`, a GitHub release with notes from
  `docs/release-notes/<tag>.md`. There is no Developer ID signature: `install.sh` downloads with curl (no quarantine).
- Demo for the README screenshots: `open "Agents Usage.app" --args --demo [-language ru] [--demo-settings]
  [--demo-review] [--demo-panel]` (`Demo.swift`): its own UserDefaults domain (the panel position too) and
  made-up data, a made-up review chain; real settings, keys (the key buttons are off) and notification state
  are left alone, revo is never run.
- The icon is `Resources/AppIcon.icns`, drawn by `tools/make-icon.swift`; rebuild it with `tools/make-icon.sh`.
  Do not change the bundle ID `ru.batrakov.UsageWidget` or the binary name `UsageWidget`: settings, accounts and
  the notification permission are tied to them.
- **No SwiftUI macros.** In the macOS 27 SDK `@State`/`@Entry` are macros, and CLT lacks the `SwiftUIMacros`
  plugin, so the build fails. UI state lives in `@Observable` models (the Observation macros are in CLT).

## Layout

- `Sources/UsageCore` has no UI and is covered by tests: models (`Provider` is a catalog type, `Account` an instance
  with its own settings), the catalog (`Catalog`), response parsers (`Parsers`), sources (`Sources.swift`),
  subprocess launching (`ProcessRunner`), `UsageStore` (parallel polling of enabled accounts, timer),
  `Alerts` (when to notify), `PollPolicy` (low-power polling), `KeyStore` (API keys in the Keychain),
  `Updates` (latest GitHub release, version comparison), `Revolver` (the `revo` JSON contract, edits as
  `apply` operations).
- `Sources/UsageWidget` is AppKit (`NSStatusItem`, `NSPopover`, `NSPanel`, settings window) plus SwiftUI content.
  `Settings` holds all settings and the account list (JSON in UserDefaults, key `accounts`). `Notifier` delivers
  notifications, `HotKey` is the global shortcut (Carbon), `SystemState` reports lock, display sleep and battery.
  `Updater` checks for a new release and installs it; `About.swift` is the About tab and the popover update row.
  `ReviewChain` runs revo and holds the edited chain; `ReviewChainTab.swift` is the Review chain tab and the
  popover line with review limits.
- Translations live in `Resources/<code>.lproj/Localizable.strings`, the key is the English text. `Localization`
  (UsageCore) loads the selected language itself, not through `Bundle`, so the language switches in settings without
  a restart. The language list comes from the `*.lproj` directories found; `build.sh` fills `CFBundleLocalizations`.
  `tools/strings.py` collects the `L("…")` keys from the code and rebuilds `en.lproj` (the template for a new
  language); `LocalizationTests` checks the keys and `%@`/`%d`.
- Decisions of the v2 stages (done) and open ideas: [docs/plan-v2.md](docs/plan-v2.md). What each release changed:
  `docs/release-notes/`.
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
| Google Cloud | `gcloud auth print-access-token` (the token stays in memory for one poll) → a query (`POST bigquery.googleapis.com/bigquery/v2/projects/<project>/jobs`, then `GET …/queries/<jobId>`) over `` `project.dataset.gcp_billing_export_v1_*` `` (Standard usage cost export): `SUM(cost)` and `SUM(credits.amount)` for `usage_start_time` in the local month or ISO week, optionally one `project.id` and one `service.description` (Vertex AI), plus the currencies (several are an error, never summed) and `MAX(export_time)` of that project scope. At most one query per dataset, project, service and period every 15 min (`CloudBillingCache`, polls in between get the last answer), `maximumBytesBilled` 100 MB; `jobs.insert` with the one-row result in a table of its own in the export's dataset (`agents_usage_<hash of dataset, project, service, period>`, `WRITE_TRUNCATE`), then `jobs.getQueryResults` until done, never restarted. The explicit table is needed: without it BigQuery makes an anonymous dataset owned by the user, which an organization with `iam.allowedPolicyMemberDomains` refuses for a personal account. So the account needs write access to that dataset. `project.dataset` is checked by pattern before it goes into the query text; the rest are query parameters. Limit and net/gross are account settings (`Account.billing`) that only change how the same answer is read |
| Updates | `GET api.github.com/repos/igor-batrakov/agents-usage/releases/latest` → `tag_name`, `html_url` (public API, no token) |
| Revolver | `revo` at `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` or `revoPath` (chosen in settings, or found once by the login shell's `command -v revo`), run from `/` with `REVO_LANG`: `version --json` (`schemas` contains 2), `ls --json` (blocks with `role`, limits in `state`; also for the popover), `engines --json` (`vendor` is the name shown, `display` only tells engines apart; `discovered`, `model_efforts`, `models_fetched_at`; `block_fields` with `project` gives a block a Google Cloud project picker from `projects`, checked by `project_pattern`, `null` in `set` removes it), `models [--refresh] --json` (fetches model lists from the providers, no model is called, up to tens of seconds; `usage` from an older revo hides the button), `apply [--check]` with operations on stdin (`remove`, `add`, `order`, `set`, `settings`). Schema 2, `docs/json.md` in the revolver repository; JSON comes on stdout with any exit code (4 config changed, 5 busy) |

## Invariants (reviewers check these)

1. **We never refresh tokens ourselves.** Refresh tokens are single-use: refreshing behind a CLI's back logs out
   Claude Code or Codex. If a token has expired, show the previous data and a hint to run the CLI. Google Cloud
   asks `gcloud auth print-access-token`: gcloud refreshes its own (reusable) credentials, the app never sees them.
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
    manual ↻ (⌘R) and "Check" always work. Opening the popover does not poll the services. The timer is one-shot
    and counts from the last full poll, whatever started it.
13. **A balance-only service** (no limit windows) gets no bar in the menu bar; the amount goes to the tooltip.
    Money is in currency units (`Balance.amount`), cents are converted while parsing.
14. **Every UI string goes through `L("English")`**, the key as a single literal (`tools/strings.py` looks for it).
    In SwiftUI it is `Text(L("…"))`, not `Text("…")`: SwiftUI translates a literal itself, by the system language,
    bypassing the selected one. Texts from data (window titles, errors) are translated at poll time, so a language
    change triggers a poll. No global constants with `L()` (they would remember the language of the first access),
    only computed ones.
15. **Updates run only the `install.sh` bundled in the app**, with the exact release tag and the app's own folder;
    no script is downloaded. The automatic check runs at most once a day after a successful
    one (launch, settings change, popover opening; no timer of its own), can be turned off, and never runs in demo
    mode. `install.sh` quits the app with `pkill -a`: the app is the script's ancestor, and plain `pkill` skips it.
    It pins the tag of `latest` first, checks a GitHub archive against that release's `SHA256SUMS`, and copies
    the new app into a folder of its own next to the old one before replacing it, so a failed download or copy
    leaves the installed app in place. The replacement runs under a `shlock` lock in the install folder: a second
    install waits for it.
16. **The Revolver config changes only through `revo apply` after an explicit Apply**, preceded by
    `apply --check` whose diff the user confirms; the write sends the `config_rev` that was checked. The app
    never reads or writes revo's files and sends only edits by id (removed and added blocks, order,
    `on`/`model`/`effort`/`role`/`takes_over`/`project`, settings), so fields it does not know survive; with any
    edit it sends every block's role, so revo writes derived roles into the file. A chain revo accepts is never
    blocked: missing required reviewers and fallbacks that never run are warnings. revo runs only on demand (tab
    opening, Apply, popover opening at most every 15 s, the Update model lists button; app launch and tab opening
    run `models` without `--refresh`, which fetches only lists older than a day, never blocks editing and never
    touches the draft), from `/` so a project's `.revolver.json` does not apply, and never in demo mode.
    A model change moves the effort to the nearest one the model takes (`model_efforts`, else `default_efforts`;
    revo refuses it otherwise): a model picked from the menu at once, a typed one at Apply. A model in
    `unavailable` is marked, never replaced. A model in `unusable` (no effort revo passes, refused as
    `invalid_effort`) is marked, takes no `default_efforts`, and as a new or changed model holds Apply back once
    `engines`, read again at that Apply, still lists it. A failed call keeps the previous chain and limits and
    only shows the error. A path is kept as `revoPath` only after
    `version --json` passes. The one exception to invariant 7: while revo is not found, the settings window
    asks the login shell (`$SHELL -l -i -c 'command -v revo'`, stdin closed, 5 s timeout) once per launch.
