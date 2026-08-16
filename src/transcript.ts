/**
 * Conductor stores each turn's raw Claude Code SDK stream JSON in
 * `session_messages.content`. User-typed prompts are stored as plain text.
 * This turns a row into compact, phone-renderable entries.
 *
 * Classification rule (verified against the whole DB): a JSON frame with
 * `type:"user"` is ALWAYS tool plumbing — every one of them carries
 * tool_result blocks, never the user's own words. Real prompts are the
 * plain-text rows. Never render an SDK user frame as a user bubble.
 */

export interface TranscriptEntry {
	id: string
	rowid: number
	/** Display role: user | assistant | tool | thinking | system */
	role: 'user' | 'assistant' | 'tool' | 'thinking' | 'system'
	/** Human-readable text. For tool rows: the call's description, else the tool name. */
	text: string
	/** Tool name when role === 'tool'. */
	tool?: string
	/** Mono secondary line for tool rows (command, path, pattern, …). */
	detail?: string
	/** True when this row is a failed tool result. */
	error?: boolean
	/**
	 * The tool_use block's own id, set only for the interactive tools (AskUserQuestion /
	 * ExitPlanMode). It is the join key everything downstream leans on: the answer's
	 * tool_result carries the same id, which is how `reads.pendingInput` tells an open
	 * question from an answered one.
	 */
	toolUseId?: string
	/** AskUserQuestion's parsed questions — present only when they parsed cleanly. */
	questions?: PendingQuestion[]
	/** ExitPlanMode's plan markdown, verbatim. */
	plan?: string
	ts: string
	/** True when the message is queued but not yet sent (queue_order set, sent_at null). */
	queued: boolean
	/** Files the user attached on the Mac, parsed out of Conductor's `@⟦name⟧(path)` markup. */
	attachments?: AttachmentRef[]
	/** Conductor's turn id — what groups a turn's entries for duration + per-file summaries. */
	turnId?: string
	/**
	 * Sub-agent nesting, mirrored from the SDK stream: a Task/Agent tool_use
	 * carries its own id as `agentId`, and every frame the sub-agent emits
	 * carries that id as `parentToolUseId` — the join clients group by.
	 * Deliberately not `toolUseId`, which is the interactive-tools join key
	 * `reads.pendingInput` scans; overloading it would risk a Task at the tail
	 * reading as a question.
	 */
	agentId?: string
	parentToolUseId?: string
	/** Lines added by an Edit/Write/MultiEdit tool call (common prefix/suffix trimmed first). */
	adds?: number
	/** Lines removed, same accounting. */
	dels?: number
	/** A clipped unified-style hunk of the change (`-`/`+`/context-prefixed lines). */
	hunk?: string
}

/** One attachment reference: display name + worktree-relative path on disk. */
export interface AttachmentRef {
	name: string
	path: string
}

export interface QuestionOption {
	label: string
	description?: string
}

export interface PendingQuestion {
	question: string
	header?: string
	multiSelect?: boolean
	options: QuestionOption[]
}

interface RawRow {
	rowid: number
	id: string
	role: string | null
	content: string | null
	full_message: string | null
	created_at: string
	sent_at: string | null
	queue_order: number | null
	/** Optional so call sites that don't select it (tail scans) still typecheck. */
	turn_id?: string | null
}

