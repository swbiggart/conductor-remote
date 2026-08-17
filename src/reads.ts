import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import type { ConductorDb } from './db.ts'
import type { FirstPrompt } from './firstprompt.ts'
import { describeRepoIcon, type RepoIcon, type ResolvedIcon, resolveRepoIcon } from './icons.ts'
import type { ParkedPrompt } from './parked.ts'
import { type PendingQuestion, parseMessage, type TranscriptEntry } from './transcript.ts'

export interface WorkspaceRow {
	id: string
	directory_name: string | null
	workspace_name: string | null
	branch: string | null
	pr_title: string | null
	derived_status: string | null
	manual_status: string | null
	/** Conductor lifecycle: 'ready' (usable) or 'setting_up' (worktree/session still provisioning). */
	state: string | null
	created_at: string
	updated_at: string
	pinned_at: string | null
	active_session_id: string | null
	intended_target_branch: string | null
	repo_name: string | null
	repo_root: string | null
	repo_icon: string | null
	remote_url: string | null
	default_branch: string | null
	session_status: string | null
	session_title: string | null
	model: string | null
	context_used_percent: number | null
}

/**
 * A chat Conductor has flagged unread, with the activity that flagged it.
 *
 * `at` is the session's own `updated_at`, which tracks its last message. The phone
 * only ever compares it against a mark taken from this same column, so SQLite's
 * `YYYY-MM-DD HH:MM:SS` (UTC, and lexically ordered) needs no parsing — don't
 * reformat it into an ISO string that no longer matches what `listSessions` serves.
 */
export interface UnreadSession {
	id: string
	at: string
}

/** A repo Conductor can create workspaces in (see `Reads.listRepos`). */
export interface RepoRow {
	name: string
	/** Absolute checkout path — the `path=` value a create-workspace deep link needs. */
	root_path: string | null
	default_branch: string | null
	icon: RepoIcon | null
}

export interface SessionRow {
	id: string
	status: string | null
	title: string | null
	model: string | null
	/** 'plan' when the chat is in plan mode, else 'default'. */
	permission_mode: string | null
	/** low | medium | high | xhigh | max | ultracode (null for non-Claude agents). */
	claude_effort_level: string | null
	/** 1 when Conductor's "Fast" toggle is on. */
	fast_mode: number | null
	/** claude | codex | cursor | acp — the agent family `model` belongs to. */
	agent_type: string | null
	context_used_percent: number | null
	unread_count: number | null
	created_at: string
	updated_at: string
	last_user_message_at: string | null
	/** When the turn now in flight was dispatched — see `listSessions`. Null before Conductor's first queued turn. */
	turn_started_at: string | null
}

/** GitHub PR state of a workspace's branch, attached best-effort by src/pr.ts. */
export type PrStatus = 'merged' | 'draft' | 'conflicts' | 'mergeable'

/** A question or plan the agent is stopped on, derived from the transcript tail (see `pendingInput`). */
export interface PendingInput {
	kind: 'question' | 'plan'
	toolUseId: string
	/** rowid of the tool_use row — stable identity for the card and the answer validation. */
	rowid: number
	questions?: PendingQuestion[]
	plan?: string
	ts: string
}

/** One chat's live status, with enough context to name it in a notification (see src/notify.ts). */
export interface SessionState {
	sessionId: string
	workspaceId: string
	/** 'working' | 'idle' | 'error' — Conductor's own live agent status. */
	status: string | null
	/** The sidebar title of the owning workspace. */
	workspaceTitle: string
	repoName: string | null
	/** Chat tab title, when the workspace has more than one. */
	sessionTitle: string | null
}

export interface Workspace extends WorkspaceRow {
	/** Chats in this workspace Conductor flags unread — empty for most (see `unreadSessions`). */
	unread_sessions: UnreadSession[]
	/** Absolute path to the git worktree on disk, or null if it can't be resolved. */
	worktree: string | null
	baseBranch: string
	/** How to render the repo's sidebar avatar; null → letter monogram. See `describeRepoIcon`. */
	icon: RepoIcon | null
	/** PR state of `branch` (null when unknown / no PR / not GitHub); set by src/pr.ts. */
	pr_status?: PrStatus | null
	/** Open/closed PR number for `branch`, when one exists; set by src/pr.ts. */
	pr_number?: number | null
	/** PR web URL for the `#N ↗` link; set by src/pr.ts. */
	pr_url?: string | null
	/** A first prompt the relay hasn't delivered yet; set by src/server.ts from src/firstprompt.ts. */
	pending_prompt?: FirstPrompt | null
	/** Prompts parked for the lock screen, each naming its chat; set by src/server.ts from src/parked.ts. */
	parked_prompts?: ParkedPrompt[]
}

