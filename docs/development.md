# Development

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/main.swift` | Picks the mode (app, `hook`, `send`, `selftest`) before AppKit loads |
| `Sources/Session.swift` | Session model, file store, lock, `sysctl` process facts, interrupt detection |
| `Sources/Hook.swift` | Hook mode: hook event to status, notification output |
| `Sources/Delivery.swift` | The send pipeline: sanitizing, checks, AppleScript, the `send` command |
| `Sources/App.swift` | Menubar app: model, popover, rows |
| `Sources/SelfTest.swift` | Asserts for the pure functions, using real screen captures |
| `Info.plist` | Bundle id, `LSUIElement`, the Automation usage string |
| `install.sh`, `uninstall.sh` | Build, install, and settings merge |
| `tests/check.sh` | Hook state machine and selftest, in a temp folder |
| `tests/e2e.sh` | Real sessions in iTerm2 windows |
| `tests/iterm.sh` | Drives iTerm2 tabs by session id, for the e2e test |

## Build and run

```sh
swift build -c release            # .build/release/ClaudeRelay
.build/release/ClaudeRelay        # run the app without installing
./install.sh                      # build, install to ~/Applications, merge hooks, launch
```

The app reads `Bundle.main.executablePath` to tell whether its hooks are installed, so a build run from `.build/` shows "Hooks missing" in the footer. That's expected.

Each `./install.sh` re-signs the app ad hoc, and macOS asks for Automation permission again on the next Send.

## Tests

```sh
tests/check.sh
```

Runs `ClaudeRelay selftest` (screen parsing, spinner detection, sanitizing, chunking, the box-ends-with-prompt check, interrupt parsing), then feeds recorded hook payloads to `ClaudeRelay hook` with `RELAY_DIR` set to a temp folder. It covers every status rule, file modes, malformed input, path-like session ids, ten parallel hooks, and fails if a hook run averages 50 ms or more. It touches nothing outside the temp folder.

```sh
tests/e2e.sh
```

Opens two iTerm2 windows running `claude` in `.spike/e2e/`, then drives them through `ClaudeRelay send`: a one-line prompt, a send over a half-typed draft, a 5-line prompt with a 400-character line, a permission dialog (in default permission mode), a forced-idle file during that dialog, the Ctrl+G editor, Ctrl+Z, and a closed tab. It checks the right tab got each prompt, the other got nothing, and the refusals left no stray text. It makes a few small model calls and closes its windows when done. Don't touch the keyboard while it runs.

The sessions use `--settings .spike/e2e/settings.json`, which points the hooks at `.build/release/ClaudeRelay`, so the test runs against your latest build without reinstalling.

## Debugging

```sh
cat ~/.claude/relay/sessions/*.json | jq -c '{cwd, status, updated_at}'   # what the app sees
tail ~/.claude/relay/hook.log                                             # hook errors
echo '{"hook_event_name":"Stop","session_id":"x","cwd":"/tmp"}' | RELAY_DIR=/tmp/r .build/release/ClaudeRelay hook
.build/release/ClaudeRelay send <session-id> "Reply with PONG"           # exit 0 confirmed, 1 refused, 2 unconfirmed
```

`send` prints the same refusal messages as the popover, which makes it the quickest way to see why a row won't send.

Avoid `screencapture` while testing: it makes macOS ask for iTerm2 screen-recording permission, and that dialog takes keyboard focus.

## When Claude Code updates

Relay depends on Claude Code behavior that the hook docs don't promise. After an upgrade, run `tests/e2e.sh`. If it fails, check these assumptions:

| Assumption | Where | How to check |
| --- | --- | --- |
| The input box is a `❯` line in column 0 between two `─` rule lines | `Delivery.box` | Read a tab: `tests/iterm.sh screen <iterm-id>` |
| The working spinner reads `✻ Word… (` right above the box | `Delivery.isSpinner` | Capture a tab while Claude works |
| Input that arrives in a burst becomes `<pasted_content>` | Chunk size and gap in `Delivery.items` and `typeScript` | Send a long line and grep the transcript for `pasted_content` |
| ESC + CR inserts a line break | `typeScript` | Send a 3-line prompt |
| Ctrl+U clears to line start; Ctrl+Y restores | Step 4 of the send pipeline | Type a draft, send over it, press Ctrl+Y |
| Esc and denials write `[Request interrupted by user…]` | `Session.interrupted` | Interrupt a turn and read the transcript tail |
| Hooks run as children of a process named `claude` | `Proc.claude()` | `ps -o pid,ppid,comm` from inside a hook |

Update the captures in `SelfTest.swift` when a screen format changes, so the selftest tracks the real UI.

## Adding a hook event

1. Add a `case` to the switch in `Hook.handle` and decide its status.
2. Add the event to the `reduce` list in `install.sh` and to the settings in `tests/e2e.sh`.
3. Add a check to `tests/check.sh`.
4. Run `./install.sh`. A second install adds the new event and skips the existing ones.
