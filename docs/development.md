# Development

## Layout

| Path | Purpose |
| --- | --- |
| `Package.swift` | The `CueCore` library, the `cue` executable and the `CueCoreTests` suites, in Swift 6 language mode |
| `Sources/CueCore/Session.swift` | `Session`, and the `Agent` and `Status` enums: the rules that differ between agents, liveness, Claude interrupt detection |
| `Sources/CueCore/Store.swift` | The session files, the lock, and `config.json` |
| `Sources/CueCore/Proc.swift` | Process facts from `sysctl` |
| `Sources/CueCore/Hook.swift` | Hook mode for Claude Code and Codex: event to status, the fallback banner |
| `Sources/CueCore/Alert.swift` | Which session change notifies, what it says and which sound plays; the `notifier.pid` handshake |
| `Sources/CueCore/Codex.swift` | `codex queue`, which Codex sessions are interactive, and the hook health check |
| `Sources/CueCore/Delivery.swift` | Sending: the agent switch, Claude typing with its checks, `sanitize`, key chunks, `DeliveryError` |
| `Sources/CueCore/Terminal.swift` | The `Terminal` protocol and its two terminals, `ITermTab` (AppleScript) and `TmuxPane` (tmux CLI) |
| `Sources/CueCore/Inbox.swift` | The app's half of the Amp inbox: drop, receipt, withdraw |
| `Sources/CueCore/Command.swift` | The process runner, with a timeout and a typed error |
| `Sources/cue/main.swift` | Picks the mode (app, `hook`, `send`, `codex-health`) before AppKit loads |
| `Sources/cue/AppDelegate.swift` | The scene, the menubar item, the popover and the hotkey wiring |
| `Sources/cue/SessionMonitor.swift` | Reads the session files every second: liveness, expiry, interrupt repair, the hook checks |
| `Sources/cue/AppModel.swift` | The popover's state: sort order, one `RowState` per row, sending and confirmation |
| `Sources/cue/Worker.swift` | A serial queue behind an async API, for blocking calls |
| `Sources/cue/PopoverView.swift`, `RowView.swift` | The SwiftUI views |
| `Sources/cue/Notifier.swift` | Plays sounds, posts notifications, and opens the popover on a click |
| `Sources/cue/LoginItem.swift` | The login item, through `SMAppService` |
| `Sources/cue/HotKey.swift` | The ⌃⌥Space global shortcut |
| `Sources/cue/SendCommand.swift` | `cue send` (`cue open` and `codex-health` live in `main.swift`) |
| `tests/CueCoreTests/` | swift-testing suites for CueCore, with real Claude Code screen captures |
| `plugins/amp/cue.ts` | The Amp plugin; `drainInbox` is exported for the tests |
| `Info.plist` | Bundle id, `LSUIElement`, the app icon, the Automation usage string |
| `assets/` | The icon sources (`icon.svg`, `menubar.svg`), the generated `AppIcon.icns` and `menubar.tiff`, the agents' logos (`agent-*.png`), and `build.sh` |
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

## The icon

`assets/icon.svg` is the app icon and `assets/menubar.svg` the menubar mark: two stacked session windows, a prompt in the front one, and a dot for the session waiting on you. After editing either, run `assets/build.sh` (it needs `rsvg-convert`, from `brew install librsvg`) and commit the regenerated `AppIcon.icns` and `menubar.tiff`; `install.sh` copies both into the bundle. The app draws `menubar.tiff` (1x and 2x) as a template image, so it must stay black on transparent. A build run from `.build/` has no bundle and shows the `terminal` SF Symbol instead.

The rows show each agent's own logo as a 64 px PNG: `agent-codex.png` is the Codex app logo from the Codex editor extension, `agent-amp.png` is the app icon from ampcode.com, and `agent-claude.png` is rendered by `build.sh` from `agent-claude.svg`, the Claude starburst from Simple Icons in Claude's coral (`#D97757`). They are their makers' trademarks, used only to mark which agent a row belongs to; when an agent restyles its logo, replace the file and reinstall.