const worktreeCache = new Map<string, string | null>()

/**
 * Conductor's sidebar title for a workspace: manual name → PR title → humanized
 * branch → worktree codename → id. Deliberately a second copy of the web's
 * `workspaceLabel` (web/src/lib/format.ts, where the precedence is documented) —
 * the relay can't import from the Vite root, and a notification that names a
 * workspace differently from the list it came from is worse than the duplication.
 */
export function workspaceTitle(w: {
	id: string
	workspace_name: string | null
	pr_title: string | null
	branch: string | null
	directory_name: string | null
}): string {
	const branch = w.branch ?? ''
	const slug = branch.includes('/') ? branch.slice(branch.indexOf('/') + 1) : branch
	const words = slug.replace(/[-_]/g, ' ').trim()
	const humanized = words ? words[0].toUpperCase() + words.slice(1) : ''
	return w.workspace_name || w.pr_title || humanized || w.directory_name || w.id.slice(0, 8)
}

/**
 * Resolve a workspace's worktree path. Conductor lays worktrees out as
 * `<workspacesRoot>/<repoName>/<directoryName>`, but we verify against
 * `git worktree list` (matched by branch) so a layout change can't silently
 * point us at the wrong tree.
 */
function resolveWorktree(
	workspacesRoot: string,
	repoName: string | null,
	directoryName: string | null,
	branch: string | null,
	repoRoot: string | null
): string | null {
	if (repoName && directoryName) {
		const guess = path.join(workspacesRoot, repoName, directoryName)
		if (fs.existsSync(path.join(guess, '.git'))) return guess
	}
	if (!(repoRoot && branch)) return null
	const cacheKey = repoRoot
	let listing = worktreeCache.get(cacheKey)
	if (listing === undefined) {
		try {
			listing = execFileSync('git', ['-C', repoRoot, 'worktree', 'list', '--porcelain'], {
				encoding: 'utf8',
				timeout: 5000
			})
		} catch {
			listing = null
		}
		worktreeCache.set(cacheKey, listing)
	}
	if (!listing) return null
	// Porcelain: blocks of "worktree <path>" / "branch refs/heads/<name>"
	const blocks = listing.split('\n\n')
	for (const block of blocks) {
		if (block.includes(`refs/heads/${branch}`)) {
			const m = block.match(/^worktree (.+)$/m)
			if (m) return m[1]
		}
	}
	return null
}

export class Reads {
	private readonly db: ConductorDb
	private readonly workspacesRoot: string

	constructor(db: ConductorDb, workspacesRoot: string) {
		this.db = db
		this.workspacesRoot = workspacesRoot
	}

	/**
	 * Unread chats, grouped by workspace. `workspaces.unread` is a **dead column** —
	 * Conductor still declares it (and its migration still says "when 1, the workspace
	 * should be marked visually as unread") but writes 0 on every row: 0 of 1691 are
	 * non-zero on this Mac, which is why the sidebar's bold/badge never once fired.
	 * The live flag is per session, and it *is* a flag — `unread_count` is only ever
	 * 0 or 1 — so what's worth counting is how many chats have news, not the column.
	 */
	private unreadSessions(): Map<string, UnreadSession[]> {
		const rows = this.db.query<{ workspace_id: string | null; id: string; updated_at: string }>(
			`SELECT workspace_id, id, updated_at
			 FROM sessions
			 WHERE COALESCE(unread_count, 0) > 0 AND COALESCE(is_hidden, 0) = 0`
		)
		const byWorkspace = new Map<string, UnreadSession[]>()
		for (const r of rows) {
			if (!r.workspace_id) continue
			const list = byWorkspace.get(r.workspace_id)
			if (list) list.push({ id: r.id, at: r.updated_at })
			else byWorkspace.set(r.workspace_id, [{ id: r.id, at: r.updated_at }])
		}
		return byWorkspace
	}

