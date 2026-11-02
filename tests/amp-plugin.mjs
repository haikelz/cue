// Drives the real Amp plugin through a fake PluginAPI and checks the session files it writes, plus a
// `cue send` round trip through its inbox. Run by tests/check.sh:
//   CUE_DIR=<tmp> node tests/amp-plugin.mjs <plugin.ts> <cue binary> <thread a> <thread b>
import { execFile } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const [, , plugin, cue, A, B] = process.argv
// As if this Amp ran inside tmux: the plugin records the pane, so Cue's Open can select it.
process.env.TMUX = '/private/tmp/tmux-501/default,4242,0'
process.env.TMUX_PANE = '%4'
const dir = process.env.CUE_DIR
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const row = (id) => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'sessions', `${id}.json`), 'utf8')) } catch { return null } }
let fails = 0
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  console.log(ok ? `ok    ${name}` : `FAIL  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
  if (!ok) fails++
}
const observable = (value) => {
  const subs = new Set()
  return {
    get current() { return value },
    get: async () => value,
    subscribe: (fn) => { subs.add(fn); return { unsubscribe: () => subs.delete(fn) } },
    emit: (v) => { value = v; subs.forEach((fn) => fn(v)) },
  }
}

const active = observable({ id: A }) // already open when the plugin loads, so no event will announce it
const states = { [A]: observable('running'), [B]: observable('idle') }
const handlers = {}
const appended = []
const { default: register, terminal } = await import(plugin)

// The terminal read from the environment, in the Claude hook's order (SessionTests covers the Swift side).
const where = (env) => Object.entries(terminal(env)).filter(([, v]) => v !== null)
const iterm = { ITERM_SESSION_ID: 'w0t1p0:ABC', TERM_PROGRAM: 'iTerm.app' }
check('the plugin records its iTerm2 tab', where(iterm), [['iterm_session_id', 'ABC']])
check('a WezTerm opened from iTerm2 is WezTerm', where({ ...iterm, TERM_PROGRAM: 'WezTerm', WEZTERM_PANE: '4', WEZTERM_UNIX_SOCKET: '/u/gui-sock-9' }),
  [['wezterm_socket', '/u/gui-sock-9'], ['wezterm_pane', '4']])
check('a kitty opened from WezTerm is kitty', where({ TERM_PROGRAM: 'WezTerm', WEZTERM_PANE: '4', WEZTERM_UNIX_SOCKET: '/u/s', TERM: 'xterm-kitty', KITTY_WINDOW_ID: '2', KITTY_LISTEN_ON: 'unix:/tmp/kitty-7' }),
  [['kitty_socket', 'unix:/tmp/kitty-7'], ['kitty_window', '2']])
check('kitty on TCP keeps no socket', where({ ...iterm, KITTY_WINDOW_ID: '2', KITTY_LISTEN_ON: 'tcp:10.0.0.5:9' }), [['kitty_window', '2']])
check('VS Code opened from iTerm2 is no iTerm2 tab', where({ ITERM_SESSION_ID: 'w0t1p0:ABC', TERM_PROGRAM: 'vscode' }), [])
check('an empty TMUX is no tmux', where({ ...iterm, TMUX: '' }), [['iterm_session_id', 'ABC']])
check('an odd pane id is dropped', where({ TERM_PROGRAM: 'WezTerm', WEZTERM_PANE: '4;x', WEZTERM_UNIX_SOCKET: '/u/s' }), [])
register({
  activeThread: active,
  threads: { get: (id) => ({ state: states[id], appendUserMessage: async (m) => { appended.push(`${id}:${m.content}`) } }) },
  on: (name, fn) => { handlers[name] = fn },
  onDispose: () => {},
  logger: { log: () => {} },
})
await wait(100)
check('plugin attaches to the thread already open', row(A)?.agent, 'amp')
check('plugin seeds the current state', row(A)?.status, 'working')
check('heartbeat is fresh', Date.now() / 1000 - (row(A)?.heartbeat ?? 0) < 2, true)

states[A].emit('awaiting-approval')
await wait(50)
check('awaiting-approval -> needs_you', row(A)?.status, 'needs_you')

states[A].emit('idle')
await handlers['agent.end']({
  thread: { id: A }, status: 'done',
  messages: [{ role: 'user', content: [] }, { role: 'assistant', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: 'All done.\nMore.' }] }],
})
check('the plugin records its tmux pane', [row(A)?.tmux_socket, row(A)?.tmux_pane, row(A)?.iterm_session_id], ['/private/tmp/tmux-501/default', '%4', null])
check('agent.end stores the reply', row(A)?.last_message, 'All done.\nMore.')
check('agent.end stamps finished_at', Date.now() / 1000 - (row(A)?.finished_at ?? 0) < 5, true)
check('idle state -> idle', row(A)?.status, 'idle')

const sent = await new Promise((resolve) =>
  execFile(cue, ['send', A, 'hi from cue'], { env: process.env }, (err, out, errOut) => resolve((out || errOut).trim())))
check('cue send reads the plugin file and delivers', sent, 'delivered')
check('the plugin appended it once', appended, [`${A}:hi from cue`])

active.emit({ id: B })
await wait(100)
check('switching threads removes the old row', row(A), null)
check('and lists the new one', row(B)?.status, 'idle')

process.exit(fails ? 1 : 0)
