# Development

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/main.swift` | Picks the mode (app, `hook`, `send`, `selftest`, `codex-health`) before AppKit loads |
| `Sources/Session.swift` | Session model, file store, lock, config, `sysctl` process facts, Claude interrupt detection |
| `Sources/Hook.swift` | Hook mode for Claude Code and Codex: event to status, notification output, Codex originator check and hook health |
| `Sources/Delivery.swift` | Sending: Claude typing with its checks (iTerm2 and tmux), `codex queue`, the process runner, the `send` command |
| `Sources/Inbox.swift` | The app's half of the Amp inbox: drop, receipt, withdraw |
| `Sources/App.swift` | Menubar app: status item, popover, model, rows |
| `Sources/HotKey.swift` | The ⌃⌥Space global shortcut |
| `Sources/SelfTest.swift` | Asserts for the pure functions, using real screen captures |
| `plugins/amp/cue.ts` | The Amp plugin; `drainInbox` is exported for the tests |
| `Info.plist` | Bundle id, `LSUIElement`, the Automation usage string |
| `install.sh`, `uninstall.sh` | Build, install, migration, and settings merges |
| `tests/check.sh` | Hook state machines, delivery and the inbox, in a temp folder |
| `tests/amp-plugin.mjs` | Drives the real Amp plugin through a fake PluginAPI, for `tests/check.sh` |
| `tests/e2e.sh` | Real Claude Code, Amp and Codex sessions in iTerm2 windows, and Claude Code in tmux |
| `tests/iterm.sh` | Drives iTerm2 tabs by session id, for the e2e test |

## Build and run

```sh
swift build -c release            # .build/release/cue
.build/release/cue                # run the app without installing
./install.sh                      # build, install, wire up the agents, launch
```

The app reads `Bundle.main.executablePath` to tell whether its Claude hooks are installed, so a build run from `.build/` shows "Hooks missing" in the footer. That's expected.

Each `./install.sh` re-signs the app ad hoc, and macOS asks for Automation permission again on the next Claude Code Send. Changing Cue's Codex hook command string makes Codex ask you to trust the hooks again in `/hooks`.

## Tests

```sh
tests/check.sh
```

Runs `cue selftest`, then, with `CUE_DIR` set to a temp folder:

- every Claude Code and Codex status rule, file modes, malformed input, path-like ids, ten parallel hooks, and a 50 ms average per hook run;
- the tmux fields a Claude hook records, an odd `$TMUX_PANE` rejected, and the fields cleared when a session leaves tmux;
- Codex specifics: `codex exec` skipping, a late `Interrupt` from an earlier turn, and a new session retiring the folder's old idle row;
- Codex delivery against a fake `codex` that records its arguments and PATH, and the footer's hook check against a fake `codex app-server`: all trusted, one changed, another binary's hooks, and an error reply;
- the Amp inbox, by running the plugin's real `drainInbox` under Node against `cue send`: delivery, two plugin processes delivering once, withdrawal of an unclaimed prompt, an orphaned prompt, the 60 KB cap, a stale heartbeat, and the file checks;
- the whole Amp plugin, through `tests/amp-plugin.mjs` and a fake PluginAPI: seeding the open thread, state changes, `agent.end`, a `cue send` round trip, and a thread switch.

It touches nothing outside the temp folder.

```sh
tests/e2e.sh
```

Opens iTerm2 windows and drives real sessions through `cue send`:

- **Claude Code** (two sessions): a one-line prompt, a send over a half-typed draft, a 5-line prompt, a permission dialog, a forced-idle file during that dialog, the Ctrl+G editor, Ctrl+Z, and a closed tab.
- **Claude Code in tmux**, in a detached session on a private socket: a confirmed send, copy mode and synchronized panes refused, a two-line prompt with a line ending in `;` over a half-typed draft, Ctrl+Z, and a killed server.
- **Amp**, when the installed plugin matches `plugins/amp/cue.ts`: registration, delivery, a send during a running turn, and the heartbeat stopping after the window closes.
- **Codex**, when Cue's hooks are in `~/.codex/hooks.json` and trusted: registration, a confirmed send, and a queued send during a running turn.

It makes a few small model calls and closes its windows when done. Don't touch the keyboard while it runs. The Claude sessions use `--settings .spike/e2e/settings.json`, which points their hooks at `.build/release/cue`.

## Debugging

```sh
jq -c '{agent, cwd, status, updated_at}' ~/.cue/sessions/*.json         # what the app sees
tail ~/.cue/hook.log                                                     # hook errors
echo '{"hook_event_name":"Stop","session_id":"x","cwd":"/tmp"}' | CUE_DIR=/tmp/c .build/release/cue hook claude
.build/release/cue send <session-id> "Reply with PONG"                   # exit 0 delivered, 1 refused, 2 unconfirmed
.build/release/cue codex-health ~/Applications/Cue.app/Contents/MacOS/cue   # what the footer says about Codex hooks
ls -la ~/.cue/inbox/*/                                                   # Amp prompts not yet claimed
```

`send` prints the same messages as the popover, which makes it the quickest way to see why a row won't send. For the Amp plugin, Amp's own plugin logs show `cue inbox` errors.

Avoid `screencapture` while testing: it makes macOS ask for iTerm2 screen-recording permission, and that dialog takes keyboard focus.

## When an agent updates

Cue depends on behavior the agents don't promise. After an upgrade, run `tests/e2e.sh`, and check the assumptions for the agent that changed.

| Agent | Assumption | Where | How to check |
| --- | --- | --- | --- |
| Claude Code | The input box is a `❯` line in column 0 between two `─` rule lines | `Delivery.box` | `tests/iterm.sh screen <iterm-id>`, or `tmux capture-pane -p -t <pane>` |
| Claude Code | The working spinner reads `✻ Word… (` right above the box | `Delivery.isSpinner` | Capture a tab while Claude works |
| Claude Code | Input that arrives in a burst becomes `<pasted_content>` | Chunking in `Delivery.items` and `typeScript` | Send a long line, grep the transcript for `pasted_content` |
| Claude Code | ESC + CR inserts a line break; Ctrl+U clears to line start | `typeScript`, send step 4 | Send a 3-line prompt over a draft |
| Claude Code | Esc and denials write `[Request interrupted by user…]` | `Session.interrupted` | Interrupt a turn, read the transcript tail |
| Claude Code | Hooks run as children of a process named `claude` | `Proc.claude()` | `ps -o pid,ppid,comm` from inside a hook |
| Codex | Hook events and payload fields match the hooks docs, with `Interrupt` and `turn_id` | `Hook.handle` | Read `~/.cue/sessions/*.json` after a turn |
| Codex | A rollout's first line names its `originator`, `codex-tui` for the TUI | `Codex.interactive` | `head -1` of a rollout in `~/.codex/sessions/` |
| Codex | `codex queue --thread= --message=` queues into a live session | `Delivery.queueToCodex` | Send to an open session |
| Codex | `codex app-server` answers `hooks/list` with `command`, `enabled` and `trustStatus` per hook | `Codex.listHooks` | Untrust a Cue hook in `/hooks`, reopen the popover |
| Amp | `amp.activeThread`, thread `state`, `appendUserMessage` and `agent.end` behave as the plugin API docs say | `plugins/amp/cue.ts` | `amp plugins show-docs`, then the e2e Amp part |

Update the captures in `SelfTest.swift` when Claude Code's screen format changes, so the selftest tracks the real UI.

## Adding a hook event

1. Add a `case` to the switch in `Hook.handle` and decide its status for each agent.
2. Add the event to the `reduce` lists in `install.sh` for the agents that send it, and to the settings in `tests/e2e.sh`.
3. Add a check to `tests/check.sh`.
4. Run `./install.sh`. A second install adds the new event and skips the existing ones; Codex asks you to trust the new hook. Changing the definition of an existing Cue hook in `install.sh` (its timeout, say) updates it in place, and Codex asks you to trust it again.
