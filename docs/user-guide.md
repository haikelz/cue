# User guide

Cue lives in the menubar. Click the terminal icon to open the popover, find the session you want, type its next prompt, and press Return.

## The menubar icon

The icon shows a count when one or more sessions are idle or need you. No count means every session is working, or none is running.

## The popover

The popover lists one row per session: Claude Code sessions, Codex sessions, and the thread open in each Amp window. Cue sorts the rows each time the popover opens:

1. Needs you (a permission dialog or a question is open)
2. Idle, longest wait first
3. Working, by project name

Rows keep their places while the popover stays open, so a row never moves under your cursor. Past three sessions, the list scrolls.

Each row shows:

- **Agent and project**: for example `Codex · billing`. The project is the last folder of the session's working directory. Two sessions of one agent in one folder get a short id suffix.
- **Status badge**: the status and the time since it last changed, for example `Idle · 3m`.
- **Last message**: the first two lines of the agent's final reply.
- **Prompt box**: a text area four lines tall; a longer prompt scrolls inside it.
- **Send**, and **Open** for Claude Code and Amp rows.
- **A note** under the prompt box when something needs your attention. See [Row messages](#row-messages).

The footer shows whether Cue's Claude Code hooks are installed, and holds the Quit button.

### Statuses

| Badge | Claude Code | Codex and Amp |
| --- | --- | --- |
| Idle | Send enabled | Send enabled |
| Working | Draft ahead; Send waits for idle | Send queues the prompt behind the running turn |
| Needs you | Answer the dialog in the terminal first | Send queues; answer the dialog in the terminal |
| Not in iTerm2 | The session runs in tmux or another terminal; Send disabled | Doesn't apply: delivery doesn't use the terminal |

Claude Code drafts follow the iTerm2 tab, so a draft survives `/clear`. Codex and Amp drafts follow the session.

## Sending a prompt

Type in the prompt box. **Return** adds a line break; **⌘Return** or the **Send** button sends. The Send button of the row you're typing in turns blue, since it's the one ⌘Return triggers. Each agent takes the prompt its own way.

**Claude Code.** Cue types into the session's iTerm2 tab. Before typing anything, it checks that the session is idle, that its Claude process runs in the foreground of that tab, and that Claude's input box sits on screen with no spinner above it. Then it:

1. Clears any text already in the input box with Ctrl+U. If that text was a draft of yours, press **Ctrl+Y** in the tab to get it back.
2. Types your prompt in small chunks, so Claude Code reads it as typed text rather than a paste.
3. Runs every check again, confirms the box ends with your prompt, and presses Return.
4. Waits up to 5 seconds for the session to report the new prompt, then clears the prompt box.

A long prompt takes a moment: each 200 characters adds 150 ms.

**Codex.** Cue runs `codex queue`, which hands the prompt to Codex. An idle session starts it within seconds and the row says "Sent"; a working one runs it after the current turn, and the row says "Queued". If you closed that session's terminal, Codex runs the prompt in the background; `codex resume` shows the result. When you start a new Codex session in a folder, including with `/clear`, `/new` or `/resume`, the folder's older idle Codex row leaves the list, so a prompt can't go to a thread nobody sees.

**Amp.** Cue drops the prompt in its inbox, and Cue's plugin inside that Amp window adds it to the thread, where it shows as "Sent by plugin: cue". During a turn, Amp runs it after the turn ends. If no Amp window picks it up within 5 seconds, Cue takes it back and copies it to the clipboard, and the plugin discards any inbox file older than 10 seconds, so a prompt never arrives twice or late. Amp prompts are capped at 60 KB.

Prompts that start with `/` (slash commands) or `!` (shell commands) behave as if you typed them in the terminal. Cue shows "Sent" for these without waiting, since they may not report back.

## Opening a session

**Open** brings the session's iTerm2 window and tab to the front. Use it to answer a permission dialog, or to read the full reply. Codex rows have no Open: Codex runs hooks in a shared background process, so Cue can't tell which tab a Codex session lives in.

## Notifications

When a session finishes its turn, iTerm2 shows "‹project› finished: ‹first line of the reply›":

- **Claude Code**: Cue's hook asks Claude Code to post it.
- **Amp**: Cue's plugin posts it through the Amp window's terminal.
- **Codex**: Codex posts its own. Turn it on in `~/.codex/config.toml`:

  ```toml
  [tui]
  notifications = true
  ```

No notifications? Allow them for iTerm2 in System Settings > Notifications.

## Row messages

| Message | What happened | What to do |
| --- | --- | --- |
| Sending… | Cue is delivering your prompt | Wait |
| Sent | Codex accepted the prompt, or a `/` or `!` prompt went through | Nothing |
| Queued | Codex holds the prompt until its current turn ends | Nothing |
| Not confirmed. Prompt copied to clipboard. | The session didn't report the prompt in time | Look at the session. If the prompt isn't there, paste it from the clipboard |
| Amp didn't pick it up. Prompt copied to clipboard. | No Amp window claimed the prompt within 5 s | Check that the thread is open in Amp, then Send again |
| Amp isn't answering; is the thread still open? | The plugin's heartbeat stopped | Open the thread in Amp, or run `plugins: reload` |
| Amp refused the prompt: … | Amp rejected the message | Read the reason; the prompt is on the clipboard |
| Prompt is too long for Amp (60 KB at most) | The prompt exceeds the inbox limit | Shorten it, or paste it in Amp directly |
| codex queue: … | Codex rejected the prompt | Read the reason; the prompt is on the clipboard |
| Cue doesn't know where codex is; run install.sh again | `~/.cue/config.json` has no Codex path | Run `./install.sh` |
| Typed but not sent: … The text is in the tab's input box | A check failed after typing, so Cue held back Return | Click Open, check the text, press Return yourself |
| Typed but not sent: the input box doesn't end with this prompt | The typed text didn't land as expected | Click Open and fix the input box by hand |
| Claude is working | The Claude session started working | Wait for idle |
| Claude needs you in the terminal | A permission dialog or MCP question is open | Click Open and answer it |
| Claude's input box isn't on screen (dialog, editor or menu open) | A dialog, menu, picker or the Ctrl+G editor covers the input box | Click Open and close it |
| Claude's vim mode is in NORMAL; press i in the terminal | Claude Code's vim mode would read your text as commands | Press `i` in the tab, then Send again |
| Claude isn't in the foreground (suspended?) | Claude is suspended (Ctrl+Z) or another program owns the terminal | Run `fg` in the tab |
| Claude process is gone | Claude exited | Start a new session; the row disappears within a second |
| Tab no longer runs this session | The tab now runs something else | Nothing; the row clears itself |
| iTerm2 tab is closed | The tab was closed | Nothing; the row clears itself |
| Allow Cue to control iTerm2 in System Settings > Privacy & Security > Automation | macOS blocked Cue from talking to iTerm2 | Turn on iTerm2 under Cue in that settings pane |
| iTerm2 didn't answer in 60 s | iTerm2 hung, or a permission dialog waited too long | Answer any open macOS dialog, then Send again |

Whenever a send fails after delivery started, Cue copies the prompt to the clipboard, so you never lose it.

## Permissions

| Permission | When it's asked | Why |
| --- | --- | --- |
| Automation: control iTerm2 | Your first Send to Claude Code, or first Open | Cue types into tabs and reads their screen through AppleScript |
| Codex hook trust | The first `codex` start after install | Codex runs a hook only after you trust it in `/hooks` |
| Notifications for iTerm2 | iTerm2's first notification | iTerm2 posts the "finished" banners |

Cue is ad-hoc signed, so macOS treats each rebuild as a new app and asks for Automation again after `./install.sh`.

## Troubleshooting

**A running session doesn't appear.** Claude Code and Codex sessions register on their next hook event: send any prompt in the terminal. An Amp thread appears once its window has loaded the plugin: run `plugins: reload` or restart Amp. If the footer says "Hooks missing", run `./install.sh`.

**No Codex rows at all.** Codex skips hooks you haven't trusted. Run `/hooks` in Codex and trust Cue's.

**A Claude row says Working, but Claude is idle.** Esc during a reply, or a denied permission, corrects itself within a second. Esc pressed before Claude writes anything leaves no trace Cue can read, so the row waits: open the popover, and Cue checks the screen of any Claude row that has stayed at Working for 15 seconds.

**A row says Needs you after you answered.** The row updates when the agent's next tool call finishes, or when the turn ends.

**A closed Codex session still shows.** Codex reports a session ended after it sits unopened for 30 minutes; the row leaves then. Starting a new Codex session in the same folder removes it sooner.

**An Amp row disappeared.** Cue hides an Amp row 30 seconds after its window stops reporting: the window closed, or you switched to another thread there. The row comes back when that window shows the thread again.

**Look at the raw data.** Each session is a JSON file in `~/.cue/sessions/`. Hook errors go to `~/.cue/hook.log`.

**Restore your settings.** Each install and uninstall saves `settings.json.cue-backup-YYYYMMDD-HHMMSS` next to `~/.claude/settings.json`, and `hooks.json.cue-backup-…` next to `~/.codex/hooks.json`, keeping the last three of each. Copy one back to undo.

## Limitations

- Claude Code delivery works in iTerm2 tabs and no other terminal.
- A multi-line draft taller than Claude's input box may not fully clear before Cue types.
- Cue reads Claude Code's screen layout, so a Claude Code UI change can make sends refuse until Cue updates. It refuses rather than types blind. See [Development](development.md#when-an-agent-updates).
- Codex rows have no Open, and a prompt sent to a Codex session whose terminal you closed runs in the background.
- Cue shows the Amp thread you're looking at in each Amp window; switching threads moves the row.
