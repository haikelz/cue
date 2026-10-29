# User guide

Claude Relay lives in the menubar. Click the terminal icon to open the popover, find the session you want, type its next prompt, and press Return.

## The menubar icon

The icon shows a count when one or more iTerm2 sessions are idle or need you. No count means every session is working, or none is running.

## The popover

The popover lists one row per Claude Code session. Relay sorts the rows each time the popover opens:

1. Needs you (a permission dialog or an MCP question is open)
2. Idle, longest wait first
3. Working, by project name

Rows keep their places while the popover stays open, so a row never moves under your cursor. Past four sessions, the list scrolls.

Each row shows:

- **Project name**: the last folder of the session's working directory. Two sessions in one folder get a 4-character session id suffix, for example `api-server · 8f2c`.
- **Status badge**: the status and the time since it last changed, for example `Idle · 3m`.
- **Last message**: the first two lines of Claude's final reply.
- **Prompt field**: grows up to six lines.
- **Send** and **Open** buttons.
- **A note** under the field when something needs your attention. See [Row messages](#row-messages).

The footer shows whether Relay's hooks are installed, and holds the Quit button.

### Statuses

| Badge | Meaning | Prompt field | Send |
| --- | --- | --- | --- |
| Idle | Claude finished and waits for input | Enabled | Enabled once you type |
| Working | Claude is busy | Enabled, so you can draft ahead | Disabled until idle |
| Needs you | A permission dialog or MCP question is open in the terminal | Disabled | Disabled; answer in the terminal |
| Not in iTerm2 | The session runs in tmux or another terminal | Disabled | Disabled |

A draft stays in its field while the app runs, even across `/clear`, because drafts follow the iTerm2 tab, not the session.

## Sending a prompt

Type in the field and press **Return** or click **Send**. **Option+Return** adds a line break.

Before typing anything, Relay checks that the session is idle, that its Claude process runs in the foreground of that tab, and that Claude's input box sits on screen with no spinner above it. Then it:

1. Clears any text already in the input box with Ctrl+U. If that text was a draft of yours, press **Ctrl+Y** in the tab to get it back.
2. Types your prompt in small chunks, so Claude Code reads it as typed text rather than a paste.
3. Runs every check again, confirms the box ends with your prompt, and presses Return.
4. Waits up to 5 seconds for the session to report the new prompt, then clears the field.

Prompts that start with `/` (slash commands) or `!` (shell commands) behave as if you typed them in the terminal. Relay shows "Sent" for these without waiting, since they may not report back.

A long prompt takes a moment: each 200 characters adds 150 ms.

## Opening a session

**Open** brings the session's iTerm2 window and tab to the front. Use it to answer a permission dialog, or to read Claude's full reply.

## Notifications

When a session finishes its turn, iTerm2 shows "‹project› finished: ‹first line of Claude's reply›". When a turn ends on an API error, it shows "‹project› stopped: API error: ‹type›". Clicking the notification opens that tab. Relay adds no notification for permission prompts; Claude Code's own notification settings cover those.

No notifications? Allow them for iTerm2 in System Settings > Notifications.

## Row messages

| Message | What happened | What to do |
| --- | --- | --- |
| Sending… | Relay is typing your prompt | Wait |
| Sent | A `/` or `!` prompt went through | Nothing |
| Not confirmed. Prompt copied to clipboard. | Relay pressed Return, but the session didn't report the prompt within 5 s | Click Open and look. If the prompt isn't there, paste it from the clipboard |
| Typed but not sent: … The text is in the tab's input box | A check failed after typing, so Relay held back Return | Click Open, check the text, press Return yourself |
| Typed but not sent: the input box doesn't end with this prompt | The typed text didn't land as expected | Click Open and fix the input box by hand |
| Claude is working | The session started working | Wait for idle |
| Claude needs you in the terminal | A permission dialog or MCP question is open | Click Open and answer it |
| Claude's input box isn't on screen (dialog, editor or menu open) | A dialog, menu, picker or the Ctrl+G editor covers the input box | Click Open and close it |
| Claude's vim mode is in NORMAL; press i in the terminal | Claude Code's vim mode would read your text as commands | Press `i` in the tab, then Send again |
| Claude isn't in the foreground (suspended?) | Claude is suspended (Ctrl+Z) or another program owns the terminal | Run `fg` in the tab |
| Claude process is gone | Claude exited | Start a new session; the row disappears within a second |
| Tab no longer runs this session | The tab now runs something else | Nothing; the row clears itself |
| iTerm2 tab is closed | The tab was closed | Nothing; the row clears itself |
| Allow Claude Relay to control iTerm2 in System Settings > Privacy & Security > Automation | macOS blocked Relay from talking to iTerm2 | Turn on iTerm2 under Claude Relay in that settings pane |
| iTerm2 didn't answer in 60 s | iTerm2 hung, or a permission dialog waited too long | Answer any open macOS dialog, then Send again |

Whenever a send fails after typing started, Relay copies the prompt to the clipboard, so you never lose it.

## Permissions

| Permission | When macOS asks | Why |
| --- | --- | --- |
| Automation: control iTerm2 | Your first Send or Open | Relay types into tabs and reads their screen through AppleScript |
| Notifications for iTerm2 | iTerm2's first notification | iTerm2 posts the "finished" banners |

Relay is ad-hoc signed, so macOS treats each rebuild as a new app and asks for Automation again after `./install.sh`.

## Troubleshooting

**A running session doesn't appear.** Sessions register on their next hook event. Send it any prompt in the terminal. If the footer says "Hooks missing", run `./install.sh`.

**A row says Working, but Claude is idle.** Esc during a reply, or a denied permission, corrects itself within a second. Esc pressed before Claude writes anything leaves no trace Relay can read, so the row waits: open the popover, and Relay checks the screen of any row that has stayed at Working for 15 seconds.

**A row says Needs you after you answered.** The row updates when Claude's next tool call finishes, or when the turn ends.

**A session in tmux shows "Not in iTerm2".** Relay delivers to iTerm2 tabs, and inside tmux it can't tell which tab holds the session.

**Look at the raw data.** Each session is a JSON file in `~/.claude/relay/sessions/`. Hook errors go to `~/.claude/relay/hook.log`.

**Restore your settings.** Each install and uninstall saves `~/.claude/settings.json.relay-backup-YYYYMMDD-HHMMSS`. Copy one back over `settings.json` to undo.

## Limitations

- Relay delivers to iTerm2 tabs and no other terminal.
- A multi-line draft taller than the input box may not fully clear before Relay types.
- Relay reads Claude Code's screen layout, so a Claude Code UI change can make sends refuse until Relay updates. It refuses rather than types blind. See [Development](development.md#when-claude-code-updates).
