#!/bin/zsh
# State-machine and delivery checks for `cue`. Runs against a temp CUE_DIR; touches nothing else.
set -u
zmodload zsh/datetime
cd "${0:A:h}/.."
BIN=${BIN:-$PWD/.build/release/cue}
export CUE_DIR=$(mktemp -d)
trap 'rm -rf "$CUE_DIR"' EXIT
fails=0
ID=0a1b2c3d-0000-4000-8000-000000000001

# CueCore's unit tests (swift-testing), then the binary's behavior below.
if out=$(swift test 2>&1); then print "ok    swift test: ${${(f)out}[-1]}"; else print -r -- "$out" | grep -E "✘|error" | head -20; fails=$((fails+1)); fi

hook() { print -r -- "$1" | "$BIN" hook claude; }
ev() { hook "{\"hook_event_name\":\"$1\",\"session_id\":\"${3:-$ID}\",\"cwd\":\"/tmp/demo-project\",\"transcript_path\":\"/tmp/none.jsonl\"${2:+,$2}}"; }
field() { jq -r ".$1" "$CUE_DIR/sessions/${2:-$ID}.json" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then print "ok    $1"; else print "FAIL  $1: got '$2', want '$3'"; fails=$((fails+1)); fi; }

check "an unknown command word prints usage instead of starting the app" "$("$BIN" bogus 2>/dev/null; print $?)" 64

out=$(ev SessionStart '"source":"startup"')
check "SessionStart registers idle" "$(field status)" idle
check "SessionStart prints nothing" "$out" ""
check "cwd recorded" "$(field cwd)" /tmp/demo-project
check "file mode 0600" "$(stat -f %Lp $CUE_DIR/sessions/$ID.json)" 600
check "folder mode 0700" "$(stat -f %Lp $CUE_DIR/sessions)" 700

# Inside tmux the pane is the target, and ITERM_SESSION_ID is a stale copy from the tmux server.
P=0a1b2c3d-0000-4000-8000-0000000000a1
(export TMUX=/private/tmp/tmux-501/default,4242,0 TMUX_PANE=%7 ITERM_SESSION_ID=w0t0p0:STALE; ev SessionStart '"source":"startup"' $P)
check "tmux socket recorded" "$(field tmux_socket $P)" /private/tmp/tmux-501/default
check "tmux pane recorded" "$(field tmux_pane $P)" %7
check "no iTerm2 tab inside tmux" "$(field iterm_session_id $P)" null
(export TMUX=/private/tmp/tmux-501/default,4242,0 TMUX_PANE='%7;kill' ; ev Stop '"last_assistant_message":"x"' $P >/dev/null)
check "odd tmux pane rejected" "$(field tmux_pane $P)" null
(export ITERM_SESSION_ID=w0t1p0:TAB; unset TMUX TMUX_PANE; ev Stop '"last_assistant_message":"x"' $P >/dev/null)
check "leaving tmux clears the pane" "$(field tmux_pane $P),$(field iterm_session_id $P)" "null,TAB"

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

long=$(printf 'x%.0s' {1..4100})
out=$(ev Stop "\"last_assistant_message\":\"All tests pass.\\nSecond line $long\"")
check "Stop -> idle" "$(field status)" idle
check "Stop stamps finished_at" "$(( EPOCHREALTIME - $(field finished_at) < 5 ))" 1
check "last message cut to 4,000" "$(field last_message | wc -m | tr -d ' ')" 4001  # 4,000 + wc's newline
check "Stop returns an OSC 9 notification" "$(print -r -- $out | jq -r .terminalSequence | cut -c2-)" "]9;demo-project finished: All tests pass."$'\a'