	listWorkspaces(): Workspace[] {
		const rows = this.db.query<WorkspaceRow>(
			`SELECT w.id, w.directory_name, w.workspace_name, w.branch, w.pr_title, w.derived_status, w.manual_status,
			        w.state, w.created_at, w.updated_at, w.pinned_at, w.active_session_id, w.intended_target_branch,
			        r.name AS repo_name, r.root_path AS repo_root, r.icon AS repo_icon,
			        r.remote_url AS remote_url, r.default_branch AS default_branch,
			        s.status AS session_status, s.title AS session_title, s.model AS model,
			        s.context_used_percent AS context_used_percent
			 FROM workspaces w
			 LEFT JOIN repos r ON r.id = w.repository_id
			 LEFT JOIN sessions s ON s.id = w.active_session_id
			 WHERE w.state IN ('ready', 'setting_up')
			 ORDER BY (w.pinned_at IS NULL), w.updated_at DESC`
		)
		const unread = this.unreadSessions()
		return rows.map(r => ({
			...r,
			unread_sessions: unread.get(r.id) ?? [],
			worktree: resolveWorktree(this.workspacesRoot, r.repo_name, r.directory_name, r.branch, r.repo_root),
			baseBranch: r.intended_target_branch || r.default_branch || 'main',
			icon: describeRepoIcon({ icon: r.repo_icon, repoRoot: r.repo_root, remoteUrl: r.remote_url })
		}))
	}

	getWorkspace(id: string): Workspace | null {
		return this.listWorkspaces().find(w => w.id === id) ?? null
	}

	/**
	 * The repos Conductor knows about, in its own sidebar order. `root_path` is
	 * what a `conductor://…&path=` deep link needs to pick the target repo — with
	 * no path Conductor silently falls back to the *first* repo.
	 */
	listRepos(): RepoRow[] {
		const rows = this.db.query<{
			name: string
			root_path: string | null
			default_branch: string | null
			icon: string | null
			remote_url: string | null
		}>(
			`SELECT name, root_path, default_branch, icon, remote_url
			 FROM repos
			 WHERE COALESCE(hidden, 0) = 0
			 ORDER BY (display_order IS NULL), display_order, name`
		)
		return rows.map(r => ({
			name: r.name,
			root_path: r.root_path,
			default_branch: r.default_branch,
			icon: describeRepoIcon({ icon: r.icon, repoRoot: r.root_path, remoteUrl: r.remote_url })
		}))
	}

	/** Resolve a repo's icon by its name (the sidebar avatar) — null if the repo or icon is unknown. */
	resolveRepoIcon(repoName: string): ResolvedIcon | null {
		const rows = this.db.query<{ root_path: string | null }>('SELECT root_path FROM repos WHERE name = ? LIMIT 1', [
			repoName
		])
		const root = rows[0]?.root_path
		return root ? resolveRepoIcon(root) : null
	}

	listSessions(workspaceId: string): SessionRow[] {
		// created_at ASC keeps tab order stable (matches the desktop app) instead of jumping on activity.
		//
		// `turn_started_at` is when the current answer began, which is NOT
		// `last_user_message_at`: a message typed while the agent is already working is
		// *steering* — it joins the running turn rather than starting one, and the phone's
		// elapsed timer must not restart on it. Conductor separates the two itself.
		// `session_messages.queue_order` is set exactly on the messages that head a turn
		// (verified over the whole DB from May 2026, when the column appeared — older rows
		// are all NULL, so a long-dormant chat reports null here and simply shows no timer),
		// and `sent_at` is when that head was dispatched, so a prompt that sat in the queue
		// times from when it actually ran, not from when it was typed. Still-queued heads
		// have `sent_at` NULL and are skipped, which is why a queued message can't blip the
		// timer while the previous answer is still going. Served straight off
		// idx_session_messages_sent_at(session_id, sent_at) — measured free at this poll rate.
		return this.db.query<SessionRow>(
			`SELECT s.id, s.status, s.title, s.model, s.permission_mode, s.claude_effort_level, s.fast_mode, s.agent_type,
			        s.context_used_percent, s.unread_count,
			        s.created_at, s.updated_at, s.last_user_message_at,
			        (SELECT MAX(m.sent_at) FROM session_messages m
			          WHERE m.session_id = s.id AND m.queue_order IS NOT NULL AND m.sent_at IS NOT NULL) AS turn_started_at
			 FROM sessions s
			 WHERE s.workspace_id = ? AND COALESCE(s.is_hidden, 0) = 0
			 ORDER BY s.created_at ASC`,
			[workspaceId]
		)
	}

