#!/bin/bash
# Installs the latest Agents Usage release into ~/Applications and starts it.
#
#   curl -fsSL https://raw.githubusercontent.com/igor-batrakov/agents-usage/main/install.sh | bash
#
# Files downloaded with curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" dialog (the app is ad-hoc signed, not notarized).
# AGENTS_USAGE_VERSION=v0.3.0 installs a specific release instead of the latest one.
set -euo pipefail

REPO="igor-batrakov/agents-usage"
APP="Agents Usage.app"
DEST="${AGENTS_USAGE_DIR:-$HOME/Applications}"   # AGENTS_USAGE_DIR: another install folder
VERSION="${AGENTS_USAGE_VERSION:-latest}"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Agents Usage runs on macOS only."
os=$(sw_vers -productVersion)
[ "${os%%.*}" -ge 15 ] || fail "Agents Usage needs macOS 15 or later, this Mac has $os."

if [ -z "${AGENTS_USAGE_URL:-}" ] && [ "$VERSION" = latest ]; then
    # Pin the tag first: the archive and SHA256SUMS then come from one release, even if a newer one
    # is published in between. GitHub redirects releases/latest to releases/tag/<tag>.
    page=$(curl -fsSL --connect-timeout 15 --max-time 60 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest") || fail "could not find the latest release"
    VERSION="${page##*/}"
    [[ "$VERSION" =~ ^v[0-9]+(\.[0-9]+){0,3}$ ]] || fail "unexpected latest release: $page"
fi
BASE="https://github.com/$REPO/releases/download/$VERSION"
URL="${AGENTS_USAGE_URL:-$BASE/Agents-Usage.zip}"   # AGENTS_USAGE_URL: another archive, e.g. file:// for testing

work=$(mktemp -d)
new=""
locked=""
trap 'rm -rf "$work"; if [ -n "$new" ]; then rm -rf "$new"; fi; if [ -n "$locked" ]; then rm -f "$lock"; fi' EXIT

echo "Downloading Agents Usage ($VERSION)…"
# A stalled download gives up (under 1 KB/s for 30 s) instead of hanging: the in-app updater waits for this script.
curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 "$URL" -o "$work/Agents-Usage.zip" \
    || fail "download failed: $URL"
# Every release carries SHA256SUMS: a truncated or damaged archive stops here. An archive of your own
# (AGENTS_USAGE_URL) has none to check against.
if [ -z "${AGENTS_USAGE_URL:-}" ]; then
    curl -fsSL --connect-timeout 15 --max-time 60 "$BASE/SHA256SUMS" -o "$work/SHA256SUMS" \
        || fail "download failed: $BASE/SHA256SUMS"
    ( cd "$work" && grep ' Agents-Usage.zip$' SHA256SUMS | shasum -a 256 -c - >/dev/null ) \
        || fail "the archive does not match SHA256SUMS"
fi
ditto -x -k "$work/Agents-Usage.zip" "$work"
[ -d "$work/$APP" ] || fail "the archive has no $APP"

mkdir -p "$DEST"
# One install at a time replaces the app: a second one waits, otherwise its `mv` could land inside the bundle
# the first one just put there. shlock takes over a lock whose process is gone. The lock is a courtesy, never a
# reason not to install: with no lock file made (no hard links on the volume, no write access) it goes on at
# once, and after a minute it goes on anyway (the lock's PID may belong to another process by now).
lock="$DEST/.agents-usage-install.lock"
for _ in $(seq 120); do
    if shlock -f "$lock" -p $$ 2>/dev/null; then locked=1; break; fi
    [ -e "$lock" ] || break
    sleep 0.5
done

# A running copy keeps the old binary; quit it before replacing. -a: when the app's updater runs this
# script, the app is its ancestor, and pkill skips ancestors by default.
pkill -a -x UsageWidget 2>/dev/null && sleep 1 || true
# Copy next to the old app first (same volume): a failed copy leaves the installed one in place.
new=$(mktemp -d "$DEST/.agents-usage-install.XXXXXX")
ditto "$work/$APP" "$new/$APP" || fail "could not copy the app to $DEST"
rm -rf "${DEST:?}/$APP"
mv "$new/$APP" "$DEST/$APP"
# curl sets no quarantine flag; clear it anyway in case the zip arrived through a browser.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

open "$DEST/$APP"
echo "Installed: $DEST/$APP"
echo "Look for the bars icon in the menu bar. The very first launch can take up to a minute while macOS checks the app."
