# Usage Widget — правила проекта

Нативное macOS-приложение для строки меню (Swift, SwiftPM, без Xcode). Показывает лимиты подписок
Claude Code, Codex и Antigravity (agy): процент использования и время сброса каждого окна.

## Сборка и тесты

- `./test.sh` — тесты (Swift Testing). Пути к Testing.framework и плагину макросов из Command Line Tools
  подставляет скрипт: CLT, в отличие от Xcode, сам их не находит.
- `./build.sh` — `build/Лимиты ИИ.app`, ad-hoc подпись. `./build.sh install` — копия в `~/Applications` и запуск.
- **Без SwiftUI-макросов.** В SDK macOS 27 `@State`/`@Entry` — макросы, а плагина `SwiftUIMacros` в CLT нет:
  сборка падает. Состояние UI держим в `@Observable`-моделях (Observation-макросы в CLT есть).

## Устройство

- `Sources/UsageCore` — без UI, под тесты: модели, парсеры ответов (`Parsers`), источники (`Sources.swift`),
  запуск подпроцессов (`ProcessRunner`), `UsageStore` (параллельный опрос, таймер).
- `Sources/UsageWidget` — AppKit (`NSStatusItem`, `NSPopover`, `NSPanel`) + SwiftUI-контент.
- Фикстуры `Tests/UsageCoreTests/Fixtures` — реальные ответы API, обезличенные (без токенов, id аккаунтов).

## Источники данных — недокументированные, могут меняться

| Сервис | Откуда |
|---|---|
| Claude | Keychain `Claude Code-credentials` через `/usr/bin/security` → `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). Массив `limits`, запасной путь — `five_hour`/`seven_day` |
| Codex | `codex app-server` (stdio JSON-RPC): `initialize`, `initialized`, `account/rateLimits/read` |
| agy | `agy -p /usage --output-format json` → `command.data.groups[].buckets[]` (`remaining_fraction`) |

## Инварианты (ревьюеру проверять)

1. **Токены не обновляем сами.** Refresh-токены одноразовые: обновление за спиной CLI разлогинит Claude Code или
   Codex. Истёк токен — показываем прошлые данные и подсказку запустить CLI.
2. **Секреты не покидают память.** Токен не пишется в лог, UI, файлы, тексты ошибок. В фикстурах — ни токенов,
   ни идентификаторов аккаунтов.
3. **Keychain — только через `/usr/bin/security`**: он в ACL элемента Claude Code, прямой `SecItemCopyMatching`
   вызовет запрос доступа.
4. **Проценты везде «использовано»**, доля 0…1. У Codex/agy `1 − remaining` там, где API отдаёт остаток.
5. **Минимум ресурсов.** Между опросами — ничего: ни анимаций, ни постоянных таймеров перерисовки (тикает только
   подпись «через N» раз в 30 с и только пока вид на экране). Подпроцессы живут секунды, по таймауту гасятся.
6. **Упавший источник не стирает данные** других и свои прошлые — только ставит текст ошибки.
7. GUI-приложению не достаётся PATH шелла: бинари ищем по явным путям (`ProcessRunner.locate`).
