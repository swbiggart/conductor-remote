import { execFile } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { promisify } from 'node:util'
import type { Workspace } from './reads.ts'
import { sidecarAvailable, sidecarSendUserMessage } from './sidecar.ts'

const exec = promisify(execFile)

/**
 * One UI operation at a time.
 *
 * Every script below drives Conductor's *shared, single* window — focus a
 * workspace, select a tab, write the composer — so two of them overlapping
 * interleaves their steps and lands a prompt in whatever the other one focused.
 * That is the exact failure the whole fail-closed AX design exists to prevent,
 * and no amount of per-step assertion catches it, because each script's reads
 * are true at the moment it makes them.
 *
 * It was unreachable while every write was one person tapping one button. It
 * stopped being unreachable when the relay grew a first-prompt queue that sends
 * on its own schedule (`firstprompt.ts`), so the queue can now fire while the
 * phone is mid-send. Cheap insurance either way: these run for seconds, the
 * caller is already awaiting, and there is never a real queue of them.
 */
let uiTail: Promise<unknown> = Promise.resolve()
function uiTurn<T>(op: () => Promise<T>): Promise<T> {
	// `.then(op, op)` so a previous failure doesn't skip the next turn.
	const turn = uiTail.then(op, op)
	uiTail = turn.catch(() => undefined)
	return turn
}

export interface SendResult {
	ok: boolean
	strategy: string
	warning?: string
	error?: string
}

/**
 * Where the target chat sits in Conductor's tab strip. `index` is 1-based in
 * `reads.listSessions` order (created_at ASC) — verified to match the strip's
 * left-to-right order — and `title` is the tab label used as a sanity check.
 */
export interface ChatTab {
	index: number
	count: number
	title: string
}

/** Who to deliver a prompt to. `sessionId` is the precise target; `workspace` carries the worktree + focus context. */
export interface SendTarget {
	workspace: Workspace
	sessionId: string | null
	/** Which chat tab to select once the workspace is focused. Omitted → whichever tab is already active. */
	tab?: ChatTab
	/** `sessions.agent_type`, when the caller knows it — the sidecar path addresses the agent by it. */
	agentType?: string | null
}

export interface Actuator {
	readonly name: string
	/** Human-readable note about this strategy's limits, surfaced in the UI. */
	readonly caveat: string
	/** True when delivery is addressed to a specific session (no window-focus dependency). */
	readonly precise: boolean
	/**
	 * `deadline` (epoch ms) is when the caller stops waiting, so a caller retrying
	 * inside one request bounds every attempt with the *same* number. A deadline
	 * rather than a duration because `uiTurn` may queue this run: only the run itself
	 * knows how much of the budget was still left when it finally started.
	 */
	send: (target: SendTarget, text: string, deadline?: number) => Promise<SendResult>
	/** Runtime availability check (e.g. the sidecar socket must be reachable). */
	available?: () => Promise<boolean>
}

/**
 * How long one AppleScript run may take before it's killed.
 *
 * Sized from measurement, not taste. A send that *worked* measured 23.6s end to
 * end on a 30-workspace sidebar — past the 20s ceiling this replaces, which is why
 * ordinary sends were being killed mid-run and reported as "Conductor took too long
 * to respond". The cost is Accessibility round trips, not waiting: activating a
 * backgrounded Conductor and reading the pane cost ~10s cold, and finding the
 * sidebar row to press another ~10s.
 *
 * `openViaDeepLink` took the row scan out of the common path — a whole send now
 * measures ~4s, and focusing alone ~2s against the ~18s the same focus costs when
 * the link is unavailable — so this budget is really the *fallback's*, kept at the
 * size that fallback still needs. A ceiling costs nothing when a send is fast; only
 * a doomed one waits it out, and the caller's own deadline is what bounds that.
 */
export const SEND_ATTEMPT_MS = 28_000

