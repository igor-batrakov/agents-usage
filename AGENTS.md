# Usage Widget — правила проекта

Нативное macOS-приложение для строки меню (Swift, SwiftPM, без Xcode). Показывает лимиты подписок
Claude Code, Codex, Antigravity (agy), GitHub Copilot, Cursor, Kimi Code, а также балансы OpenRouter и Moonshot:
процент использования и время сброса каждого окна, суммы — строкой баланса.

## Сборка и тесты

- `./test.sh` — тесты (Swift Testing). Пути к Testing.framework и плагину макросов из Command Line Tools
  подставляет скрипт: CLT, в отличие от Xcode, сам их не находит.
- `./build.sh` — `build/Agents Usage.app`, ad-hoc подпись. `./build.sh install` — копия в `~/Applications` и запуск.
- Иконка — `Resources/AppIcon.icns`, рисует её `tools/make-icon.swift`; пересобрать — `tools/make-icon.sh`.
  Bundle ID `ru.batrakov.UsageWidget` и имя бинаря `UsageWidget` не менять: к ним привязаны настройки,
  аккаунты и разрешение на уведомления.
- **Без SwiftUI-макросов.** В SDK macOS 27 `@State`/`@Entry` — макросы, а плагина `SwiftUIMacros` в CLT нет:
  сборка падает. Состояние UI держим в `@Observable`-моделях (Observation-макросы в CLT есть).

## Устройство

- `Sources/UsageCore` — без UI, под тесты: модели (`Provider` — тип из каталога, `Account` — экземпляр со своими
  настройками), каталог (`Catalog`), парсеры ответов (`Parsers`), источники (`Sources.swift`), запуск
  подпроцессов (`ProcessRunner`), `UsageStore` (параллельный опрос включённых аккаунтов, таймер),
  `Alerts` (когда уведомлять), `PollPolicy` (экономный опрос), `KeyStore` (API-ключи в Связке ключей).
- `Sources/UsageWidget` — AppKit (`NSStatusItem`, `NSPopover`, `NSPanel`, окно настроек) + SwiftUI-контент.
  `Settings` — все настройки и список аккаунтов (JSON в UserDefaults, ключ `accounts`). `Notifier` — доставка
  уведомлений, `HotKey` — глобальное сочетание (Carbon), `SystemState` — блокировка, сон дисплея, батарея.
- План развития — [docs/plan-v2.md](docs/plan-v2.md).
- Фикстуры `Tests/UsageCoreTests/Fixtures` — реальные ответы API, обезличенные (без токенов, id аккаунтов).

## Источники данных — недокументированные, могут меняться

| Сервис | Откуда |
|---|---|
| Claude | Keychain `Claude Code-credentials` (с `CLAUDE_CONFIG_DIR` — `…-<sha256(путь NFC)[0:8]>`, как в Claude Code 2.1.x) через `/usr/bin/security` → `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). Массив `limits`, запасной путь — `five_hour`/`seven_day` |
| Codex | `codex app-server` (stdio JSON-RPC, `CODEX_HOME` для второго аккаунта): `initialize`, `initialized`, `account/rateLimits/read` |
| agy | `agy -p /usage --output-format json` → `command.data.groups[].buckets[]` (`remaining_fraction`) |
| Copilot | токен `gh auth token` → `GET api.github.com/copilot_internal/user` (`Authorization: token …` + editor-заголовки) → `quota_snapshots.*.percent_remaining`, сброс `quota_reset_date_utc`; безлимитные и с `entitlement` 0 — пропуск |
| Cursor | `cursorAuth/accessToken` из `state.vscdb` (`/usr/bin/sqlite3 -readonly`) → cookie `WorkosCursorSessionToken=<хвост sub>%3A%3A<jwt>` → `GET cursor.com/api/usage-summary`. Проценты — уже проценты, деньги — центы |
| Kimi Code | API-ключ → `GET api.kimi.com/coding/v1/usages` (401 — пробуем `api.kimi.ai`): `usages.limit_*.used_ratio` или счётчики `usage` (неделя) и `limits[0]` |
| OpenRouter | API-ключ → `GET openrouter.ai/api/v1/key` (бюджет ключа, даты сброса нет) и `/credits` (баланс, необязателен) |
| Moonshot | API-ключ → `GET api.moonshot.ai/v1/users/me/balance` (401 — `api.moonshot.cn`, тогда юани) → `data.available_balance` |

## Инварианты (ревьюеру проверять)

1. **Токены не обновляем сами.** Refresh-токены одноразовые: обновление за спиной CLI разлогинит Claude Code или
   Codex. Истёк токен — показываем прошлые данные и подсказку запустить CLI.
2. **Секреты не покидают память.** Токен не пишется в лог, UI, файлы, тексты ошибок. В фикстурах — ни токенов,
   ни идентификаторов аккаунтов.
3. **Keychain — только через `/usr/bin/security`**: он в ACL элемента Claude Code, прямой `SecItemCopyMatching`
   вызовет запрос доступа. API-ключи (`KeyStore`) — свои элементы, тоже через него: ad-hoc подпись приложения
   меняется с каждой сборкой, ACL на приложение спрашивал бы доступ после каждого обновления. Ключ пишется через
   stdin (`security -i`), не аргументом — аргументы видны в `ps`; в UserDefaults и в логи не попадает.
4. **Проценты везде «использовано»**, доля 0…1. У Codex/agy `1 − remaining` там, где API отдаёт остаток.
5. **Минимум ресурсов.** Между опросами — ничего: ни анимаций, ни постоянных таймеров перерисовки (тикает только
   подпись «через N» раз в 30 с и только пока вид на экране). Подпроцессы живут секунды, по таймауту гасятся.
6. **Упавший источник не стирает данные** других и свои прошлые — только ставит текст ошибки.
7. GUI-приложению не достаётся PATH шелла: бинари ищем по явным путям (`ProcessRunner.locate`).
8. **Выключенный аккаунт не опрашивается**, его снимок отбрасывается; результат опроса аккаунта, который за время
   опроса выключили, удалили или сменили ему каталог, не записывается.
9. **Скрытые окна** не показываются и не влияют ни на цвет иконки, ни на планирование опроса к сбросу, ни на
   уведомления.
10. **id окон стабильны** между опросами (`LimitWindow.id`): по ним хранятся скрытые окна, окно для иконки и
    состояние уведомлений.
11. **Уведомление — не чаще раза за окно** и только при выданном разрешении (иначе система примет его молча,
    а окно сочтётся предупреждённым). Бесплатные сбросы Codex приложение только показывает, не тратит.
12. **Экономный опрос** пропускает только плановые опросы (таймер, разовый к сбросу при тёмном экране); ручной
    ↻, «Проверить» и открытие поповера работают всегда.
13. **Сервис только с балансом** (нет окон лимита) полоски в строке меню не получает — сумма в подсказке.
    Деньги — в единицах валюты (`Balance.amount`), центы переводятся при разборе.
