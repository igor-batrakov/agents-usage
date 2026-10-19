#!/bin/zsh
# swift test with paths to Testing.framework from Command Line Tools:
# CLT (unlike Xcode) does not add them on its own.
set -euo pipefail
cd "$(dirname "$0")"
DEV="$(xcode-select -p)"           # /Library/Developer/CommandLineTools
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
# The @Test/#expect macro plugin sits separately in CLT, swiftbuild does not find it on its own.
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
exec swift test \
    -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