/**
 * A run's own ceiling, taken off the caller's deadline at the moment it actually
 * starts.
 *
 * Both halves matter. `uiTurn` above means a run can sit in the queue behind
 * another write, so a duration computed when it was *requested* would let a queued
 * run overshoot a deadline the caller is still holding a phone open on.
 * `SEND_ATTEMPT_MS` then caps it, because a caller with a minute of budget still
 * shouldn't spend all of it on one doomed run when a retry is the thing that works.
 * The floor keeps a squeezed run honest instead of passing `timeout: 0`, which node
 * reads as "no timeout at all".
 */
function runCeiling(deadline: number): number {
	return Math.max(5_000, Math.min(SEND_ATTEMPT_MS, deadline - Date.now()))
}

/**
 * Failures no amount of retrying will fix, so a caller that retries can stop at
 * once instead of spending a whole budget to arrive at the same sentence.
 *
 * Matched on phrases this file writes itself — the first two from `refusalReason`,
 * the rest from the target checks below — never on macOS's own wording, which we
 * quote verbatim precisely because it drifts. The refusals are the ones a node
 * upgrade causes by silently revoking Accessibility: they fail instantly and
 * identically every time, so making the phone sit through a whole retry budget to
 * be told a permission is missing is worse than being told at once. The rest are
 * malformed targets — no session, no branch — which no attempt can turn into one.
 */
const TERMINAL_ERRORS = [
	'not trusted for Accessibility',
	'blocked the relay from controlling the UI',
	'no session id to target',
	'workspace has no branch to focus'
]

export function retryWontHelp(error: string | undefined): boolean {
	return error !== undefined && TERMINAL_ERRORS.some(phrase => error.includes(phrase))
}

/**
 * A send that failed because the Mac's screen is locked. Deliberately *not* in
 * `TERMINAL_ERRORS`: it isn't terminal (an unlock fixes it) but it also isn't a
 * warm-up cost a retry loop should burn budget on — the caller parks the prompt
 * instead (src/parked.ts) and the queue delivers it when the lock lifts. Matched
 * on the phrase every lock refusal in conductor.applescript starts with; the
 * words are ours, so they can't drift under us the way macOS's can.
 */
export function lockBlocked(error: string | undefined): boolean {
	return (error ?? '').includes('The Mac is locked')
}

/**
 * Node's own read of the lock screen — the same CGSessionCopyCurrentDictionary
 * probe `screenLocked()` in conductor.applescript makes, minus the AppleScript
 * wrapper, so the parked-prompt queue can poll it without spinning up a whole
 * UI script (and without needing Accessibility at all). `null` means the probe
 * itself failed — callers should treat that as "try the send and let it tell
 * you", not as either lock state.
 */
export async function screenLocked(): Promise<boolean | null> {
	// Keep in lockstep with `screenLocked()` in conductor.applescript, traps and
	// all: $.CFBridgingRelease segfaults under JXA, and without the bindFunction
	// rebind deepUnwrap reads the CF dictionary as undefined — a silent "unlocked"
	// on a locked Mac.
	const jxa =
		"ObjC.import('CoreGraphics'); ObjC.bindFunction('CGSessionCopyCurrentDictionary', ['id', []]); const d = ObjC.deepUnwrap($.CGSessionCopyCurrentDictionary()) || {}; d.CGSSessionScreenIsLocked ? 'locked' : 'unlocked'"
	try {
		const { stdout } = await exec('osascript', ['-l', 'JavaScript', '-e', jxa], { timeout: 5_000 })
		const out = stdout.trim()
		if (out === 'locked') return true
		if (out === 'unlocked') return false
		return null
	} catch {
		return null
	}
}

/**
 * Seconds since the human last touched this Mac's keyboard, mouse, or trackpad —
 * or `null` when the probe can't say. Same permission-free JXA channel as
 * `screenLocked` (a C call, not an Apple event), same bindFunction rule: the
 * return here is a plain double, so only the argument types need declaring.
 */
