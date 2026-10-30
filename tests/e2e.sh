#!/bin/zsh
# End-to-end: two real Claude Code sessions in new iTerm2 windows, prompts sent through
# `cue send`. Costs a few small model calls. Needs iTerm2, claude and jq.
set -u
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
session_of() { jq -r --arg s "$1" 'select(.iterm_session_id == $s) | .session_id' $SESSIONS/*.json 2>/dev/null | head -1; }

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
jq -n --arg b "$BIN" '{hooks: (([ "SessionStart","UserPromptSubmit","PostToolUse","PostToolUseFailure","PermissionRequest","Elicitation","ElicitationResult","Stop","StopFailure","SessionEnd" ] | map({key: ., value: [{hooks: [{type: "command", command: $b, args: ["hook"], timeout: 5}]}]}) | from_entries) + {Notification: [{matcher: "idle_prompt", hooks: [{type: "command", command: $b, args: ["hook"], timeout: 5}]}]})}' > $W/settings.json

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
print; (( fails == 0 )) && print "all checks passed" || print "$fails check(s) failed"
exit $(( fails > 0 ))
