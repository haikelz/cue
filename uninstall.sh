#!/bin/sh
# Remove Cue's hooks from Claude Code and Codex, its Amp plugin, and the app. Other hooks stay.
set -eu

APP="$HOME/Applications/Cue.app"
BIN="$APP/Contents/MacOS/cue"
CLAUDE="$HOME/.claude/settings.json"
CODEX="$HOME/.codex/hooks.json"

for f in "$CLAUDE" "$CODEX"; do
  if [ -L "$f" ]; then echo "$f is a symlink; run this against its target instead." >&2; exit 1; fi
done

# drop <file> <command>: remove every handler running <command>, keep the rest of each group.
drop() {
  [ -f "$1" ] || return 0
  cp "$1" "$1.cue-backup-$(date +%Y%m%d-%H%M%S)"
  ls -t "$1".cue-backup-* | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done  # keep the last 3
  tmp=$(mktemp "$1.XXXXXX")
  if jq --arg cmd "$2" '
      if .hooks then
        .hooks |= with_entries(
          (.value |= (map(if .hooks then .hooks |= map(select(.command != $cmd)) else . end) | map(select(.hooks != []))))
          | select(.value != []))
      else . end' "$1" > "$tmp" && jq -e . "$tmp" > /dev/null; then
    chmod "$(stat -f %Lp "$1")" "$tmp"
    mv "$tmp" "$1"
  else
    rm -f "$tmp"
    echo "Couldn't update $1; it is unchanged." >&2
    exit 1
  fi
}

drop "$CLAUDE" "$BIN"
drop "$CODEX" "'$(printf %s "$BIN" | sed "s/'/'\\\\''/g")' hook codex"
rm -f "$HOME/.config/amp/plugins/cue.ts"
pkill -xf "$BIN" 2>/dev/null || true
rm -rf "$APP"
echo "Removed Cue. Codex may ask you to re-review hooks that were listed after Cue's in /hooks."
echo "Session files stay in ~/.cue until you delete them."