# While the Cue app notifies (its pid in notifier.pid), Stop leaves the terminal banner out.
# A stand-in process named cue: the kernel names a symlink after its target, and a copied /bin/sleep won't run.
mkdir -p $CUE_DIR/bin && print '#include <unistd.h>\nint main(void) { pause(); }' | cc -x c - -o $CUE_DIR/bin/cue
$CUE_DIR/bin/cue &
notifier=$!
print $notifier > $CUE_DIR/notifier.pid
check "Stop prints no banner while Cue notifies" "$(ev Stop '"last_assistant_message":"x"')" ""
amp_notifies() { CUE_DIR=$CUE_DIR node --no-warnings -e "import('$PWD/plugins/amp/cue.ts').then((m) => console.log(m.cueNotifies()))"; }
check "the Amp plugin leaves the banner to Cue too" "$(amp_notifies)" true
kill $notifier; wait $notifier 2>/dev/null
check "a notifier.pid left by a crash brings the banner back" "$(ev Stop '"last_assistant_message":"x"' | jq -r '.terminalSequence | length > 0')" true
check "and the Amp plugin's banner too" "$(amp_notifies)" false
rm $CUE_DIR/notifier.pid

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
finished=$(field finished_at)
ev Interrupt > /dev/null; ev Notification '"notification_type":"idle_prompt"' > /dev/null
check "a turn ending without Stop leaves finished_at alone" "$(field finished_at)" "$finished"
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

print "      -- codex"
X=01a18a05-536c-77d0-b9bb-3f3117bb510b
tui=$CUE_DIR/tui.jsonl; print '{"type":"session_meta","payload":{"originator":"codex-tui"}}' > $tui
cx() { print -r -- "{\"hook_event_name\":\"$1\",\"session_id\":\"${3:-$X}\",\"cwd\":\"/tmp/codex-project\",\"transcript_path\":\"${4:-$tui}\"${2:+,$2}}" | "$BIN" hook codex; }
out=$(cx SessionStart '"source":"startup"')
check "Codex SessionStart registers idle" "$(field status $X)" idle
check "Codex row is tagged codex" "$(field agent $X)" codex
check "Codex hooks always print JSON" "$out" "{}"
check "Codex row records no tab" "$(field iterm_session_id $X)" null
cx UserPromptSubmit '"turn_id":"turn-1","prompt":"hi"' > /dev/null
check "Codex UserPromptSubmit -> working" "$(field status $X)" working
check "Codex turn recorded" "$(field turn_id $X)" turn-1
cx PermissionRequest '"turn_id":"turn-1","tool_name":"Bash"' > /dev/null
check "Codex PermissionRequest -> needs_you" "$(field status $X)" needs_you
cx PostToolUse '"turn_id":"turn-1","tool_name":"Bash"' > /dev/null
check "Codex PostToolUse -> working" "$(field status $X)" working
out=$(cx Stop '"turn_id":"turn-1","last_assistant_message":"Done here."')
check "Codex Stop -> idle" "$(field status $X)" idle
check "Codex Stop stores the reply" "$(field last_message $X)" "Done here."
check "Codex Stop prints {}" "$out" "{}"
cx PostToolUse '"turn_id":"turn-0","tool_name":"Read"' > /dev/null
check "subagent event from another turn ignored" "$(field status $X)" idle
cx UserPromptSubmit '"turn_id":"turn-2","prompt":"again"' > /dev/null
cx Interrupt '"turn_id":"turn-1"' > /dev/null
check "a late Interrupt from an earlier turn is ignored" "$(field status $X)" working
cx Interrupt '"turn_id":"turn-2"' > /dev/null
check "Codex Interrupt -> idle" "$(field status $X)" idle
cx UserPromptSubmit '"turn_id":"turn-4","prompt":"with a subagent"' > /dev/null
finished=$(field finished_at $X)
cx Stop '"turn_id":"turn-sub","last_assistant_message":"subagent reply"' > /dev/null
check "a subagent's Stop doesn't end the parent's turn" "$(field status $X)/$(field finished_at $X)/$(field last_message $X)" "working/$finished/Done here."
cx Stop '"turn_id":"turn-4","last_assistant_message":"Parent done."' > /dev/null
check "the parent's own Stop ends it" "$(field status $X)/$(field last_message $X)" "idle/Parent done."
E=01a18a05-0000-7000-8000-00000000e8ec; ex=$CUE_DIR/exec.jsonl
print '{"type":"session_meta","payload":{"originator":"codex_exec"}}' > $ex
cx SessionStart '"source":"startup"' $E $ex > /dev/null
check "codex exec sessions are skipped" "$([[ -e $CUE_DIR/sessions/$E.json ]] && print row || print none)" none
print -r -- "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"01a18a05-0000-7000-8000-00000000bead\",\"cwd\":\"/tmp/memories\",\"transcript_path\":null,\"turn_id\":\"t\"}" | "$BIN" hook codex > /dev/null
check "Codex background sessions without a rollout are skipped" "$([[ -e $CUE_DIR/sessions/01a18a05-0000-7000-8000-00000000bead.json ]] && print row || print none)" none
check "a codex exec run leaves the TUI row alone" "$(field status $X)" idle
out=$(print -r -- 'garbage' | "$BIN" hook codex)
check "Codex malformed input still prints {}" "$out" "{}"