| Color | Hex | Use |
| --- | --- | --- |
| Ink | `#2E323C` to `#121419` | The icon's background gradient, top to bottom |
| Slate | `#596071` | The back window |
| Paper | `#F4F1EA` | The front window |
| Amber | `#FFB224` | The waiting dot, with a soft glow in the app icon |

## Tests

```sh
swift test        # CueCore's unit tests
tests/check.sh    # those, then the built binary's behavior
```

`swift test` runs the swift-testing suites in `tests/CueCoreTests`: the notification rules, Claude typing against a fake terminal, the screen checks against real Claude Code captures, `sanitize` and key chunks, the agent rules, liveness, the session file format, which terminal a session types into, Claude interrupt detection, and the Codex checks. The Command Line Tools include swift-testing, so Xcode isn't needed.

`tests/check.sh` runs `swift test`, then, with `CUE_DIR` set to a temp folder:

- every Claude Code and Codex status rule, file modes, malformed input, path-like ids, ten parallel hooks, and a 50 ms average per hook run;
- the tmux fields a Claude hook records, an odd `$TMUX_PANE` rejected, and the fields cleared when a session leaves tmux;
- Codex specifics: `codex exec` skipping, a late `Interrupt` from an earlier turn, and a new session retiring the folder's old idle row;
- Codex delivery against a fake `codex` that records its arguments and PATH, and the footer's hook check against a fake `codex app-server`: all trusted, one changed, another binary's hooks, and an error reply;
- the Amp inbox, by running the plugin's real `drainInbox` under Node against `cue send`: delivery, two plugin processes delivering once, withdrawal of an unclaimed prompt, an orphaned prompt, the 60 KB cap, a stale heartbeat, and the file checks;
- the whole Amp plugin, through `tests/amp-plugin.mjs` and a fake PluginAPI: seeding the open thread, state changes, `agent.end`, a `cue send` round trip, and a thread switch.

It touches nothing outside the temp folder.

**CI.** `.github/workflows/test.yml` runs on GitHub Actions for every push to `master` and every pull request, on a macOS runner with Node 24: `swift test`, then `swift build -c release`, then `tests/check.sh`. CI sets `HOOK_BUDGET_MS=200`, since shared runners run hooks slower than the 50 ms the script allows by default. `tests/e2e.sh` stays local: it drives real Claude Code, Codex and Amp sessions, which need your accounts and iTerm2.

```sh
tests/e2e.sh
```

Opens iTerm2 windows and drives real sessions through `cue send`:

- **Claude Code** (two sessions): a one-line prompt, a send over a half-typed draft, a 5-line prompt, a permission dialog, a forced-idle file during that dialog, the Ctrl+G editor, Ctrl+Z, and a closed tab.
- **Claude Code in tmux**, in a detached session on a private socket: a confirmed send, copy mode and synchronized panes refused, Open with no client and with its client in an iTerm2 tab, a two-line prompt with a line ending in `;` over a half-typed draft, Ctrl+Z, and a killed server.
- **Amp**, when the installed plugin matches `plugins/amp/cue.ts`: registration, delivery, a send during a running turn, and the heartbeat stopping after the window closes.
- **Codex**, when Cue's hooks are in `~/.codex/hooks.json` and trusted: registration, a confirmed send, and a queued send during a running turn.

It makes a few small model calls and closes its windows when done. Don't touch the keyboard while it runs. The Claude sessions use `--settings .spike/e2e/settings.json`, which points their hooks at `.build/release/cue`.

## Debugging

```sh
jq -c '{agent, cwd, status, updated_at}' ~/.cue/sessions/*.json         # what the app sees
tail ~/.cue/hook.log                                                     # hook errors
echo '{"hook_event_name":"Stop","session_id":"x","cwd":"/tmp"}' | CUE_DIR=/tmp/c .build/release/cue hook claude
.build/release/cue send <session-id> "Reply with PONG"                   # exit 0 delivered, 1 refused, 2 unconfirmed
.build/release/cue open <session-id>                                     # what Open does, without the app
.build/release/cue codex-health ~/Applications/Cue.app/Contents/MacOS/cue   # what the footer says about Codex hooks
ls -la ~/.cue/inbox/*/                                                   # Amp prompts not yet claimed
```

