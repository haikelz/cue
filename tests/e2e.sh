#!/bin/zsh
# End-to-end: real Claude Code, Amp and Codex sessions in new iTerm2 windows, prompts sent through
# `cue send`. Costs a few small model calls. Needs iTerm2, claude and jq; Amp and Codex parts run
# when ./install.sh has wired them in (Codex also needs Cue's hooks trusted in /hooks).
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
  sidC=$($T new); sleep 1
  $T type $sidC "cd $W/codex && codex" > /dev/null; $T key $sidC 13 > /dev/null
  trusted=yes
  for i in {1..40}; do
    screen=$($T screen $sidC)
    if [[ $screen == *"Update available"* ]]; then $T key $sidC 27 > /dev/null
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
else
  print "skip  Codex: run ./install.sh"
fi
print; (( fails == 0 )) && print "all checks passed" || print "$fails check(s) failed"
exit $(( fails > 0 ))
