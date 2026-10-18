#!/bin/zsh
# Сборка .app без Xcode. `./build.sh install` — ещё и копия в ~/Applications
# (автозапуск через SMAppService привязан к месту, где лежит приложение).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/UsageWidget"
APP="build/Лимиты ИИ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/UsageWidget"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier ru.batrakov.UsageWidget "$APP"
echo "Готово: $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/Лимиты ИИ.app"
    pkill -x UsageWidget || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Установлено: $DEST"
fi