export async function secondsSinceUserInput(): Promise<number | null> {
	const jxa =
		"ObjC.bindFunction('CGEventSourceSecondsSinceLastEventType', ['double', ['int32', 'uint32']]); String($.CGEventSourceSecondsSinceLastEventType(1, 4294967295))"
	try {
		const { stdout } = await exec('osascript', ['-l', 'JavaScript', '-e', jxa], { timeout: 5_000 })
		const n = Number.parseFloat(stdout.trim())
		return Number.isFinite(n) && n >= 0 ? n : null
	} catch {
		return null
	}
}

/**
 * Hold a UI write until the human's hands have been off the Mac for a beat.
 * `uiTurn` serializes *our* writes against each other, but not against the
 * person at the keyboard — and an open menu dies the moment they click (the
 * status write's one observed failure mode is exactly that contention). Waiting
 * a few idle seconds costs the phone little and removes most of it. Fail-open on
 * every edge: a probe that can't answer, a locked screen (no input is coming),
 * or the cap running out all proceed — this is a courtesy, not a gate.
 */
export async function waitForUserIdle(minIdleSeconds: number, capMs: number): Promise<void> {
	const deadline = Date.now() + capMs
	for (;;) {
		const idle = await secondsSinceUserInput()
		if (idle === null || idle >= minIdleSeconds) return
		if (Date.now() >= deadline) return
		await new Promise(resolve => setTimeout(resolve, Math.min(1000, deadline - Date.now())))
	}
}

/**
 * The sidecar IPC path — the precise, per-session write. Delivers straight to
 * `sessionId` over Conductor's own dispatch socket (see sidecar.ts), so it needs
 * no window focus and the app UI reflects the turn correctly.
 *
 * Opt-in (WRITE_STRATEGY=sidecar) because it speaks a private, versioned IPC and
 * hasn't been validated by an automated live send (that would inject a prompt
 * into a running agent). It is the intended default once you've confirmed it on
 * your setup.
 */
export class SidecarActuator implements Actuator {
	readonly name = 'sidecar'
	readonly caveat =
		'Delivered straight to the target session over Conductor’s dispatch socket — precise per-workspace targeting.'
	readonly precise = true

	available(): Promise<boolean> {
		return sidecarAvailable()
	}

	/** `deadline` is ignored — the sidecar is one socket write, with no UI to wait on. */
	async send(target: SendTarget, text: string, _deadline?: number): Promise<SendResult> {
		const sessionId = target.sessionId ?? target.workspace.active_session_id
		if (!sessionId) return { ok: false, strategy: this.name, error: 'no session id to target' }
		if (!target.workspace.worktree) {
			return { ok: false, strategy: this.name, error: 'workspace worktree could not be resolved' }
		}
		try {
			await sidecarSendUserMessage({
				sessionId,
				text,
				cwd: target.workspace.worktree,
				agentType: target.agentType ?? 'claude'
			})
			return { ok: true, strategy: this.name }
		} catch (err) {
			return { ok: false, strategy: this.name, error: err instanceof Error ? err.message : String(err) }
		}
	}
}

/**
 * Every AppleScript handler the write path uses, read from src/conductor.applescript.
 *
 * A sibling asset, so it resolves off this module's own directory rather than
 * `packageRoot()`. The usual rule here (never anchor on `import.meta.dirname/..`) exists
 * because the compiled files sit one level deeper in the tarball, which is exactly
 * why a *sibling* is the one thing that may anchor there: `yarn build:node` copies the
 * script next to the emitted JS, so the same join resolves unbuilt and installed.
 * Read once at import, because a missing copy is a packaging bug and a relay that
 * refuses to boot with an ENOENT naming the path is the loudest way to say so.
 */
const CONDUCTOR_HANDLERS = readFileSync(path.join(import.meta.dirname, 'conductor.applescript'), 'utf8').trimEnd()

