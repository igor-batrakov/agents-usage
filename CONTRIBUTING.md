# Contributing

Thanks for helping. Bug reports, new services and translations are all welcome.

## Building

You need macOS 15 or later and the Command Line Tools (`xcode-select --install`). Xcode works too but is not
required.

```sh
./build.sh            # build/Agents Usage.app
./build.sh install    # build, copy to ~/Applications and start
./test.sh             # tests (Swift Testing)
```

`./test.sh` passes the Command Line Tools paths to Testing.framework that `swift test` does not find on its own.
With Xcode installed, plain `swift test` works as well.

The Command Line Tools have no SwiftUI macro plugin, so `@State` does not compile. View state lives in
`@Observable` models instead (see `Settings.selectedAccountID`).

## Project layout

- `Sources/UsageCore` has no UI and is fully testable: models, the service catalog, response parsers, data
  sources, the polling store, notification rules, localization.
- `Sources/UsageWidget` is the app: menu bar item, popover, floating panel, settings window.
- `Tests/UsageCoreTests` holds the tests. Fixtures are real API responses with tokens and account ids removed.
- `AGENTS.md` lists the invariants every change must keep. The short version: never refresh a
  CLI's token, never log or store secrets outside the Keychain, a failing source never erases other data.

## Adding a service

1. Add a case to `Provider` (`Sources/UsageCore/Models.swift`) with its title and usage page.
2. Write a parser in `Parsers.swift` and a source in `Sources.swift`, then register it in `Catalog`.
3. Save a real response as a fixture with every token, id and email removed, and test the parser on it.
4. Pick an accent color in `Theme.swift` that stays apart from amber and red, the warning colors.

## Translations

Every interface string in the code is written as `L("English text")`. The English text is the key, so a
missing translation falls back to English.

To add a language:

1. Copy `Resources/en.lproj` to `Resources/<code>.lproj`, for example `de.lproj`.
2. Translate the right-hand side of every line in `Localizable.strings`. Keep `%@` and `%d` in the same order.
3. Run `python3 tools/strings.py` to check for missing lines, then `./test.sh`.
4. Build and pick the language in **Settings → General → Language**.

The app finds the new folder by itself. No code changes are needed.

When you add or change a string in the code, run `python3 tools/strings.py`. It updates `en.lproj` and lists
the lines other languages are missing. CI runs it with `--check`.

## Pull requests

- Keep a change focused on one thing and describe how you tested it.
- `./test.sh` must pass.
- For UI changes, attach a screenshot.

## Releases

`tools/release.sh v1.2.0` builds a universal, ad-hoc signed app, packs it as zip and dmg into `dist/`, and
publishes a GitHub release with the notes from `docs/release-notes/v1.2.0.md`.
