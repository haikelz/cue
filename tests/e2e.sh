#!/bin/zsh
# End-to-end: real Claude Code, Amp and Codex sessions in new iTerm2 windows, and Claude Code in a
# detached tmux session, prompts sent through `cue send`. Costs a few small model calls. Needs iTerm2,
# claude and jq; the tmux part needs tmux; Amp and Codex parts run when ./install.sh has wired them in
# (Codex also needs Cue's hooks trusted in /hooks).
set -u
setopt null_glob
zmodload zsh/datetime
cd "${0:A:h}/.."
BIN=$PWD/.build/release/cue
T=$PWD/tests/iterm.sh
W=$PWD/.spike/e2e
SESSIONS=$HOME/.cue/sessions
fails=0

check() { if [[ "$2" == "$3" ]]; then print "ok    $1"; else print "FAIL  $1: got '$2', want '$3'"; fails=$((fails+1)); fi; }
field() { jq -r ".$2" "$SESSIONS/$1.json" 2>/dev/null; }
wait_for() {  # wait_for <seconds> <zsh condition>
  for i in {1..$(( $1 * 2 ))}; do eval "$2" && return 0; sleep 0.5; done; return 1
}
session_of() { jq -r --arg s "$1" --arg a "${2:-claude}" 'select(.iterm_session_id == $s and .agent == $a) | .session_id' $SESSIONS/*.json 2>/dev/null | head -1; }

# Start claude in a fresh window, clearing first-run prompts (folder trust, MCP servers).
start() {  # start <dir> <extra flags> -> prints "<iterm id> <session id>"
  local sid=$($T new) id=""
  sleep 1
  $T type $sid "cd $1 && claude --settings $W/settings.json $2" >/dev/null; $T key $sid 13 >/dev/null
  for i in {1..60}; do
    local screen=$($T screen $sid)
    if [[ $screen == *"Yes, I trust this folder"* ]]; then $T key $sid 27 91 66 >/dev/null; sleep 0.3; $T key $sid 13 >/dev/null
    elif [[ $screen == *"new MCP servers found"* ]]; then $T key $sid 27 >/dev/null
    fi
    id=$(session_of $sid); [[ -n $id ]] && break
    sleep 0.5
  done
  print "$sid $id"
}

rm -rf $W && mkdir -p $W/one $W/two
jq -n --arg b "$BIN" '{hooks: (([ "SessionStart","UserPromptSubmit","PostToolUse","PostToolUseFailure","PermissionRequest","Elicitation","ElicitationResult","Stop","StopFailure","SessionEnd" ] | map({key: ., value: [{hooks: [{type: "command", command: $b, args: ["hook", "claude"], timeout: 5}]}]}) | from_entries) + {Notification: [{matcher: "idle_prompt", hooks: [{type: "command", command: $b, args: ["hook", "claude"], timeout: 5}]}]})}' > $W/settings.json

read sidA A <<< "$(start $W/one '')"
read sidB B <<< "$(start $W/two '--permission-mode default')"
check "session one registered" "$([[ -n $A ]] && print yes)" yes
check "session two registered" "$([[ -n $B ]] && print yes)" yes
[[ -n $A && -n $B ]] || { print "cannot continue"; exit 1; }
sleep 2

# 1. A one-line prompt reaches its own session and nobody else.
before_b=$(field $B last_prompt_at)
check "send returns confirmed" "$($BIN send $A 'Reply with the single word PONG and nothing else')" confirmed
wait_for 60 '[[ $(field $A status) == idle ]]'
check "Claude answered" "$(field $A last_message)" PONG
check "other session untouched" "$(field $B last_prompt_at)" "$before_b"

# 1b. A half-typed draft is cleared first (Ctrl+Y brings it back), so it never merges into the prompt.
$T type $sidA 'half typed draft' > /dev/null; sleep 0.5
check "send over a draft confirmed" "$($BIN send $A 'Reply with the single word CLEAN and nothing else')" confirmed
wait_for 60 '[[ $(field $A status) == idle ]]'
prompt=$(grep '"type":"user"' "$(field $A transcript_path)" | tail -1 | jq -r '.message.content | if type == "string" then . else .[0].text end')
check "draft did not merge into the prompt" "$prompt" "Reply with the single word CLEAN and nothing else"

# 2. A 5-line prompt with a 400-character line arrives as typed text, not a collapsed paste.
pad=$(printf 'padding words %.0s' {1..28})
$BIN send $A "Line one.
Line two: $pad
Line three.
Line four.
Line five: reply with the number of lines in this message and nothing else." > /dev/null
wait_for 60 '[[ $(field $A status) == idle ]]'
check "five lines counted" "$(field $A last_message)" 5
prompt=$(grep '"type":"user"' "$(field $A transcript_path)" | tail -1 | jq -r '.message.content | if type == "string" then . else .[0].text end')
check "prompt is not a paste" "$([[ $prompt == *pasted_content* ]] && print paste || print typed)" typed

# 3. Permission dialog: status flips, and the gate refuses even when the file says idle.
$BIN send $B 'Run this exact bash command: touch e2e-permission.txt' > /dev/null
wait_for 60 '[[ $(field $B status) == needs_you ]]'
check "permission dialog -> needs_you" "$(field $B status)" needs_you
check "send refused during dialog" "$($BIN send $B 'nope' 2>&1)" "Claude needs you in the terminal"
# PermissionRequest fires before Claude Code draws the dialog; wait for it before faking a stale "idle".
wait_for 15 '[[ $($T screen $sidB) == *"Do you want to proceed"* ]]'
f=$SESSIONS/$B.json; jq '.status = "idle"' $f > $f.t && mv $f.t $f
check "input-box check refuses a forced idle" "$($BIN send $B 'nope' 2>&1)" "Claude's input box isn't on screen (dialog, editor or menu open)"
$T key $sidB 27 > /dev/null

# 4. Ctrl+G editor and Ctrl+Z suspension.
$T key $sidA 7 > /dev/null; sleep 2
check "send refused with editor open" "$($BIN send $A 'nope' 2>&1)" "Claude's input box isn't on screen (dialog, editor or menu open)"
$T key $sidA 27 > /dev/null; $T type $sidA ':q!' > /dev/null; $T key $sidA 13 > /dev/null; sleep 1.5
$T key $sidA 26 > /dev/null; sleep 1.5
check "send refused while suspended" "$($BIN send $A 'nope' 2>&1)" "Claude isn't in the foreground (suspended?)"
$T type $sidA 'fg' > /dev/null; $T key $sidA 13 > /dev/null; sleep 2

# 5. Nothing typed by refused sends reached either tab.
check "no stray text in tab one" "$($T screen $sidA | grep -c nope)" 0
check "no stray text in tab two" "$($T screen $sidB | grep -c nope)" 0

# 6. A closed tab refuses instead of typing somewhere else.
$T close $sidA > /dev/null; sleep 2
out=$($BIN send $A 'nope' 2>&1)
check "send to closed tab refused" "$([[ $out == "Claude process is gone" || $out == "iTerm2 tab is closed" ]] && print refused)" refused

$T close $sidB > /dev/null
rm -f $SESSIONS/$A.json $SESSIONS/$B.json

# 6b. tmux: Claude Code in a detached tmux session, the path for Ghostty, Kitty, WezTerm and Terminal.app.
if command -v tmux > /dev/null; then
  mkdir -p $W/tmux
  tx() { tmux -S $W/tmux.sock "$@"; }
  tx new-session -d -s cue-e2e -x 120 -y 40 -c $W/tmux
  pane=$(tx display-message -p -t cue-e2e '#{pane_id}')
  tx send-keys -t $pane "claude --settings $W/settings.json" Enter
  pane_session() { jq -r --arg p "$pane" --arg s "$W/tmux.sock" 'select(.tmux_pane == $p and .tmux_socket == $s) | .session_id' $SESSIONS/*.json 2>/dev/null | head -1; }
  P=""
  for i in {1..60}; do
    screen=$(tx capture-pane -p -t $pane)
    if [[ $screen == *"Yes, I trust this folder"* ]]; then tx send-keys -t $pane Down; sleep 0.3; tx send-keys -t $pane Enter
    elif [[ $screen == *"new MCP servers found"* ]]; then tx send-keys -t $pane Escape
    fi
    P=$(pane_session); [[ -n $P ]] && break
    sleep 0.5
  done
  check "tmux session registered" "$([[ -n $P ]] && print yes)" yes
  if [[ -n $P ]]; then
    sleep 2
    check "tmux row has no iTerm2 tab" "$(field $P iterm_session_id)" null
    check "tmux send confirmed" "$($BIN send $P 'Reply with the single word TMUXED and nothing else')" confirmed
    wait_for 60 '[[ $(field $P status) == idle ]]'
    check "Claude in tmux answered" "$(field $P last_message)" TMUXED

    # Copy mode reads keys as tmux commands; synchronized panes copy them to every pane in the window.
    tx copy-mode -t $pane
    check "tmux send refused in copy mode" "$($BIN send $P 'nope' 2>&1)" "tmux pane is in copy mode; press q in it"
    tx send-keys -X -t $pane cancel
    tx set-window-option -t $pane synchronize-panes on
    check "tmux send refused with synchronized panes" "$($BIN send $P 'nope' 2>&1)" "tmux panes are synchronized; turn synchronize-panes off"
    tx set-window-option -t $pane synchronize-panes off

    # A draft is cleared, a line ending in ";" survives tmux, and the line break stays a line break.
    tx send-keys -t $pane -l 'half typed draft'; sleep 0.5
    text="First line ends with a semicolon;
Second line: reply with the number of lines in this message and nothing else."
    check "tmux multi-line send confirmed" "$($BIN send $P $text)" confirmed
    wait_for 60 '[[ $(field $P status) == idle ]]'
    check "two lines counted" "$(field $P last_message)" 2
    prompt=$(grep '"type":"user"' "$(field $P transcript_path)" | tail -1 | jq -r '.message.content | if type == "string" then . else .[0].text end')
    check "tmux prompt arrived exactly" "$prompt" "$text"

    tx send-keys -t $pane C-z; sleep 1.5
    check "tmux send refused while suspended" "$($BIN send $P 'nope' 2>&1)" "Claude isn't in the foreground (suspended?)"
    tx send-keys -t $pane fg Enter; sleep 2
    check "no stray text in the pane" "$(tx capture-pane -p -t $pane | grep -c nope)" 0

    # Open: a detached session has no terminal to show; with its client in an iTerm2 tab, Open selects that tab.
    check "Open with no tmux client says so" "$($BIN open $P 2>&1)" "No terminal shows this tmux session; run tmux attach"
    sidT=$($T new); sleep 1; $T type $sidT "tmux -S $W/tmux.sock attach -t cue-e2e" > /dev/null; $T key $sidT 13 > /dev/null; sleep 2
    client=$(tx list-clients -F '#{client_tty}' | head -1)
    sidF=$($T new); sleep 1  # another window in front
    opened=$($BIN open $P 2>&1)
    check "Open selects the iTerm2 tab of the tmux client" "$opened $(osascript -e 'tell application "iTerm2" to tty of current session of current window')" "opened $client"
    $T close $sidF > /dev/null; $T close $sidT > /dev/null; sleep 1

    # The row may outlive its pane for a moment; put it back as if the app hadn't caught up yet.
    # A running Cue app may delete it again first, which is a refusal too.
    cp $SESSIONS/$P.json $W/tmux-row.json; tx kill-server; sleep 1; cp $W/tmux-row.json $SESSIONS/$P.json
    out=$($BIN send $P 'nope' 2>&1)
    check "send to a closed pane refused" "$([[ $out == "Claude process is gone" || $out == "tmux pane is closed" || $out == "Session is gone" ]] && print refused)" refused
    rm -f $SESSIONS/$P.json
  fi
  tx kill-server 2> /dev/null
else
  print "skip  tmux: install tmux"
fi

# 7. Amp: the plugin lists the thread you have open and delivers through the inbox.
if command -v amp > /dev/null && cmp -s plugins/amp/cue.ts ~/.config/amp/plugins/cue.ts; then
  mkdir -p $W/amp
  sidM=$($T new); sleep 1
  $T type $sidM "cd $W/amp && amp" > /dev/null; $T key $sidM 13 > /dev/null; sleep 10
  $T type $sidM 'Reply with the single word READY and nothing else' > /dev/null; sleep 0.2; $T key $sidM 13 > /dev/null
  wait_for 60 '[[ -n $(session_of $sidM amp) ]]'
  M=$(session_of $sidM amp)
  check "Amp thread registered" "$([[ -n $M ]] && print yes)" yes
  if [[ -n $M ]]; then
    wait_for 60 '[[ $(field $M last_message) == READY ]]'
    check "Amp reply stored" "$(field $M last_message)" READY
    check "Amp send delivered" "$($BIN send $M 'Reply with the single word AMPED and nothing else')" delivered
    wait_for 60 '[[ $(field $M last_message) == AMPED ]]'
    check "Amp answered the sent prompt" "$(field $M last_message)" AMPED
    $BIN send $M 'Write the numbers 1 to 60, one per line, and nothing else' > /dev/null
    wait_for 30 '[[ $(field $M status) == working ]]'
    check "Amp send while working delivered" "$($BIN send $M 'Then reply with the single word QUEUED and nothing else')" delivered
    wait_for 120 '[[ $(field $M last_message) == QUEUED ]]'
    check "the queued prompt ran" "$(field $M last_message)" QUEUED
    $T key $sidM 3 > /dev/null; sleep 0.5; $T key $sidM 3 > /dev/null; sleep 1; $T close $sidM > /dev/null
    wait_for 40 '(( EPOCHREALTIME - $(field $M heartbeat) > 30 ))' 2> /dev/null
    check "closed Amp window stops the heartbeat" "$(( EPOCHREALTIME - $(field $M heartbeat 2>/dev/null || print 0) > 30 ))" 1
  else
    $T close $sidM > /dev/null
  fi
else
  print "skip  Amp: install amp and run ./install.sh"
fi

# 8. Codex: hooks list the session, `codex queue` delivers.
if grep -q "Cue.app/Contents/MacOS/cue' hook codex" ~/.codex/hooks.json 2> /dev/null; then
  mkdir -p $W/codex
  # Rows left by earlier runs in this folder would pass for the new session.
  for f in $SESSIONS/*.json; do [[ $(jq -r '.agent + .cwd' $f) == "codex$W/codex" ]] && rm -f $f; done
  sidC=$($T new); sleep 1
  $T type $sidC "cd $W/codex && codex" > /dev/null; $T key $sidC 13 > /dev/null
  trusted=yes
  for i in {1..40}; do
    screen=$($T screen $sidC)
    if [[ $screen == *"Update available"*"enter continue"* ]]; then $T key $sidC 27 > /dev/null  # the dialog, not the banner left after it
    elif [[ $screen == *"Trust this folder"* ]]; then $T key $sidC 13 > /dev/null
    elif [[ $screen == *"Hooks need review"* || $screen == *"/hooks"* ]]; then trusted=no; break
    elif [[ $screen == *"Ask Codex to do anything"* ]]; then
      sleep 3  # Codex draws its main screen first and the hooks review dialog a moment later
      [[ $($T screen $sidC) == *"Hooks need review"* ]] && trusted=no
      break
    fi
    sleep 0.5
  done
  if [[ $trusted == yes ]]; then
    $T type $sidC 'Reply with the single word READY and nothing else' > /dev/null; sleep 0.2; $T key $sidC 13 > /dev/null
    codex_row() { jq -r --arg d "$W/codex" 'select(.agent == "codex" and .cwd == $d) | .session_id' $SESSIONS/*.json 2>/dev/null | head -1; }
    wait_for 60 '[[ -n $(codex_row) ]]'
    C=$(codex_row)
    check "Codex session registered" "$([[ -n $C ]] && print yes)" yes
    if [[ -n $C ]]; then
      wait_for 60 '[[ $(field $C last_message) == READY ]]'
      check "Codex reply stored" "$(field $C last_message)" READY
      check "Codex send accepted" "$($BIN send $C 'Reply with the single word CODEXED and nothing else')" sent
      wait_for 60 '[[ $(field $C last_message) == CODEXED ]]'
      check "Codex answered the sent prompt" "$(field $C last_message)" CODEXED
      $BIN send $C 'Write the numbers 1 to 60, one per line, and nothing else' > /dev/null
      wait_for 30 '[[ $(field $C status) == working ]]'
      check "Codex send while working is queued" "$($BIN send $C 'Then reply with the single word QUEUED and nothing else')" queued
      wait_for 120 '[[ $(field $C last_message) == QUEUED ]]'
      check "the queued prompt ran" "$(field $C last_message)" QUEUED
    fi
  else
    print "skip  Codex: trust Cue's hooks in Codex's /hooks first"
  fi
  $T key $sidC 3 > /dev/null; sleep 0.5; $T key $sidC 3 > /dev/null; sleep 1; $T close $sidC > /dev/null
  [[ -n ${C:-} ]] && rm -f $SESSIONS/$C.json  # Codex reports the end only after 30 unopened minutes
else
  print "skip  Codex: run ./install.sh"
fi
print; (( fails == 0 )) && print "all checks passed" || print "$fails check(s) failed"
exit $(( fails > 0 ))