print "      -- codex delivery"
fake=$CUE_DIR/fake-codex; print -r -- '#!/bin/sh
printf "%s\n" "$@" > "$CUE_DIR/codex-args"; echo "PATH=$PATH" >> "$CUE_DIR/codex-args"' > $fake; chmod +x $fake
print -r -- "{\"codex\":\"$fake\",\"path\":\"/opt/test/bin:/usr/bin:/bin\"}" > $CUE_DIR/config.json
out=$(CUE_DIR=$CUE_DIR "$BIN" send $X '- starts with a dash' 2>&1)
check "send to idle Codex reports sent" "$out" sent
check "send to idle Codex runs codex queue" "$(sed -n 1p $CUE_DIR/codex-args)" queue
check "thread passed with =" "$(sed -n 2p $CUE_DIR/codex-args)" "--thread=$X"
check "message passed with =, dash intact" "$(sed -n 3p $CUE_DIR/codex-args)" "--message=- starts with a dash"
check "codex runs with the install-time PATH" "$(sed -n 4p $CUE_DIR/codex-args)" "PATH=/opt/test/bin:/usr/bin:/bin"
cx UserPromptSubmit '"turn_id":"turn-3","prompt":"busy"' > /dev/null
check "send to working Codex is queued" "$("$BIN" send $X 'next task' 2>&1)" queued
# The footer's hook check, against a fake `codex app-server` that answers with $CUE_DIR/listing.
print -r -- '#!/bin/sh
read -r a; read -r b; read -r c
printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"; cat "$CUE_DIR/listing"' > $fake
hooks() {  # hooks <trust status of the last of seven>
  local h='{"command":"'"'/x/cue' hook codex"'","enabled":true,"trustStatus":"trusted"}'
  print -r -- "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"data\":[{\"cwd\":\"/\",\"hooks\":[$h,$h,$h,$h,$h,$h,${h/trusted/$1}]}]}}" > $CUE_DIR/listing
}
hooks trusted
check "Codex health: seven trusted hooks pass" "$("$BIN" codex-health /x/cue)" ok
hooks modified
check "Codex health: a changed hook needs review" "$("$BIN" codex-health /x/cue)" "Codex hooks need review: run /hooks in Codex"
check "Codex health: another binary's hooks count as missing" "$("$BIN" codex-health /y/cue)" "Cue's Codex hooks are missing: run ./install.sh"
print -r -- '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}' > $CUE_DIR/listing
check "Codex health: an error reply stays quiet" "$("$BIN" codex-health /x/cue)" "no answer"
rm $CUE_DIR/config.json
check "send without a codex path refuses" "$("$BIN" send $X 'x' 2>&1)" "Cue doesn't know where codex is; run install.sh again"
cx SessionEnd > /dev/null
check "Codex SessionEnd deletes the row" "$([[ -e $CUE_DIR/sessions/$X.json ]] && print row || print none)" none
O=01a18a05-0000-7000-8000-0000000000c1
cx SessionStart '"source":"startup"' $O > /dev/null
cx SessionStart '"source":"startup"' 01a18a05-0000-7000-8000-0000000000c2 > /dev/null
check "a new Codex session in the same folder retires the old idle row" "$([[ -e $CUE_DIR/sessions/$O.json ]] && print row || print none)" none

