#!/bin/sh
# Remove Claude Relay's hooks from ~/.claude/settings.json and delete the app. Other hooks stay.
set -eu

APP="$HOME/Applications/ClaudeRelay.app"
BIN="$APP/Contents/MacOS/ClaudeRelay"
SETTINGS="$HOME/.claude/settings.json"

[ -L "$SETTINGS" ] && { echo "$SETTINGS is a symlink; run this against its target instead." >&2; exit 1; }
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.relay-backup-$(date +%Y%m%d-%H%M%S)"
  TMP=$(mktemp "$SETTINGS.XXXXXX")
  trap 'rm -f "$TMP"' EXIT
  jq --arg bin "$BIN" '
    if .hooks then
      .hooks |= with_entries(
        (.value |= (map(if .hooks then .hooks |= map(select(.command != $bin)) else . end) | map(select(.hooks != []))))
        | select(.value != []))
    else . end
  ' "$SETTINGS" > "$TMP"
  jq -e . "$TMP" > /dev/null
  chmod "$(stat -f %Lp "$SETTINGS")" "$TMP"
  mv "$TMP" "$SETTINGS"
  trap - EXIT
fi

pkill -xf "$BIN" 2>/dev/null || true
rm -rf "$APP"
echo "Removed Claude Relay. Session files stay in ~/.claude/relay until you delete them."