/**
 * The URL scheme Conductor registers, which is per *release channel*: the
 * production build answers `conductor://`, the pre-release ones
 * `conductor-alpha://`, `conductor-beta://`, `conductor-dev://` and friends.
 * Everything else in this file addresses `application "Conductor"` by name, so
 * production is the only channel the write path works against anyway — the
 * override exists so a channel build needs a variable rather than a patch.
 */
const CONDUCTOR_SCHEME = process.env.RELAY_CONDUCTOR_SCHEME || 'conductor'

/**
 * Conductor's own link to a workspace, and optionally to one chat inside it —
 * exactly what its sidebar row menu copies under "Copy link" (Cmd+Shift+C).
 *
 * `conductor://workspace?id=<workspace>&session=<chat>` is the shape that works,
 * and the near misses all fail *badly*, so this is the one place that builds it:
 * the parameters sit behind a real `?` (unlike the create-workspace links, which
 * are flat after the scheme), the workspace id is `id` rather than `workspace`,
 * and `workspace` must be the URL's **host** — `conductor:///workspace/<id>`,
 * with the id in the path, falls through to the flat-parameter parser and
 * **creates a new workspace in the first repo**. A path-shaped link with the
 * right host (`conductor://workspace/<id>`) is merely ignored.
 *
 * `session` is optional and names a chat by `sessions.id`, the same id the relay
 * already serves; omitted, Conductor opens whichever tab that workspace had.
 * A hidden chat (`sessions.is_hidden`) has no tab, and Conductor keeps the
 * workspace's current one rather than reporting anything, so the caller's own
 * tab assertion is still what catches it.
 *
 * The https form Conductor copies for sharing —
 * `https://app.conductor.build/workspace/<id>?session=<chat>` — reaches the same
 * handler, but only once macOS has decided to hand it to the app; the desktop
 * build declares no associated domain, so a browser gets it first. Locally the
 * scheme form is the one that always lands.
 */
function workspaceLink(workspaceId: string, sessionId: string | null): string {
	const params = new URLSearchParams({ id: workspaceId })
	if (sessionId) params.set('session', sessionId)
	return `${CONDUCTOR_SCHEME}://workspace?${params.toString()}`
}

/** Conductor's command palette matches workspaces by branch — its unique key. A
 * looser query (directory name) can match a command like unarchive, so prefer
 * branch and only fall back when it's absent. */
function focusQuery(ws: Workspace): string {
	return ws.branch || ws.workspace_name || ws.directory_name || ''
}

/**
 * Every title Conductor might be showing for this workspace in the sidebar
 * (its precedence: manual name → PR title → humanized branch → codename). The
 * sidebar press tries each and requires a unique row; a miss just means we fall
 * back to the palette, so this doesn't have to reproduce the precedence exactly.
 */
function sidebarTitles(ws: Workspace): string[] {
	const slug = ws.branch?.includes('/') ? ws.branch.slice(ws.branch.indexOf('/') + 1) : ws.branch
	const humanized = slug?.replace(/[-_]/g, ' ').trim()
	return [
		ws.workspace_name,
		ws.pr_title,
		humanized ? humanized[0].toUpperCase() + humanized.slice(1) : '',
		ws.directory_name
	].filter((t): t is string => Boolean(t))
}

/**
 * May the actuator restart Conductor to force a window into existence?
 *
 * Restarting is the only lever left when a running, windowless Conductor ignores
 * both `reopen` and a Dock click — it is single-window and single-instance, so
 * there is nothing else to press. It is also the one step here that can destroy
 * work: quitting takes any agent mid-turn down with it. "Nothing is running" is a
 * fact only the read side has, so server.ts wires this to a DB read rather than
 * writes.ts guessing. Unset → never restart, which is the safe default for any
 * caller that hasn't opted in.
 */
let restartGuard: (() => boolean) | null = null

export function setRestartGuard(guard: (() => boolean) | null): void {
	restartGuard = guard
}

function restartAllowed(): boolean {
	try {
		return restartGuard?.() ?? false
	} catch {
		return false
	}
}