print "      -- amp inbox"
A=T-01a18a06-d728-70de-8d1e-8cc150b0f6fc
amp_row() { print -r -- "{\"session_id\":\"$A\",\"agent\":\"amp\",\"cwd\":\"/tmp/amp-project\",\"status\":\"$1\",\"updated_at\":0,\"heartbeat\":$2}" > $CUE_DIR/sessions/$A.json; }
drain() {  # plays the plugin's part: the real drainInbox from plugins/amp/cue.ts
  CUE_DIR=$CUE_DIR node --no-warnings -e "
    import('$PWD/plugins/amp/cue.ts').then(async ({ drainInbox }) => {
      for (let i = 0; i < 40; i++) {
        await drainInbox('$CUE_DIR/inbox/$A', async (c) => { require('fs').appendFileSync('$CUE_DIR/amp-got', c + '\n') })
        await new Promise(r => setTimeout(r, 100))
      }
    })"
}
amp_row idle $EPOCHREALTIME
drain & out=$("$BIN" send $A 'hello amp' 2>&1); wait
check "Amp send is delivered through the inbox" "$out" delivered
check "the plugin got the prompt once" "$(cat $CUE_DIR/amp-got)" "hello amp"
check "no inbox leftovers" "$(ls -A $CUE_DIR/inbox/$A | grep -v receipts | wc -l | tr -d ' ')" 0
amp_row working $EPOCHREALTIME
drain & drain & out=$("$BIN" send $A 'only once' 2>&1); wait
check "two Amp processes, one delivery" "$(grep -c 'only once' $CUE_DIR/amp-got)" 1
out=$("$BIN" send $A 'nobody home' 2>&1)
check "unclaimed prompt is withdrawn" "$out" "Amp didn't pick it up"
check "withdrawn prompt left nothing behind" "$(ls -A $CUE_DIR/inbox/$A | grep -v receipts | wc -l | tr -d ' ')" 0
amp_row idle $EPOCHREALTIME
check "a prompt over 60 KB is refused" "$("$BIN" send $A "$(printf 'x%.0s' {1..61000})" 2>&1)" "Prompt is too long for Amp (60 KB at most)"
mkdir -p $CUE_DIR/inbox/$A; old=$CUE_DIR/inbox/$A/0a1b2c3d-0000-4000-8000-0000000000cc.json
print '{"content":"orphan"}' > $old; chmod 600 $old; touch -t 202001010000 $old
: > $CUE_DIR/amp-got; drain
check "an orphaned prompt is dropped, never sent late" "$(wc -c < $CUE_DIR/amp-got | tr -d ' ')$([[ -e $old ]] && print ' still there')" 0
amp_row idle $(( EPOCHREALTIME - 60 ))
check "stale heartbeat refuses the send" "$("$BIN" send $A 'x' 2>&1)" "Amp isn't answering; is the thread still open?"
mkdir -p $CUE_DIR/inbox/$A; print '{"content":"evil"}' > $CUE_DIR/inbox/$A/0a1b2c3d-0000-4000-8000-0000000000aa.json; chmod 644 $CUE_DIR/inbox/$A/*.json
ln -s /etc/hosts $CUE_DIR/inbox/$A/0a1b2c3d-0000-4000-8000-0000000000bb.json
: > $CUE_DIR/amp-got; drain
check "plugin skips wrong-mode files and symlinks" "$(wc -c < $CUE_DIR/amp-got | tr -d ' ')" 0

print "      -- amp plugin, fake API"
rm -rf $CUE_DIR/sessions/* $CUE_DIR/inbox
CUE_DIR=$CUE_DIR node --no-warnings tests/amp-plugin.mjs $PWD/plugins/amp/cue.ts $BIN \
  T-0a1b2c3d-0000-4000-8000-00000000000a T-0a1b2c3d-0000-4000-8000-00000000000b || fails=$((fails+1))

print; (( fails == 0 )) && print "all checks passed" || print "$fails check(s) failed"
exit $(( fails > 0 ))