`send` prints the same messages as the popover, which makes it the quickest way to see why a row won't send. For the Amp plugin, Amp's own plugin logs show `cue inbox` errors.

Avoid `screencapture` while testing: it makes macOS ask for iTerm2 screen-recording permission, and that dialog takes keyboard focus.

## When an agent updates

Cue depends on behavior the agents don't promise. After an upgrade, run `tests/e2e.sh`, and check the assumptions for the agent that changed.

| Agent | Assumption | Where | How to check |
| --- | --- | --- | --- |
| Claude Code | The input box is a `❯` line in column 0 between two `─` rule lines | `Delivery.box` | Save a screen with `tests/iterm.sh screen <iterm-id>` or `tmux capture-pane -p -t <pane>` (or take `~/.cue/unreadable-screen.txt`, kept when a send found no box), then `CUE_SCREEN_FILE=<file> swift test --filter LiveScreen` |
| Claude Code | The working spinner reads `✻ Word… (` right above the box | `Delivery.isSpinner` | Capture a tab while Claude works |
| Claude Code | Input that arrives in a burst becomes `<pasted_content>` | `Delivery.keys`, and the 150 ms gap in each `Terminal.send` | Send a long line, grep the transcript for `pasted_content` |
| Claude Code | ESC + CR inserts a line break; Ctrl+U clears to line start | `Key`, send step 4 | Send a 3-line prompt over a draft |
| Claude Code | Esc and denials write `[Request interrupted by user…]` | `Session.interrupted` | Interrupt a turn, read the transcript tail |
| Claude Code | Hooks run as children of a process named `claude` | `Proc.claude()` | `ps -o pid,ppid,comm` from inside a hook |
| Codex | Hook events and payload fields match the hooks docs, with `Interrupt` and `turn_id` | `Hook.handle` | Read `~/.cue/sessions/*.json` after a turn |
| Codex | A rollout's first line names its `originator`, `codex-tui` for the TUI | `Codex.interactive` | `head -1` of a rollout in `~/.codex/sessions/` |
| Codex | `codex queue --thread= --message=` queues into a live session | `Codex.queue` | Send to an open session |
| Codex | `codex app-server` answers `hooks/list` with `command`, `enabled` and `trustStatus` per hook | `Codex.listHooks` | Untrust a Cue hook in `/hooks`, reopen the popover |
| Amp | `amp.activeThread`, thread `state`, `appendUserMessage` and `agent.end` behave as the plugin API docs say | `plugins/amp/cue.ts` | `amp plugins show-docs`, then the e2e Amp part |

Update the captures in `tests/CueCoreTests/ScreenTests.swift` when Claude Code's screen format changes, so the tests track the real UI.

## Adding an agent or a terminal

- **An agent:** add a case to `Agent` in `Session.swift`. The compiler then stops at every `switch` that needs it: the agent's name, its liveness, its delivery channel in `Delivery.send`, and its symbol in `RowView`. Rules shared by several agents are properties on `Agent`, such as `queuesWhileBusy` and `canOpen`.
- **A terminal for Claude Code:** write a type that conforms to `Terminal` (read the screen, send key chunks, open), and return it from `Session.terminal` when the hook recorded what it needs. The safety checks in `Delivery` apply to it unchanged. Kitty (`kitty @ send-text`) and WezTerm (`wezterm cli send-text`) would fit this way.

## Adding a hook event

1. Add a `case` to the switch in `Hook.handle` and decide its status for each agent.
2. Add the event to the `reduce` lists in `install.sh` for the agents that send it, and to the settings in `tests/e2e.sh`.
3. Add a check to `tests/check.sh`.
4. Run `./install.sh`. A second install adds the new event and skips the existing ones; Codex asks you to trust the new hook. Changing the definition of an existing Cue hook in `install.sh` (its timeout, say) updates it in place, and Codex asks you to trust it again.
