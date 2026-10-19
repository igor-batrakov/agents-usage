#!/bin/zsh
# Builds build/Agents Usage.app without Xcode (Command Line Tools are enough), ad-hoc signed.
#
#   ./build.sh            native architecture
#   ./build.sh install    also copy to ~/Applications and start (launch at login is tied to that location)
#   UNIVERSAL=1 ./build.sh          Apple Silicon + Intel in one binary (used by tools/release.sh)
#   VERSION=1.2.0 ./build.sh        version shown in Finder and About (default: Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")"
ARCHS=()
[[ "${UNIVERSAL:-}" == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/UsageWidget"
APP="build/Agents Usage.app"
PLIST="$APP/Contents/Info.plist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UsageWidget"
cp "Resources/Info.plist" "$PLIST"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The in-app updater runs this copy with the release tag (Updater.swift).
cp install.sh "$APP/Contents/Resources/install.sh"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
# Translations and the language list come from Resources/*.lproj: a new language needs no Info.plist edit.
i=0
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$PLIST"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:$i string $(basename "$lproj" .lproj)" "$PLIST"
    i=$((i + 1))
done
codesign --force --sign - --identifier ru.batrakov.UsageWidget "$APP"
echo "Built: $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/Agents Usage.app"
    pkill -x UsageWidget || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed: $DEST"
fi
