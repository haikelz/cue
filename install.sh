#!/bin/sh
# Build Cue, install it to ~/Applications, and add its hooks to ~/.claude/settings.json.
# Safe to run twice: hooks already present are left alone. Migrates a Claude Relay install.
set -eu
cd "$(dirname "$0")"

APP="$HOME/Applications/Cue.app"
BIN="$APP/Contents/MacOS/cue"
OLD_APP="$HOME/Applications/ClaudeRelay.app"
OLD_BIN="$OLD_APP/Contents/MacOS/ClaudeRelay"
CLAUDE="$HOME/.claude/settings.json"
CUE_DIR="$HOME/.cue"

for f in "$CLAUDE"; do
  if [ -L "$f" ]; then echo "$f is a symlink; run this against its target instead." >&2; exit 1; fi
done

# rewrite <file> <jq filter> [jq args...]: back up, write a temp file in the same folder, validate,
# keep the mode, rename. Live sessions reload these files on change, so they never see half of one.
rewrite() {
  file=$1; filter=$2; shift 2
  [ -f "$file" ] || echo '{}' > "$file"
  cp "$file" "$file.cue-backup-$(date +%Y%m%d-%H%M%S)"
  ls -t "$file".cue-backup-* | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done  # keep the last 3
  tmp=$(mktemp "$file.XXXXXX")
  if jq "$@" "$filter" "$file" > "$tmp" && jq -e . "$tmp" > /dev/null; then
    chmod "$(stat -f %Lp "$file")" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    echo "Couldn't update $file; it is unchanged." >&2
    exit 1
  fi
}

swift build -c release
# Build the bundle beside the old one and swap them, so hooks never find the binary missing.
rm -rf "$APP.new" "$APP.old"
mkdir -p "$APP.new/Contents/MacOS"
cp .build/release/cue "$APP.new/Contents/MacOS/cue"
cp Info.plist "$APP.new/Contents/Info.plist"
codesign --force --sign - "$APP.new"
pkill -xf "$BIN" 2>/dev/null || true  # the app only; hook runs carry arguments
if [ -d "$APP" ]; then mv "$APP" "$APP.old"; fi
mv "$APP.new" "$APP"
rm -rf "$APP.old"

mkdir -p "$CUE_DIR"
chmod 700 "$CUE_DIR"
# Claude Code: Claude Relay's hooks out and Cue's in, in one write, before the old app goes away.
if [ -d "$HOME/.claude" ]; then
rewrite "$CLAUDE" '
  def cue($m): {hooks: [{type: "command", command: $bin, args: ["hook"], timeout: 5}]} + (if $m then {matcher: $m} else {} end);
  def add($ev; $m):
    .hooks[$ev] = ((.hooks[$ev] // []) | if any(.[]; any(.hooks[]?; .command == $bin)) then . else . + [cue($m)] end);
  .hooks //= {}
  | .hooks |= with_entries(
      (.value |= (map(if .hooks then .hooks |= map(select(.command != $old)) else . end) | map(select(.hooks != []))))
      | select(.value != []))
  | reduce ("SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "Elicitation", "ElicitationResult", "Stop", "StopFailure", "SessionEnd") as $ev (.; add($ev; null))
  | add("Notification"; "idle_prompt")
' --arg bin "$BIN" --arg old "$OLD_BIN"
fi
pkill -xf "$OLD_BIN" 2>/dev/null || true
rm -rf "$OLD_APP" "$HOME/.claude/relay"

[ -n "${CUE_NO_OPEN:-}" ] || open "$APP"
echo "Installed $APP. Sessions appear after their next prompt or reply."
