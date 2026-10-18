#!/bin/zsh
# Сборка .app без Xcode. `./build.sh install` — ещё и копия в ~/Applications
# (автозапуск через SMAppService привязан к месту, где лежит приложение).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/UsageWidget"
APP="build/Agents Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UsageWidget"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Переводы и список языков — по каталогам Resources/*.lproj: новый язык не требует правки Info.plist.
i=0
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$APP/Contents/Info.plist"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:$i string $(basename "$lproj" .lproj)" "$APP/Contents/Info.plist"
    i=$((i + 1))
done
codesign --force --sign - --identifier ru.batrakov.UsageWidget "$APP"
echo "Готово: $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/Agents Usage.app"
    pkill -x UsageWidget || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Установлено: $DEST"
fi