	/**
	 * Every live chat's status, across all workspaces — what the notifier watches for
	 * transitions. Unlike `listWorkspaces` this is not limited to the *active* session:
	 * a background tab finishing its turn is exactly the thing you want told about.
	 * `setting_up` workspaces are excluded; their chat isn't the user's turn yet.
	 */
	listSessionStates(): SessionState[] {
		const rows = this.db.query<{
			id: string
			status: string | null
			title: string | null
			workspace_id: string
			workspace_name: string | null
			pr_title: string | null
			branch: string | null
			directory_name: string | null
			repo_name: string | null
			tab_count: number
		}>(
			`SELECT s.id, s.status, s.title, s.workspace_id,
			        w.workspace_name, w.pr_title, w.branch, w.directory_name,
			        r.name AS repo_name,
			        (SELECT COUNT(*) FROM sessions t WHERE t.workspace_id = w.id AND COALESCE(t.is_hidden, 0) = 0) AS tab_count
			 FROM sessions s
			 JOIN workspaces w ON w.id = s.workspace_id
			 LEFT JOIN repos r ON r.id = w.repository_id
			 WHERE w.state = 'ready' AND COALESCE(s.is_hidden, 0) = 0`
		)
		return rows.map(r => ({
			sessionId: r.id,
			workspaceId: r.workspace_id,
			status: r.status,
			workspaceTitle: workspaceTitle({ ...r, id: r.workspace_id }),
			repoName: r.repo_name,
			// A single-tab workspace's chat title is just the workspace again — only name it when it disambiguates.
			sessionTitle: r.tab_count > 1 ? r.title : null
		}))
	}

	/**
	 * The last thing the agent actually said in a chat — the body of a "finished"
	 * notification. Reads the tail rather than the whole transcript, and runs the
	 * same parser the phone renders with, so what lands on the lock screen is the
	 * text that will be at the bottom of the chat when it's opened.
	 */
	lastAssistantText(sessionId: string): string | null {
		const rows = this.db.query<{
			rowid: number
			id: string
			role: string | null
			content: string | null
			full_message: string | null
			created_at: string
			sent_at: string | null
			queue_order: number | null
		}>(
			`SELECT rowid, id, role, content, full_message, created_at, sent_at, queue_order
			 FROM session_messages
			 WHERE session_id = ?
			 ORDER BY rowid DESC
			 LIMIT 20`,
			[sessionId]
		)
		// Rows come back newest-first; the last assistant text is the first one found.
		for (const row of rows) {
			const entries = parseMessage(row, null)
			for (let i = entries.length - 1; i >= 0; i--) {
				if (entries[i].role === 'assistant' && entries[i].text.trim()) return entries[i].text.trim()
			}
		}
		return null
	}