/** The target rides in on the environment, like RELAY_WS_QUERY, to dodge AppleScript escaping. */
function targetEnv(target: SendTarget): Record<string, string> {
	return {
		RELAY_ALLOW_RESTART: restartAllowed() ? '1' : '',
		RELAY_TAB_INDEX: String(target.tab?.index ?? 0),
		RELAY_TAB_COUNT: String(target.tab?.count ?? 0),
		RELAY_TAB_TITLE: target.tab?.title ?? '',
		RELAY_WS_BRANCH: target.workspace.branch ?? '',
		RELAY_WS_REPO: target.workspace.repo_name ?? '',
		RELAY_WS_QUERY: focusQuery(target.workspace),
		RELAY_WS_LINK: workspaceLink(target.workspace.id, target.sessionId),
		RELAY_WS_TITLES: sidebarTitles(target.workspace).join('\n')
	}
}

/** osascript echoes the whole failing script back; keep just the reason for the phone. */
function osaError(err: unknown): string {
	const raw = err instanceof Error ? err.message : String(err)
	// A timeout kill carries no execution error at all — its first line is
	// "Command failed: osascript -e" plus the whole script, which is useless here.
	if (err && typeof err === 'object' && 'killed' in err && (err as { killed?: boolean }).killed) {
		return 'Conductor took too long to respond'
	}
	return raw.match(/execution error: (.+?) \(-?\d+\)/)?.[1] ?? raw.split('\n')[0]
}

/**
 * Drives Conductor's real send path via macOS Accessibility (AppleScript): focus
 * the target workspace, paste the prompt, press Enter. Uses whatever model /
 * permission mode the session already has (zero risk of altering the agent),
 * which is why it's the default.
 *
 * Precise targeting comes from opening Conductor's own workspace link first
 * (`conductor://workspace?id=…&session=…`, see `workspaceLink`) and then
 * confirming the pane and the chat tab through Accessibility (see
 * src/conductor.applescript), so the prompt lands in the right session regardless
 * of what was focused. The link is public and id-addressed; the AX reads only
 * check it, and pressing the sidebar row or the command palette remains the
 * fallback for a Conductor that doesn't answer it.
 */
export class AppleScriptActuator implements Actuator {
	readonly name = 'applescript'
	readonly caveat = "Opens the target workspace's own Conductor link, then confirms the chat tab before sending."
	readonly precise = true

	async send(target: SendTarget, text: string, deadline = Date.now() + SEND_ATTEMPT_MS): Promise<SendResult> {
		// Try the silent path first: when Conductor already shows the target chat, the
		// whole send is AX reads and presses, which work on a background app — no
		// activate, no stolen focus (see silentSend in conductor.applescript). Anything
		// short of that falls into the activation ladder: open the workspace's own
		// link, confirm its chat tab, fill the composer, send. Filling is an
		// Accessibility write (no keystrokes, no clipboard); the clipboard paste is
		// kept only as a fallback, and stashes/restores around it. The final press
		// prefers the composer's send button and keeps Enter for a build whose button
		// isn't AX-mapped.
		const script = `
${CONDUCTOR_HANDLERS}

set promptText to my normalizeNewlines(do shell script "cat" & " " & quoted form of (system attribute "RELAY_PROMPT_FILE"))
if not (my silentSend(promptText)) then
	my activateConductor()
	my focusWorkspace()
	my selectChatTab()
	if not (my fillComposer(promptText)) then
		set savedClipboard to the clipboard
		my pasteComposer()
		delay 0.1
		set the clipboard to savedClipboard
	end if
	if not (my pressSendButton()) then
		tell application "System Events"
			key code 36
		end tell
	end if
end if
`.trim()
		// Pass the prompt via a temp file + env to avoid AppleScript string escaping.
		const os = await import('node:os')
		const fs = await import('node:fs/promises')
		const path = await import('node:path')
		const tmp = path.join(os.tmpdir(), `relay-prompt-${process.pid}-${Date.now()}.txt`)
		await fs.writeFile(tmp, text, 'utf8')
		try {
			await uiTurn(() =>
				exec('osascript', ['-e', script], {
					env: { ...process.env, RELAY_PROMPT_FILE: tmp, ...targetEnv(target) },
					timeout: runCeiling(deadline)
				})
			)
			return { ok: true, strategy: this.name }
		} catch (err) {
			return { ok: false, strategy: this.name, error: osaError(err) }
		} finally {
			await fs.rm(tmp, { force: true }).catch(() => undefined)
		}
	}
}

