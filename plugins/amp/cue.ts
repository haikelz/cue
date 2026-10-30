// Cue's Amp plugin. Lists the thread you have open in Amp in the Cue menubar app, and delivers the
// prompts you send from Cue. Installed to ~/.config/amp/plugins/cue.ts by install.sh.
import type { PluginAPI } from '@ampcode/plugin'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

export const description = 'Cue: shows this Amp thread in the Cue menubar app and delivers the prompts you send from it.'

const root = process.env.CUE_DIR || path.join(os.homedir(), '.cue')
const THREAD = /^T-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MESSAGE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$/
const now = () => Date.now() / 1000

/** Temp file plus rename, so Cue never reads half a file. */
function writeFile(file: string, text: string) {
	fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
	const tmp = `${file}.${process.pid}.tmp`
	fs.writeFileSync(tmp, text, { mode: 0o600 })
	fs.renameSync(tmp, file)
}

/** The tty of the Amp process above this plugin, for notifications. The plugin has none of its own. */
function ampTTY(): string | null {
	try {
		let pid = process.ppid
		for (let i = 0; i < 3 && pid > 1; i++) {
			const [ppid, tty] = execFileSync('/bin/ps', ['-o', 'ppid=,tty=', '-p', String(pid)], { encoding: 'utf8' }).trim().split(/\s+/)
			if (/^ttys\d+$/.test(tty)) return `/dev/${tty}`
			pid = Number(ppid)
		}
	} catch {}
	return null
}

/**
 * Posts "‹project› finished: ‹reply›": iTerm2 turns OSC 9 into a notification. Non-blocking, so a
 * paused terminal can't stall the plugin; a failure costs only the banner.
 */
function notify(tty: string | null, text: string) {
	if (!tty) return
	try {
		const fd = fs.openSync(tty, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK | fs.constants.O_NOCTTY)
		try {
			fs.writeSync(fd, `\x1b]9;${text.replace(/[\x00-\x1f\x7f-\x9f]/g, ' ').slice(0, 180)}\x07`)
		} finally {
			fs.closeSync(fd)
		}
	} catch {}
}

/**
 * Delivers each prompt Cue dropped in this thread's inbox, at most once. A rename claims a file, so
 * when two Amp windows show the thread, one wins. Cue reads the receipt, or the error, to report back.
 * A file older than 10 s lost its sender (Cue withdraws after 5 s), so it's dropped, never sent late.
 */
export async function drainInbox(dir: string, append: (content: string) => Promise<void>) {
	const me = process.getuid?.()
	const folder = fs.lstatSync(dir, { throwIfNoEntry: false })
	if (!folder?.isDirectory() || folder.uid !== me) return
	for (const name of fs.readdirSync(dir)) {
		if (!MESSAGE.test(name)) continue
		const file = path.join(dir, name)
		const st = fs.lstatSync(file, { throwIfNoEntry: false })
		if (!st?.isFile() || st.uid !== me || (st.mode & 0o777) !== 0o600 || st.size > 65_536) continue
		if (Date.now() - st.mtimeMs > 10_000) {
			fs.rmSync(file, { force: true })
			continue
		}
		const claimed = `${file}.${process.pid}.claimed`
		try {
			fs.renameSync(file, claimed)
		} catch {
			continue // another Amp process, or Cue withdrawing it, got there first
		}
		const id = name.slice(0, -'.json'.length)
		let error: string | null = null
		try {
			const { content } = JSON.parse(fs.readFileSync(claimed, 'utf8'))
			if (typeof content !== 'string' || !content.trim()) throw new Error('empty prompt')
			await append(content)
		} catch (err) {
			error = String(err).slice(0, 300)
		} finally {
			fs.rmSync(claimed, { force: true })
		}
		writeFile(path.join(dir, 'receipts', error === null ? id : `${id}.error`), error ?? '')
	}
}

export default function (amp: PluginAPI) {
	// Nothing starts at load: `amp plugins list` loads plugins in a short-lived process.
	// Work begins when an Amp window shows a thread, and moves with the thread you switch to.
	type Attached = { id: string; session: Record<string, unknown>; stop: () => void }
	let current: Attached | null = null
	let tty: string | null | undefined // looked up on first attach, not at load

	const sessionFile = (id: string) => path.join(root, 'sessions', `${id}.json`)

	function attach(id: string): Attached {
		if (tty === undefined) tty = ampTTY()
		const file = sessionFile(id)
		const tab = process.env.ITERM_SESSION_ID?.split(':').pop()
		const session: Record<string, unknown> = {
			session_id: id,
			agent: 'amp',
			cwd: process.env.PWD || process.cwd(),
			status: 'idle',
			last_message: null,
			updated_at: now(),
			pid: process.ppid, // the owning Amp process; another window on this thread won't delete our file
			iterm_session_id: process.env.TMUX ? null : tab || null,
			heartbeat: now(),
		}
		const save = () => {
			session.heartbeat = now()
			writeFile(file, JSON.stringify(session))
		}
		const apply = (st: string) => {
			const status = st === 'running' ? 'working' : st === 'awaiting-approval' ? 'needs_you' : 'idle'
			if (status !== session.status) {
				session.status = status
				session.updated_at = now()
			}
			if (st === 'error') session.last_message = 'Error'
			save()
		}
		const thread = amp.threads.get(id)
		const state = thread.state.subscribe(apply)
		thread.state.get().then(apply, () => {}) // subscribers see later values; seed the current one
		let beats = 0
		let draining = false
		const timer = setInterval(() => {
			if (++beats % 5 === 0) save() // heartbeat every 5 s; Cue hides a row after 30 s of silence
			if (draining) return
			draining = true
			drainInbox(path.join(root, 'inbox', id), (content) => thread.appendUserMessage({ type: 'user-message', content }))
				.catch((err) => amp.logger.log('cue inbox', String(err)))
				.finally(() => (draining = false))
		}, 1000)
		save()
		return {
			id,
			session,
			stop: () => {
				state.unsubscribe()
				clearInterval(timer)
				try {
					if (JSON.parse(fs.readFileSync(file, 'utf8')).pid === process.ppid) fs.rmSync(file, { force: true })
				} catch {}
			},
		}
	}

	const follow = (thread: { id: string } | null) => {
		if (thread?.id === current?.id) return
		current?.stop()
		current = thread && THREAD.test(thread.id) ? attach(thread.id) : null
	}
	amp.activeThread.subscribe(follow)
	follow(amp.activeThread.current) // subscribers see later values; seed the open thread

	amp.on('agent.end', async (event) => {
		const attached = current
		if (!attached || event.thread.id !== attached.id) return
		const reply = [...event.messages].reverse().find((m) => m.role === 'assistant')
		const text = (reply?.content ?? [])
			.map((block: { type: string; text?: string }) => (block.type === 'text' ? block.text ?? '' : ''))
			.join('')
			.trim()
		const done = event.status === 'done'
		attached.session.last_message = done ? text.slice(0, 500) : event.status === 'error' ? 'Error' : 'Cancelled'
		writeFile(sessionFile(attached.id), JSON.stringify(attached.session))
		if (event.status !== 'cancelled') {
			const project = path.basename(String(attached.session.cwd))
			notify(tty ?? null, `${project} ${done ? 'finished' : 'stopped'}: ${done ? text.split('\n')[0] : 'Error'}`)
		}
	})

	amp.onDispose(() => current?.stop())
}
