#!/bin/sh
# Build Cue, install it to ~/Applications, and wire it into Claude Code, Codex and Amp.
# Safe to run twice: hooks already present are left alone. Migrates a Claude Relay install.
# In a release download, which holds a built Cue.app and no sources, it installs that app instead.
set -eu
cd "$(dirname "$0")"

# bundle <path.app>: build Cue and assemble its app bundle there.
bundle() {
  swift build -c release
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp .build/release/cue "$1/Contents/MacOS/cue"
  cp Info.plist "$1/Contents/Info.plist"
  cp assets/AppIcon.icns assets/menubar.tiff assets/agent-*.png "$1/Contents/Resources/"
  codesign --force --sign - "$1"
}

# ./install.sh --bundle <path.app> only builds the bundle, for the release workflow to zip.
if [ "${1:-}" = --bundle ]; then bundle "${2:?--bundle takes the path of the app to build}"; exit; fi

# macOS 15 ships jq; macOS 14 doesn't, and without it the settings below can't be written.
command -v jq > /dev/null || { echo "Cue's install needs jq: brew install jq" >&2; exit 1; }

APP="$HOME/Applications/Cue.app"
BIN="$APP/Contents/MacOS/cue"
OLD_APP="$HOME/Applications/ClaudeRelay.app"
OLD_BIN="$OLD_APP/Contents/MacOS/ClaudeRelay"
CLAUDE="$HOME/.claude/settings.json"
CODEX="$HOME/.codex/hooks.json"
CUE_DIR="$HOME/.cue"

for f in "$CLAUDE" "$CODEX"; do
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

# Build the bundle beside the old one and swap them, so hooks never find the binary missing.
rm -rf "$APP.new" "$APP.old"
if [ -f Package.swift ]; then
  bundle "$APP.new"
else
  # hw.optional.arm64, not uname -m, which says x86_64 in a Rosetta shell on Apple silicon.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || { echo "This Cue.app is built for Apple silicon. On this Mac, build Cue from its sources." >&2; exit 1; }
  cp -R Cue.app "$APP.new"
  # A downloaded app carries the quarantine flag, and Gatekeeper would stop the unsigned app and its hooks.
  xattr -dr com.apple.quarantine "$APP.new"
fi
pkill -xf "$BIN" 2>/dev/null || true  # the app only; hook runs carry arguments
if [ -d "$APP" ]; then mv "$APP" "$APP.old"; fi
mv "$APP.new" "$APP"
rm -rf "$APP.old"

mkdir -p "$CUE_DIR"
chmod 700 "$CUE_DIR"
# The absolute codex and tmux paths and this shell's PATH: `codex queue` may start Codex's daemon,
# which inherits the PATH Cue gives it, and your Codex hooks need theirs (node, for one).
jq -n --arg codex "$(command -v codex || true)" --arg tmux "$(command -v tmux || true)" --arg path "$PATH" \
  '{codex: (if $codex == "" then null else $codex end), tmux: (if $tmux == "" then null else $tmux end), path: $path}' > "$CUE_DIR/config.json"
chmod 600 "$CUE_DIR/config.json"

# Claude Code: Claude Relay's hooks out and Cue's in, in one write, before the old app goes away.
if [ -d "$HOME/.claude" ]; then
rewrite "$CLAUDE" '
  def cue($m): {hooks: [{type: "command", command: $bin, args: ["hook", "claude"], timeout: 5}]} + (if $m then {matcher: $m} else {} end);
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

# Codex: append to the end of each list. Codex records hook trust by position, so appending leaves
# the trust of your other hooks alone. Codex handlers take no args field, hence one command string,
# with the path single-quoted for sh (a quote inside the path becomes '\''). Codex caps some hooks at 3 s.
CODEX_CMD="'$(printf %s "$BIN" | sed "s/'/'\\\\''/g")' hook codex"
if [ -d "$HOME/.codex" ]; then
  rewrite "$CODEX" '
    def mine: {type: "command", command: $cmd, timeout: 3};
    def add($ev):
      .hooks[$ev] = ((.hooks[$ev] // []) | if any(.[]; any(.hooks[]?; .command == $cmd)) then . else . + [{hooks: [mine]}] end);
    .hooks //= {}
    | .hooks |= map_values(map(if .hooks then .hooks |= map(if .command == $cmd then mine else . end) else . end))
    | reduce ("SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd") as $ev (.; add($ev))
  ' --arg cmd "$CODEX_CMD"
  echo "Codex: open codex, run /hooks, and trust Cue's hooks. Codex skips hooks you haven't trusted."
  echo "Codex: Cue posts its own notifications; leave notifications under [tui] in ~/.codex/config.toml off to avoid doubles."
fi

if command -v amp > /dev/null; then
  mkdir -p "$HOME/.config/amp/plugins"
  cp plugins/amp/cue.ts "$HOME/.config/amp/plugins/cue.ts"
  echo "Amp: plugin installed. Open Amp windows load it after 'plugins: reload' or a restart."
fi

[ -n "${CUE_NO_OPEN:-}" ] || open "$APP"
echo "Installed $APP. Sessions appear after their next prompt or reply."