/**
 * Conductor stores the effort level as `sessions.claude_effort_level`, but the
 * composer button is labelled with the human name and *cycles* through them in
 * this order. Both directions are needed: the label to press toward, and the DB
 * value to confirm against.
 */
export const EFFORT_LABELS: Record<string, string> = {
	low: 'Low',
	medium: 'Medium',
	high: 'High',
	xhigh: 'Extra high',
	max: 'Max',
	ultracode: 'Ultracode'
}

/** What a phone can change about the agent before (or instead of) sending a prompt. */
export interface AgentOptions {
	/** A `claude_effort_level` value (low…ultracode), not the UI label. */
	effort?: string
	plan?: boolean
	/** Fast mode exposes no readable state, so pass `true` only when it must flip. */
	toggleFast?: boolean
	/** The model picker's menu label, e.g. "Opus 5" or "Sonnet 4.6". */
	model?: string
	/**
	 * The model's *id* (`sessions.model`), when the caller resolved `model` from
	 * the catalog — lets the DB confirm the exact value instead of trusting the
	 * menu label alone. Ignored by the UI drive itself.
	 */
	modelId?: string
}

/**
 * Apply agent settings to a specific chat: focus its workspace and tab (same
 * verified path as a send), then drive the composer's own controls. Every step
 * confirms the control landed on the requested value and errors out otherwise,
 * so a half-applied change is reported rather than assumed.
 */
export async function setAgentOptions(target: SendTarget, opts: AgentOptions): Promise<SendResult> {
	if (opts.effort && !EFFORT_LABELS[opts.effort]) {
		return { ok: false, strategy: 'applescript', error: `unknown effort level ${opts.effort}` }
	}
	const script = `
${CONDUCTOR_HANDLERS}

my activateConductor()
my focusWorkspace()
my selectChatTab()
my applyAgentOptions()
return "ok"`.trim()
	try {
		await uiTurn(() =>
			exec('osascript', ['-e', script], {
				env: {
					...process.env,
					...targetEnv(target),
					RELAY_SET_EFFORT: opts.effort ? EFFORT_LABELS[opts.effort] : '',
					RELAY_SET_PLAN: opts.plan === undefined ? '' : opts.plan ? '1' : '0',
					RELAY_SET_FAST: opts.toggleFast ? '1' : '',
					RELAY_SET_MODEL: opts.model ?? ''
				},
				timeout: SEND_ATTEMPT_MS
			})
		)
		return { ok: true, strategy: 'applescript' }
	} catch (err) {
		return { ok: false, strategy: 'applescript', error: osaError(err) }
	}
}

/** What the phone pressed on a question/plan card (see `answerSession`). */
export interface AnswerAction {
	kind: 'question' | 'plan'
	/** Option labels to press, in order (one for single-select). Ignored for plan approval. */
	labels: string[]
}

/**
 * Approve-button labels tried in order on the plan card. Nothing documents the
 * card's AX shape, so a miss errors with every pressable name it *did* see — the
 * failure is the discovery dump. A rename here is a one-line edit.
 */
const APPROVE_LABELS = ['Approve plan', 'Approve']

/**
 * Answer a pending question or approve a pending plan in one chat: same verified
 * focus path as a send, then press the card's own buttons by their exact labels.
 * The caller (server.ts) validates the labels against the live pending read
 * before this runs and confirms afterwards against the transcript receipt — this
 * function only ever presses a unique match, and errors in words otherwise.
 */
