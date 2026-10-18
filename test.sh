#!/bin/zsh
# swift test с путями к Testing.framework из Command Line Tools:
# CLT (в отличие от Xcode) не подставляет их сам.
set -euo pipefail
cd "$(dirname "$0")"
DEV="$(xcode-select -p)"           # /Library/Developer/CommandLineTools
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
# Плагин макросов @Test/#expect лежит в CLT отдельно, swiftbuild его сам не находит.
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
exec swift test \
    -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