interface SdkBlock {
	type: string
	id?: string
	text?: string
	thinking?: string
	name?: string
	input?: unknown
	content?: unknown
	is_error?: boolean
}

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}…` : s)

const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : undefined)

/** Make tool details repo-relative: absolute worktree paths waste the whole line on a phone. */
function stripWorktree(s: string, worktree: string | null): string {
	if (!worktree) return s
	// Conductor prefixes commands with `cd <worktree>` (newline- or &&-joined) — drop the whole clause.
	if (s.startsWith(`cd ${worktree}`)) s = s.slice(`cd ${worktree}`.length).replace(/^\s*(&&)?\s*/, '')
	return s.replaceAll(`${worktree}/`, '').replaceAll(worktree, '.')
}

/** What a per-edit diff boils down to on the wire. */
interface EditDiff {
	adds: number
	dels: number
	hunk?: string
}

/**
 * Line counts + a clipped hunk for one old→new string pair. Common prefix and
 * suffix lines are trimmed first: an Edit's strings are one contiguous region
 * plus the context Claude needed to anchor it, so what's left after trimming is
 * the actual change — the same accounting behind Conductor's own `+N −M` chips.
 * One context line each side keeps the hunk readable without shipping anchors.
 */
function diffStrings(oldStr: string, newStr: string): EditDiff {
	const a = oldStr.split('\n')
	const b = newStr.split('\n')
	let start = 0
	while (start < a.length && start < b.length && a[start] === b[start]) start++
	let endA = a.length
	let endB = b.length
	while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
		endA--
		endB--
	}
	const dels = endA - start
	const adds = endB - start
	if (!adds && !dels) return { adds, dels }
	const lines: string[] = []
	if (start > 0) lines.push(` ${a[start - 1]}`)
	for (const line of a.slice(start, endA)) lines.push(`-${line}`)
	for (const line of b.slice(start, endB)) lines.push(`+${line}`)
	if (endA < a.length) lines.push(` ${a[endA]}`)
	return { adds, dels, hunk: clipHunk(lines) }
}

/** Hunks ride the 1s poll, so they are clipped hard — the workspace diff view has the rest. */
function clipHunk(lines: string[], maxLines = 60, maxChars = 4000): string {
	const kept =
		lines.length > maxLines ? [...lines.slice(0, maxLines), `… ${lines.length - maxLines} more lines`] : lines
	const joined = kept.join('\n')
	return joined.length > maxChars ? `${joined.slice(0, maxChars)}\n…` : joined
}

/** Raw string, untrimmed — the diff must see real line boundaries, unlike `str()`. */
const raw = (v: unknown) => (typeof v === 'string' ? v : undefined)

/** Change accounting for the file-editing tools, from their own inputs. */
function editDiff(name: string, o: Record<string, unknown>): EditDiff | null {
	if (name === 'Edit') {
		const oldStr = raw(o.old_string)
		const newStr = raw(o.new_string)
		if (oldStr === undefined || newStr === undefined) return null
		return diffStrings(oldStr, newStr)
	}
	if (name === 'Write') {
		const content = raw(o.content)
		if (content === undefined) return null
		// No old content in the input — a Write counts as all-new, like `git diff` on a new file.
		return diffStrings('', content)
	}
	if (name === 'MultiEdit' && Array.isArray(o.edits)) {
		const total: EditDiff = { adds: 0, dels: 0 }
		const hunks: string[] = []
		for (const edit of o.edits as Record<string, unknown>[]) {
			const oldStr = raw(edit?.old_string)
			const newStr = raw(edit?.new_string)
			if (oldStr === undefined || newStr === undefined) continue
			const d = diffStrings(oldStr, newStr)
			total.adds += d.adds
			total.dels += d.dels
			if (d.hunk) hunks.push(d.hunk)
		}
		if (hunks.length) total.hunk = clipHunk(hunks.join('\n \n').split('\n'))
		return total
	}
	if (name === 'NotebookEdit') {
		const source = raw(o.new_source)
		if (source === undefined) return null
		return diffStrings('', source)
	}
	return null
}

/**
 * Mirror Conductor's one-line tool rows: the human description as the title
 * (Bash always has one), the primary input as a mono detail. Tools without a
 * recognizable primary input get the title alone — dumping raw JSON is noise.
 * File-editing tools additionally carry `adds`/`dels` and a clipped hunk, the
 * data behind the Mac-style `+N −M` chips and tap-to-expand diffs.
 */
function summarizeToolUse(
	name: string,
	input: unknown,
	worktree: string | null
): { text: string; detail?: string; adds?: number; dels?: number; hunk?: string } {
	if (!input || typeof input !== 'object') return { text: name }
	const o = input as Record<string, unknown>
	const text = str(o.description) ?? name
	const detail =
		str(o.command) ??
		str(o.file_path) ??
		str(o.notebook_path) ??
		str(o.path) ??
		str(o.pattern) ??
		str(o.url) ??
		str(o.skill) ??
		str(o.prompt)
	const diff = editDiff(name, o)
	const extra = diff ? { adds: diff.adds, dels: diff.dels, ...(diff.hunk ? { hunk: diff.hunk } : {}) } : {}
	if (!detail || detail === text) return { text, ...extra }
	return { text, detail: clip(stripWorktree(detail, worktree).replace(/\s+/g, ' '), 160), ...extra }
}

/**
 * The two tools that stop the turn to wait on the user. Conductor routes questions
 * through its MCP server (`mcp__conductor__AskUserQuestion` — every question frame in
 * this DB), but the built-in name could appear if Claude Code routes it itself.
 */
function interactiveTool(name: string): 'AskUserQuestion' | 'ExitPlanMode' | null {
	if (name === 'ExitPlanMode') return 'ExitPlanMode'
	if (name === 'AskUserQuestion' || /^mcp__.+__AskUserQuestion$/.test(name)) return 'AskUserQuestion'
	return null
}

/**
 * Normalize AskUserQuestion input to labelled options. Conductor's MCP shape carries
 * options as plain strings; the built-in tool uses `{label, description}`. Anything
 * else returns null and the entry falls back to the plain tool row — a question we
 * can't parse must not become a card with wrong choices.
 */
function parseQuestions(input: unknown): PendingQuestion[] | null {
	if (!input || typeof input !== 'object') return null
	const raw = (input as Record<string, unknown>).questions
	if (!Array.isArray(raw) || raw.length === 0) return null
	const out: PendingQuestion[] = []
	for (const q of raw) {
		if (!q || typeof q !== 'object') return null
		const o = q as Record<string, unknown>
		const question = str(o.question)
		if (!question || !Array.isArray(o.options) || o.options.length === 0) return null
		const options: QuestionOption[] = []
		for (const opt of o.options) {
			if (typeof opt === 'string' && opt.trim()) {
				options.push({ label: opt.trim() })
			} else if (opt && typeof opt === 'object' && str((opt as Record<string, unknown>).label)) {
				const l = opt as Record<string, unknown>
				options.push({ label: str(l.label) as string, description: str(l.description) })
			} else {
				return null
			}
		}
		out.push({
			question,
			header: str(o.header),
			multiSelect: typeof o.multiSelect === 'boolean' ? o.multiSelect : undefined,
			options
		})
	}
	return out
}

function resultText(content: unknown): string {
	let s = ''
	if (typeof content === 'string') s = content
	else if (Array.isArray(content)) {
		s = content
			.map(c => (c && typeof c === 'object' && 'text' in c ? String((c as { text: unknown }).text) : ''))
			.join('')
	}
	return clip(s.replace(/<\/?tool_use_error>/g, '').trim(), 400)
}

/**
 * Conductor's attachment references — `@⟦name⟧(percent-encoded path)` — are
 * markup the Mac renders as chips and a phone must not show raw. The bubble
 * text keeps a plain `📎 name` marker; the parsed name + worktree-relative path
 * ride along as an additive field (a stale client just shows the clean text),
 * so a client can grow real thumbnails later — the files live on disk under the
 * worktree's `.context/attachments/`.
 */
const ATTACHMENT_REF = /@⟦([^⟧]*)⟧\(([^)]*)\)/g

function parseAttachmentRefs(content: string): { text: string; attachments?: AttachmentRef[] } {
	const attachments: AttachmentRef[] = []
	const text = content
		.replace(ATTACHMENT_REF, (_, name: string, encoded: string) => {
			let path = encoded
			try {
				path = decodeURIComponent(encoded)
			} catch {}
			attachments.push({ name, path })
			// Removed from the text entirely — clients render `attachments` as
			// chips, and no inline marker survives being shown raw somewhere.
			return ''
		})
		.replace(/[^\S\n]{2,}/g, ' ')
		.trim()
	return attachments.length ? { text, attachments } : { text: content }
}

export function parseMessage(row: RawRow, worktree: string | null = null): TranscriptEntry[] {
	const queued = row.queue_order !== null && row.sent_at === null
	const base = { rowid: row.rowid, ts: row.created_at, queued, ...(row.turn_id ? { turnId: row.turn_id } : {}) }
	const content = row.content ?? ''

	// Plain user prompt (not SDK JSON) — the only source of real user bubbles.
	if (!content.startsWith('{')) {
		if (!content.trim()) return []
		return [{ ...base, id: row.id, role: 'user', ...parseAttachmentRefs(content) }]
	}

	let parsed: {
		type?: string
		subtype?: string
		message?: { content?: SdkBlock[] }
		parent_tool_use_id?: string | null
	}
	try {
		parsed = JSON.parse(content)
	} catch {
		return [{ ...base, id: row.id, role: 'system', text: clip(content, 200) }]
	}

	// Bookkeeping frames: hooks, init, token accounting, end-of-turn results.
	if (parsed.type === 'system' || parsed.type === 'result') return []

	// Turn-level error rows — Conductor renders these as its bordered capsule
	// ("INTERRUPTED BY USER"), and by far the most common is the user pressing
	// Stop. Surface the human content with Conductor's own wording for the known
	// phrase, and set `error` so clients style it as a notice; the raw-dump
	// fallback below stays reserved for frames we *don't* understand.
	if (parsed.type === 'error') {
		const detail = (parsed as { content?: unknown }).content
		const text = typeof detail === 'string' && detail.trim() ? detail.trim() : clip(content, 200)
		return [
			{
				...base,
				id: row.id,
				role: 'system',
				error: true,
				text: text === 'aborted by user' ? 'Interrupted by user' : clip(text, 300)
			}
		]
	}

	const blocks = parsed.message?.content
	if (!Array.isArray(blocks)) {
		if (parsed.type === 'user' || parsed.type === 'assistant') return []
		// Unknown frame shape — keep a dim raw dump so Conductor drift stays visible.
		return [{ ...base, id: row.id, role: 'system', text: clip(content, 200) }]
	}

	// Frames a sub-agent emits carry the spawning Task's tool_use id — attach it
	// to every entry from the frame so clients can nest the run under its agent.
	const parentId = str(parsed.parent_tool_use_id ?? undefined)
	const entries: TranscriptEntry[] = []
	const push = (e: Pick<TranscriptEntry, 'role' | 'text'> & Partial<TranscriptEntry>) =>
		entries.push({
			...base,
			...(parentId ? { parentToolUseId: parentId } : {}),
			...e,
			id: `${row.id}:${entries.length}`
		})

	let pending: string[] = []
	const flush = () => {
		const text = pending.join('\n').trim()
		if (text) push({ role: 'assistant', text })
		pending = []
	}

	for (const b of blocks) {
		if (b.type === 'text' && typeof b.text === 'string') {
			// Text inside an SDK user frame would be injected context, not the user.
			if (parsed.type !== 'user') pending.push(b.text)
		} else if (b.type === 'thinking') {
			flush()
			const text = str(b.thinking) ?? str(b.text)
			if (text) push({ role: 'thinking', text })
		} else if (b.type === 'tool_use' && typeof b.name === 'string') {
			flush()
			const interactive = typeof b.id === 'string' ? interactiveTool(b.name) : null
			const questions = interactive === 'AskUserQuestion' ? parseQuestions(b.input) : null
			const plan =
				interactive === 'ExitPlanMode' && b.input && typeof b.input === 'object'
					? str((b.input as Record<string, unknown>).plan)
					: undefined
			if (interactive === 'AskUserQuestion' && questions) {
				// text carries the question so a stale PWA's plain tool row shows it too.
				push({
					role: 'tool',
					tool: 'AskUserQuestion',
					toolUseId: b.id,
					questions,
					text: questions[0].question
				})
			} else if (interactive === 'ExitPlanMode' && plan) {
				push({ role: 'tool', tool: 'ExitPlanMode', toolUseId: b.id, plan, text: 'Proposed a plan for review' })
			} else {
				// Task/Agent spawns a sub-agent whose frames will reference this id.
				const agentId = (b.name === 'Task' || b.name === 'Agent') && typeof b.id === 'string' ? b.id : undefined
				push({
					role: 'tool',
					tool: b.name,
					...(agentId ? { agentId } : {}),
					...summarizeToolUse(b.name, b.input, worktree)
				})
			}
		} else if (b.type === 'tool_result' && b.is_error) {
			// Successful results are noise on a phone; surface only failures.
			flush()
			push({ role: 'tool', error: true, text: resultText(b.content) || '(tool error)' })
		}
	}
	flush()
	return entries
}