export async function answerSession(target: SendTarget, action: AnswerAction): Promise<SendResult> {
	const script = `
${CONDUCTOR_HANDLERS}

my activateConductor()
my focusWorkspace()
my selectChatTab()
${action.kind === 'plan' ? 'my pressApprovePlan()' : 'my pressAnswerOption()'}
return "ok"`.trim()
	try {
		await uiTurn(() =>
			exec('osascript', ['-e', script], {
				env: {
					...process.env,
					...targetEnv(target),
					RELAY_ANSWER_LABELS: action.labels.join('\n'),
					RELAY_APPROVE_LABELS: APPROVE_LABELS.join('\n')
				},
				timeout: SEND_ATTEMPT_MS
			})
		)
		return { ok: true, strategy: 'applescript' }
	} catch (err) {
		return { ok: false, strategy: 'applescript', error: osaError(err) }
	}
}

/**
 * The workspace statuses Conductor's sidebar groups by, mapped from the value it
 * stores in `workspaces.manual_status` to the label on its own menu. `canceled`
 * is on the menu but has never been written in this DB, so it's the one spelling
 * here that is taken from the UI rather than confirmed against stored data — a
 * mismatch surfaces as a failed confirmation naming what Conductor actually wrote.
 */
export const WORKSPACE_STATUS_LABELS: Record<string, string> = {
	backlog: 'Backlog',
	'in-progress': 'In progress',
	'in-review': 'In review',
	done: 'Done',
	canceled: 'Canceled'
}

/**
 * Move a workspace between the sidebar's status groups — the thing a merged PR
 * that Conductor never linked can't do for itself.
 *
 * In the common case this never changes what's on screen: it right-clicks the
 * workspace's *row* (AXShowMenu) and works the menu, so the workspace you were
 * reading stays open. A row hidden by a collapsed sidebar section is no longer a
 * dead end: `revealSidebarRow` escalates — the workspace's own deep link first
 * (which does change the screen; failing was the alternative), then expanding
 * the section header the row should sit under, restored afterward.
 * RELAY_WS_GROUP carries the group to try first, from the same status the
 * sidebar groups by.
 */
export async function setWorkspaceStatus(workspace: Workspace, status: string): Promise<SendResult> {
	const label = WORKSPACE_STATUS_LABELS[status]
	if (!label) return { ok: false, strategy: 'applescript', error: `unknown status ${status}` }
	const currentGroup = WORKSPACE_STATUS_LABELS[workspace.manual_status ?? workspace.derived_status ?? ''] ?? ''
	const script = `
${CONDUCTOR_HANDLERS}

my activateConductor()
my setWorkspaceStatus()
return "ok"`.trim()
	try {
		await uiTurn(() =>
			exec('osascript', ['-e', script], {
				env: {
					...process.env,
					...targetEnv({ workspace, sessionId: null }),
					RELAY_SET_STATUS: label,
					RELAY_WS_GROUP: currentGroup
				},
				timeout: 35000
			})
		)
		return { ok: true, strategy: 'applescript' }
	} catch (err) {
		return { ok: false, strategy: 'applescript', error: osaError(err) }
	}
}

/** The model labels Conductor is currently offering, read off the live picker. */
export async function listAgentModels(target: SendTarget): Promise<{ ok: boolean; models?: string[]; error?: string }> {
	const script = `
${CONDUCTOR_HANDLERS}

my activateConductor()
my focusWorkspace()
my selectChatTab()
return my listModels()`.trim()
	try {
		const { stdout } = await uiTurn(() =>
			exec('osascript', ['-e', script], {
				env: { ...process.env, ...targetEnv(target) },
				timeout: SEND_ATTEMPT_MS
			})
		)
		const models = stdout
			.split('\n')
			.map(s => s.trim())
			.filter(Boolean)
		return { ok: true, models }
	} catch (err) {
		return { ok: false, error: osaError(err) }
	}
}

