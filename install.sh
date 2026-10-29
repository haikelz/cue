#!/bin/sh
# Build Claude Relay, install it to ~/Applications, and add its hooks to ~/.claude/settings.json.
# Safe to run twice: hooks already present are left alone.
set -eu
cd "$(dirname "$0")"

APP="$HOME/Applications/ClaudeRelay.app"
BIN="$APP/Contents/MacOS/ClaudeRelay"
SETTINGS="$HOME/.claude/settings.json"
[ -L "$SETTINGS" ] && { echo "$SETTINGS is a symlink; run this against its target instead." >&2; exit 1; }

swift build -c release
pkill -xf "$BIN" 2>/dev/null || true  # the app only; hook runs carry a "hook" argument
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeRelay "$BIN"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.relay-backup-$(date +%Y%m%d-%H%M%S)"

# Live Claude Code sessions reload settings.json when it changes, so never write it in place:
# temp file in the same folder, validate, keep the mode, rename.
TMP=$(mktemp "$SETTINGS.XXXXXX")
trap 'rm -f "$TMP"' EXIT
jq --arg bin "$BIN" '
  def relay($m): {hooks: [{type: "command", command: $bin, args: ["hook"], timeout: 5}]} + (if $m then {matcher: $m} else {} end);
  def add($ev; $m):
    .hooks[$ev] = ((.hooks[$ev] // []) | if any(.[]; any(.hooks[]?; .command == $bin)) then . else . + [relay($m)] end);
  .hooks //= {}
  | reduce ("SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "Elicitation", "ElicitationResult", "Stop", "StopFailure", "SessionEnd") as $ev (.; add($ev; null))
  | add("Notification"; "idle_prompt")
' "$SETTINGS" > "$TMP"
jq -e '.hooks' "$TMP" > /dev/null
chmod "$(stat -f %Lp "$SETTINGS")" "$TMP"
mv "$TMP" "$SETTINGS"
trap - EXIT

open "$APP"
echo "Installed $APP and its hooks. Claude Code sessions pick up the hooks on their next event."