	/**
	 * Is this chat stopped on a question or a plan waiting for the user? Derived
	 * entirely from the transcript tail — a session whose newest meaningful entry is
	 * an interactive tool_use with no tool_result carrying the same id *is* the
	 * flag. Deliberately no `sessions.status` gate: an interactive tool's result can
	 * only come from a human, so an unanswered one at the tail means the agent is
	 * blocked no matter what status says — and status lies here anyway. A plan
	 * awaiting approval sits at `needs_plan_response`, a fourth value the schema
	 * surveys never saw because it exists only while a plan is actually waiting;
	 * the `=== 'idle'` gate this replaces returned null for exactly the sessions
	 * the card was built for (live-observed 2026-08-17). The supersede scan below
	 * plus the receipt check are what keep mid-turn rows out. Riding the per-chat
	 * messages poll (1s, open chat only), so the tail scan stays cheap.
	 */
	pendingInput(sessionId: string): PendingInput | null {
		const rows = this.db.query<{
			rowid: number
			id: string
			role: string | null
			content: string | null
			full_message: string | null
			created_at: string
			sent_at: string | null
			queue_order: number | null
		}>(
			`SELECT rowid, id, role, content, full_message, created_at, sent_at, queue_order
			 FROM session_messages
			 WHERE session_id = ?
			 ORDER BY rowid DESC
			 LIMIT 30`,
			[sessionId]
		)
		// Newest first: the first meaningful entry decides. A question buried under 30+
		// bookkeeping rows fails closed to "nothing pending" — no card beats a stale card.
		for (const row of rows) {
			const entries = parseMessage(row, null)
			for (let i = entries.length - 1; i >= 0; i--) {
				const e = entries[i]
				if (e.toolUseId && (e.tool === 'AskUserQuestion' || e.tool === 'ExitPlanMode')) {
					if (this.answerRecorded(sessionId, e.toolUseId, row.rowid)) return null
					return {
						kind: e.tool === 'ExitPlanMode' ? 'plan' : 'question',
						toolUseId: e.toolUseId,
						rowid: row.rowid,
						questions: e.questions,
						plan: e.plan,
						ts: e.ts
					}
				}
				// Anything the user or agent did after a question supersedes it — including a
				// failed tool_result, which is what a rejected plan leaves behind.
				if (e.role === 'user' || e.role === 'assistant' || e.role === 'tool') return null
			}
		}
		return null
	}

	/**
	 * Has anything referencing this tool_use id landed after the question row? The
	 * answer's tool_result frame carries the same id, so a plain substring check is
	 * the drift-proof receipt — no dependence on Claude Code's result wording.
	 */
	answerRecorded(sessionId: string, toolUseId: string, sinceRowid: number): boolean {
		const rows = this.db.query<{ found: number }>(
			`SELECT 1 AS found FROM session_messages
			 WHERE session_id = ? AND rowid > ? AND content LIKE '%' || ? || '%'
			 LIMIT 1`,
			[sessionId, sinceRowid, toolUseId]
		)
		return rows.length > 0
	}

	/** Session → worktree path, cached: it's stable for a session's lifetime and polled every tick. */
	private readonly worktreeBySession = new Map<string, string | null>()

	/** The session's worktree on disk — the base transcript-referenced relative paths resolve against. */
	worktreeFor(sessionId: string): string | null {
		return this.sessionWorktree(sessionId)
	}

	private sessionWorktree(sessionId: string): string | null {
		const cached = this.worktreeBySession.get(sessionId)
		if (cached !== undefined) return cached
		const rows = this.db.query<{
			directory_name: string | null
			branch: string | null
			repo_name: string | null
			repo_root: string | null
		}>(
			`SELECT w.directory_name, w.branch, r.name AS repo_name, r.root_path AS repo_root
			 FROM sessions s
			 JOIN workspaces w ON w.id = s.workspace_id
			 LEFT JOIN repos r ON r.id = w.repository_id
			 WHERE s.id = ? LIMIT 1`,
			[sessionId]
		)
		const r = rows[0]
		const worktree = r
			? resolveWorktree(this.workspacesRoot, r.repo_name, r.directory_name, r.branch, r.repo_root)
			: null
		this.worktreeBySession.set(sessionId, worktree)
		return worktree
	}

	/** Incremental transcript fetch. `afterRowid` is the cursor from a prior call. */
	getMessages(sessionId: string, afterRowid = 0): { entries: TranscriptEntry[]; cursor: number } {
		const rows = this.db.query<{
			rowid: number
			id: string
			role: string | null
			content: string | null
			full_message: string | null
			created_at: string
			sent_at: string | null
			queue_order: number | null
			turn_id: string | null
		}>(
			`SELECT rowid, id, role, content, full_message, created_at, sent_at, queue_order, turn_id
			 FROM session_messages
			 WHERE session_id = ? AND rowid > ?
			 ORDER BY rowid ASC`,
			[sessionId, afterRowid]
		)
		const worktree = this.sessionWorktree(sessionId)
		const entries: TranscriptEntry[] = []
		let cursor = afterRowid
		for (const row of rows) {
			cursor = row.rowid
			entries.push(...parseMessage(row, worktree))
		}
		return { entries, cursor }
	}
}
