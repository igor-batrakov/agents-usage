#!/bin/zsh
# Builds a release: a universal app (Apple Silicon + Intel), ad-hoc signed, packed as zip and dmg in dist/.
#
#   tools/release.sh            build dist/Agents-Usage.zip, dist/Agents-Usage.dmg and dist/SHA256SUMS
#   tools/release.sh v1.0.0     the same with that version, then publish a GitHub release (needs gh)
#
# Asset names carry no version: install.sh downloads releases/latest/download/Agents-Usage.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-}"

UNIVERSAL=1 VERSION="${TAG#v}" ./build.sh
APP="build/Agents Usage.app"
lipo -archs "$APP/Contents/MacOS/UsageWidget" | grep -q x86_64 || { echo "the binary is not universal" >&2; exit 1; }

mkdir -p dist
ditto -c -k --keepParent "$APP" dist/Agents-Usage.zip

# The dmg holds the app and a shortcut to /Applications to drag it onto.
stage=$(mktemp -d)
ditto "$APP" "$stage/Agents Usage.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Agents Usage" -srcfolder "$stage" -format UDZO -ov dist/Agents-Usage.dmg

( cd dist && shasum -a 256 Agents-Usage.zip Agents-Usage.dmg > SHA256SUMS )
ls -lh dist

if [[ -n "$TAG" ]]; then
    gh release create "$TAG" dist/Agents-Usage.zip dist/Agents-Usage.dmg dist/SHA256SUMS \
        --title "Agents Usage $TAG" --notes-file "docs/release-notes/$TAG.md"
fi
