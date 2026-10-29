# Claude Relay

A macOS menubar app for people who run many Claude Code sessions at once. It lists each session with its status and Claude's last message, and you send any idle session its next prompt without hunting for its terminal window.

```
 >_ 2                      ← menubar: 2 sessions wait for you
┌──────────────────────────────────────────┐
│ api-server              Idle · 3m        │
│ All 42 tests pass. The /orders endpoint… │
│ [Next prompt                 ] Send Open │
├──────────────────────────────────────────┤
│ web-dashboard           Working · 40s    │
│ [Next prompt                 ] Send Open │
└──────────────────────────────────────────┘
```

- The menubar count shows how many sessions are idle or need you.
- Each row has a prompt field. Send types your prompt into that session's iTerm2 tab and presses Return.
- When a session finishes, iTerm2 shows a "‹project› finished" notification.
- Relay types nothing unless Claude's input box is idle and on screen, so a prompt never lands in a shell, an editor or a permission dialog.

## Requirements

- macOS 14 or later
- iTerm2 (sessions in tmux, Ghostty or Terminal.app appear but can't receive prompts)
- Claude Code 2.1.285 or later
- `jq`, and Swift 6 (the Xcode Command Line Tools are enough)

## Install

```sh
./install.sh
```

The script builds the app into `~/Applications/ClaudeRelay.app`, backs up `~/.claude/settings.json`, adds Relay's hooks beside your existing ones, and launches the app. Running sessions appear after their next prompt or reply.

On your first Send, macOS asks whether Claude Relay may control iTerm2. Click Allow.

## Documentation

| Guide | For |
| --- | --- |
| [User guide](docs/user-guide.md) | Using the popover, every row message explained, permissions, troubleshooting |
| [Architecture](docs/architecture.md) | Hooks, session files, the send pipeline and its safety checks |
| [Development](docs/development.md) | Building, testing, debugging, and what to re-check when Claude Code updates |

## Uninstall

```sh
./uninstall.sh
```

The script removes Relay's hooks and leaves every other hook alone, then deletes the app. Session files stay in `~/.claude/relay` until you delete them.