/**
 * Create a *new workspace*, optionally with a first prompt, via Conductor's
 * deep-link scheme (conductor.build/docs/reference/deep-links).
 *
 * This is the one write here that touches no UI at all: no Accessibility, no
 * keystrokes, no focus dependency — macOS hands the URL to Conductor and it
 * creates the worktree. Nothing to rebreak on an update, unlike every other
 * path in this file.
 *
 * Three things the scheme dictates:
 *  - Parameters sit *flat* after the scheme (`conductor://prompt=…&path=…`), not
 *    behind a `?`, and every value must be URL-encoded — which is also what stops
 *    a prompt containing `&path=` from redirecting the workspace to another repo.
 *  - **An unmatched (or absent) `path` silently falls back to the first repo**, so
 *    the caller resolves a real `root_path` first rather than trusting a name.
 *  - **`prompt` is optional**: a bare `conductor://path=…` opens an empty
 *    workspace, same as Conductor's own New workspace. That form isn't in the
 *    docs (every documented route carries a prompt) but is verified against the
 *    live app — so if it ever stops working, this is the line to suspect.
 *
 * The link is fire-and-forget: it reports that Conductor was *handed* the URL,
 * never that a workspace appeared. The caller watches the DB for that.
 */
export async function createWorkspace(prompt: string, repoPath: string | null): Promise<SendResult> {
	if (!prompt.trim() && !repoPath) {
		return { ok: false, strategy: 'deeplink', error: 'a new workspace needs a repo or a first prompt' }
	}
	const query = [
		prompt.trim() ? `prompt=${encodeURIComponent(prompt)}` : '',
		repoPath ? `path=${encodeURIComponent(repoPath)}` : ''
	]
		.filter(Boolean)
		.join('&')
	try {
		// Serialized with the AX writes: creating a workspace pulls Conductor forward and
		// switches which one is showing, which is precisely what a concurrent send assumes.
		await uiTurn(() => exec('open', [`${CONDUCTOR_SCHEME}://${query}`], { timeout: 15000 }))
		return { ok: true, strategy: 'deeplink' }
	} catch (err) {
		return { ok: false, strategy: 'deeplink', error: osaError(err) }
	}
}

/**
 * Open a new chat in the target workspace — Conductor's "New chat, same files"
 * (Cmd+T). Focuses the workspace first (its own link, see `workspaceLink`), then
 * Cmd+T; the caller detects the freshly-created session id from the DB.
 */
export async function newChat(workspace: Workspace): Promise<SendResult> {
	if (!focusQuery(workspace)) return { ok: false, strategy: 'applescript', error: 'workspace has no branch to focus' }
	const script = `
${CONDUCTOR_HANDLERS}

my activateConductor()
my focusWorkspace()
tell application "System Events"
	keystroke "t" using {command down}
end tell`.trim()
	try {
		// Shares the focus path with a send, so it needs the same ceiling: 15s was under
		// the cost of activating a cold Conductor and finding the row on its own.
		await uiTurn(() =>
			exec('osascript', ['-e', script], {
				env: { ...process.env, ...targetEnv({ workspace, sessionId: null }) },
				timeout: SEND_ATTEMPT_MS
			})
		)
		return { ok: true, strategy: 'applescript' }
	} catch (err) {
		return { ok: false, strategy: 'applescript', error: osaError(err) }
	}
}

export type WriteStrategy = 'applescript' | 'sidecar'

export function pickActuator(strategy: WriteStrategy): Actuator {
	return strategy === 'sidecar' ? new SidecarActuator() : new AppleScriptActuator()
}

/** Effective actuator description for the UI, factoring in runtime availability. */
export async function describeActuator(
	actuator: Actuator
): Promise<{ name: string; caveat: string; precise: boolean; available: boolean }> {
	const available = actuator.available ? await actuator.available().catch(() => false) : true
	return { name: actuator.name, caveat: actuator.caveat, precise: actuator.precise, available }
}
