#!/bin/zsh
# State-machine check for `cue hook`. Runs against a temp CUE_DIR; touches nothing else.
set -u
zmodload zsh/datetime
cd "${0:A:h}/.."
BIN=${BIN:-$PWD/.build/release/cue}
export CUE_DIR=$(mktemp -d)
trap 'rm -rf "$CUE_DIR"' EXIT
fails=0
ID=0a1b2c3d-0000-4000-8000-000000000001

"$BIN" selftest | grep -v "^ok" || fails=$((fails+1))

hook() { print -r -- "$1" | "$BIN" hook; }
ev() { hook "{\"hook_event_name\":\"$1\",\"session_id\":\"${3:-$ID}\",\"cwd\":\"/tmp/demo-project\",\"transcript_path\":\"/tmp/none.jsonl\"${2:+,$2}}"; }
field() { jq -r ".$1" "$CUE_DIR/sessions/${2:-$ID}.json" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then print "ok    $1"; else print "FAIL  $1: got '$2', want '$3'"; fails=$((fails+1)); fi; }

out=$(ev SessionStart '"source":"startup"')
check "SessionStart registers idle" "$(field status)" idle
check "SessionStart prints nothing" "$out" ""
check "cwd recorded" "$(field cwd)" /tmp/demo-project
check "file mode 0600" "$(stat -f %Lp $CUE_DIR/sessions/$ID.json)" 600
check "folder mode 0700" "$(stat -f %Lp $CUE_DIR/sessions)" 700

ev UserPromptSubmit '"prompt":"hi"'
check "UserPromptSubmit -> working" "$(field status)" working
check "UserPromptSubmit stamps last_prompt_at" "$([[ $(field last_prompt_at) != null ]] && print set)" set

before=$(field updated_at); sleep 0.05
ev PostToolUse '"tool_name":"Bash"'
check "PostToolUse while working writes nothing" "$(field updated_at)" "$before"

ev PermissionRequest '"tool_name":"Bash"'
check "PermissionRequest -> needs_you" "$(field status)" needs_you
ev PostToolUse '"tool_name":"Bash"'
check "PostToolUse after approval -> working" "$(field status)" working

ev PermissionRequest '"tool_name":"Bash"'
ev PostToolUseFailure '"tool_name":"Bash"'
check "PostToolUseFailure after denial -> working" "$(field status)" working

ev Elicitation; check "Elicitation -> needs_you" "$(field status)" needs_you
ev ElicitationResult; check "ElicitationResult -> working" "$(field status)" working

long=$(printf 'x%.0s' {1..600})
out=$(ev Stop "\"last_assistant_message\":\"All tests pass.\\nSecond line $long\"")
check "Stop -> idle" "$(field status)" idle
check "last message cut to 500" "$(field last_message | wc -m | tr -d ' ')" 501  # 500 + wc's newline
check "Stop returns an OSC 9 notification" "$(print -r -- $out | jq -r .terminalSequence | cut -c2-)" "]9;demo-project finished: All tests pass."$'\a'

ev Notification '"notification_type":"idle_prompt"'
check "idle_prompt while idle changes nothing" "$(field status)" idle
ev UserPromptSubmit '"prompt":"go"'
ev Notification '"notification_type":"permission_prompt"'
check "other notifications change nothing" "$(field status)" working
ev Notification '"notification_type":"idle_prompt"'
check "idle_prompt while working -> idle" "$(field status)" idle

ev UserPromptSubmit '"agent_id":"sub-1","prompt":"x"'
check "subagent events change nothing" "$(field status)" idle

ev UserPromptSubmit '"prompt":"go"'
out=$(ev StopFailure '"error":"rate_limit"')
check "StopFailure -> idle" "$(field status)" idle
check "StopFailure stores the error" "$(field last_message)" "API error: rate_limit"
check "StopFailure notifies" "$(print -r -- $out | jq -r .terminalSequence | cut -c2-)" "]9;demo-project stopped: API error: rate_limit"$'\a'

ev UserPromptSubmit '"prompt":"go"'
ev SessionStart '"source":"resume"'
check "resume SessionStart -> idle" "$(field status)" idle
ev UserPromptSubmit '"prompt":"go"'
ev SessionStart '"source":"compact"'
check "compact SessionStart keeps status" "$(field status)" working
C=0a1b2c3d-0000-4000-8000-000000000002
ev SessionStart '"source":"compact"' $C
check "compact SessionStart on a new file -> working" "$(field status $C)" working

ev SessionEnd '"reason":"prompt_input_exit"'
check "SessionEnd deletes the file" "$([[ -e $CUE_DIR/sessions/$ID.json ]] && print exists || print gone)" gone

out=$(print -r -- 'not json' | "$BIN" hook); code=$?
check "malformed input exits 0" "$code" 0
check "malformed input prints nothing" "$out" ""
check "malformed input is logged" "$(wc -l < $CUE_DIR/hook.log | tr -d " ")" 1

hook '{"hook_event_name":"Stop","session_id":"../escape","cwd":"/tmp"}'
check "path-like session id is rejected" "$(ls $CUE_DIR/sessions | grep -c escape)" 0

P=0a1b2c3d-0000-4000-8000-000000000003
for i in {1..10}; do ev PostToolUse '"tool_name":"Read"' $P & done; wait
check "10 parallel hooks leave valid JSON" "$(jq -r .status $CUE_DIR/sessions/$P.json)" working
check "no temp files left" "$(ls -a $CUE_DIR/sessions | grep -c tmp)" 0

start=$EPOCHREALTIME
for i in {1..100}; do ev PostToolUse '"tool_name":"Read"' $P; done
avg=$(( (EPOCHREALTIME - start) * 10 ))  # ms per run
printf "      hook average: %.1f ms\n" $avg
check "hook averages under 50 ms" "$(( avg < 50 ))" 1

print; (( fails == 0 )) && print "all checks passed" || print "$fails check(s) failed"
exit $(( fails > 0 ))
