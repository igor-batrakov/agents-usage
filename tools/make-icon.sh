#!/bin/zsh
# Пересобирает Resources/AppIcon.icns из tools/make-icon.swift (нужно только при смене рисунка).
set -euo pipefail
cd "$(dirname "$0")/.."
SET="build/AppIcon.iconset"
mkdir -p "$SET"
swift tools/make-icon.swift build/AppIcon.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Готово: Resources/AppIcon.icns ($(ls "$SET" | wc -l | tr -d ' ') размеров, $(du -h Resources/AppIcon.icns | cut -f1))"
