import type { Workspace } from './types.ts'

export function workspaceLabel(w: Workspace): string {
	return w.workspace_name || w.pr_title || humanizeBranch(w.branch) || w.directory_name || w.id.slice(0, 8)
}

/**
 * Conductor's own workspace title precedence, reproduced:
 *   manual name → PR title → humanized branch → worktree codename → id.
 * `pr_title` is Conductor's cached PR title, present exactly when the workspace
 * has a PR (in-review or done) and cleared back to empty otherwise — so it's the
 * live sidebar title, not a stale value. The branch minus its prefix, sentence-
 * cased, is Conductor's own fallback while a workspace is still in-progress:
 * prefix-agnostic (github_username/custom/none), stripping the first path segment
 * rather than reading Conductor's `branch_prefix_type` setting since the branch
 * already embeds the resolved prefix. directory_name (the worktree codename, e.g.
 * "managua-v2") is a last resort for a branchless workspace.
 */
function humanizeBranch(branch: string | null): string {
	if (!branch) return ''
	const slug = branch.includes('/') ? branch.slice(branch.indexOf('/') + 1) : branch
	const words = slug.replace(/[-_]/g, ' ').trim()
	return words ? words[0].toUpperCase() + words.slice(1) : ''
}

/** Fallback avatar glyph when a repo has no resolvable icon — its leading letter. */
export function repoMonogram(w: Workspace): string {
	const src = w.repo_name || workspaceLabel(w)
	return (src.trim()[0] ?? '?').toUpperCase()
}

/**
 * A workspace Conductor is still provisioning (creating the worktree / running the
 * setup command). Its session may already be idle, but the desktop app dims it and
 * labels it "setting up" — mirror that so a workspace stranded in this state (a known
 * Conductor stuck-state) stays visible here with an honest badge instead of vanishing.
 */
export function isSettingUp(w: Workspace): boolean {
	return w.state === 'setting_up'
}

/** Normalize the many status sources into one of three UI states. */
export type UiStatus = 'working' | 'idle' | 'done'

export function uiStatus(w: Workspace): UiStatus {
	if (w.session_status === 'working') return 'working'
	if (w.derived_status === 'done' || w.manual_status === 'done') return 'done'
	return 'idle'
}

export function statusLabel(w: Workspace): string {
	const s = uiStatus(w)
	if (s === 'working') return 'working'
	if (s === 'done') return 'done'
	return w.session_status || 'idle'
}

const PR_DOT_COLORS: Record<NonNullable<Workspace['pr_status']>, string> = {
	merged: 'var(--color-pr-merged)',
	draft: 'var(--color-pr-draft)',
	conflicts: 'var(--color-pr-conflicts)',
	mergeable: 'var(--color-pr-mergeable)'
}

/**
 * The workspace dot: PR state drives the colour (merged/draft/conflicts/mergeable),
 * everything else falls back to the accent. While the agent is working the dot is
 * drawn as a spinner in that colour instead (`StatusDot`).
 */
export function statusDot(w: Workspace): { color: string; working: boolean } {
	const color = (w.pr_status && PR_DOT_COLORS[w.pr_status]) || 'var(--color-accent)'
	return { color, working: w.session_status === 'working' }
}

/**
 * The workspace lifecycle status the desktop sidebar groups by — a manual
 * override beats the derived one (same precedence as the app).
 */
export function workspaceStatus(w: Workspace): string {
	// A still-provisioning workspace groups on its own — it isn't an active agent run,
	// so folding it into "In progress" (as Conductor does) is the confusion we avoid.
	if (isSettingUp(w)) return 'setting-up'
	return w.manual_status || w.derived_status || 'in-progress'
}

/** Group order matches the desktop sidebar (Done → In review → In progress → Setting up → Backlog). */
// Active work first (setting-up is a brand-new workspace, seconds from
// in-progress), finished work last. Mirrored by Format.swift ▸ statusOrder.
export const STATUS_ORDER = ['setting-up', 'in-progress', 'in-review', 'backlog', 'done', 'canceled']

/**
 * The statuses you can *set*, in the order Conductor's own "Set status" menu lists
 * them. `setting-up` isn't here on purpose: it's a lifecycle state the app derives
 * from a provisioning worktree, not something the menu offers.
 */
export const SETTABLE_STATUSES = ['backlog', 'in-progress', 'in-review', 'done', 'canceled']

export function workspaceStatusLabel(status: string): string {
	const labels: Record<string, string> = {
		done: 'Done',
		'in-review': 'In review',
		'in-progress': 'In progress',
		'setting-up': 'Setting up',
		backlog: 'Backlog',
		canceled: 'Canceled'
	}
	return labels[status] ?? status
}

/** One palette for every status dot, so the header control and the sidebar groups agree. */
export const STATUS_COLORS: Record<string, string> = {
	done: 'var(--color-done)',
	'in-review': 'var(--color-idle)',
	'in-progress': 'var(--color-working)',
	'setting-up': 'var(--color-working)'
}

/** Compact model name: strip the `claude-`/date noise for the phone. */
export function shortModel(model: string | null): string {
	if (!model) return ''
	return model
		.replace(/^claude-/, '')
		.replace(/-\d{8}$/, '')
		.replace(/-latest$/, '')
}

/**
 * One flat line of a prompt, for the jump sheet's rows (components/MessageNav.tsx).
 * The first line that has anything in it — a prompt often opens with a heading or a
 * bullet, and the marker is noise at this size — collapsed and cut to a little past
 * the two lines the row clamps to, so the ellipsis lands where the row does.
 */
export function messagePreview(text: string, max = 120): string {
	const line = text.split('\n').find(l => l.trim()) ?? ''
	const flat = line
		.replace(/^[\s>#*\-+]+/, '')
		.replace(/`/g, '')
		.replace(/\s+/g, ' ')
		.trim()
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat
}

/**
 * A running duration for the working indicator: `12s` → `4m 07s` → `1h 04m 07s`.
 * Padded once a bigger unit is in play so the label stops twitching as it counts,
 * and clamped at zero — the relay's clock and the phone's don't have to agree.
 */
export function elapsed(ms: number): string {
	const total = Math.max(0, Math.floor(ms / 1000))
	const s = total % 60
	const m = Math.floor(total / 60) % 60
	const h = Math.floor(total / 3600)
	const pad = (n: number) => String(n).padStart(2, '0')
	if (h) return `${h}h ${pad(m)}m ${pad(s)}s`
	if (m) return `${m}m ${pad(s)}s`
	return `${s}s`
}

/**
 * When a message was sent, in the phone's own locale and timezone. The date is only
 * spelled out once the message isn't from today — a chat left open overnight would
 * otherwise show two "09:14"s a day apart.
 */
export function messageTime(iso: string): string {
	const at = new Date(iso)
	if (!Number.isFinite(at.getTime())) return ''
	const time = at.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
	const today = new Date()
	if (at.toDateString() === today.toDateString()) return time
	return `${at.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${time}`
}

export function relativeTime(iso: string): string {
	const then = new Date(iso).getTime()
	if (!Number.isFinite(then)) return ''
	const secs = Math.round((Date.now() - then) / 1000)
	if (secs < 45) return 'now'
	if (secs < 90) return '1m'
	const mins = Math.round(secs / 60)
	if (mins < 60) return `${mins}m`
	const hrs = Math.round(mins / 60)
	if (hrs < 24) return `${hrs}h`
	return `${Math.round(hrs / 24)}d`
}
