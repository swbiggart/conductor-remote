import { useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, FileText, Image as ImageIcon, Loader2 } from 'lucide-react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useSendPrompt, useTranscript } from '../hooks.ts'
import { client } from '../lib/api.ts'
import { cn } from '../lib/cn.ts'
import { elapsed, messagePreview, messageTime } from '../lib/format.ts'
import type { PendingPrompt, TranscriptEntry } from '../lib/types.ts'
import type { PendingMessage } from '../store.ts'
import { useApp } from '../store.ts'
import { InputRequest } from './InputRequest.tsx'
import { Markdown } from './Markdown.tsx'
import { MessageNav } from './MessageNav.tsx'
import { Empty, Spinner } from './ui.tsx'

export function Transcript({
	sessionId,
	workspaceId,
	working,
	workingSince,
	queued
}: {
	sessionId: string | null
	workspaceId: string
	working?: boolean
	/** Epoch ms the current answer started (see SessionView) — the elapsed timer's origin. */
	workingSince?: number | null
	/** The relay's undelivered first prompt for this workspace (src/firstprompt.ts). */
	queued?: PendingPrompt | null
}) {
	const { entries, pending: inputPending, loading, error } = useTranscript(sessionId)
	const liveSteps = useApp(s => s.view.liveSteps)
	const pending = useApp(s => s.pending)
	const removePending = useApp(s => s.removePending)
	const sendPrompt = useSendPrompt()
	const queryClient = useQueryClient()
	const scroller = useRef<HTMLDivElement>(null)
	const atBottom = useRef(true)

	// The relay owns the entry, so dropping it is a request, not a local edit. A
	// parked prompt (lock screen) belongs to its chat, a first prompt to its workspace.
	const dismiss = async (q: PendingPrompt) => {
		await (q.sessionId ? client.dismissParked(q.sessionId) : client.dismissPrompt(q.workspaceId)).catch(() => undefined)
		queryClient.invalidateQueries({ queryKey: ['state'] })
	}

	// This session's optimistic prompts, hiding any still-`sending` one whose text
	// has already arrived as a real user row — the confirmed bubble replaces it.
	const delivered = new Set(entries.filter(e => e.role === 'user').map(e => e.text.trim()))
	const mine = pending.filter(p => p.sessionId === sessionId)
	const visiblePending = mine.filter(p => !(p.status === 'sending' && delivered.has(p.text.trim())))

	// The relay keeps the entry until delivery is *confirmed*, and its own send lands as
	// a real user row up to a poll before /api/state drops it — so hide the queued bubble
	// as soon as the text shows up in the chat (or in a bubble of our own), or it doubles.
	const queuedText = queued?.text.trim() || null
	const showQueued =
		queuedText && !delivered.has(queuedText) && !mine.some(p => p.text.trim() === queuedText) ? queued : null

	// Purge confirmed optimistic bubbles from the store once the real row shows (the
	// send hook also purges on a timer; this catches the fast path so nothing lingers).
	useEffect(() => {
		const seen = new Set(entries.filter(e => e.role === 'user').map(e => e.text.trim()))
		for (const p of pending) {
			if (p.sessionId === sessionId && p.status === 'sending' && seen.has(p.text.trim())) removePending(p.id)
		}
	}, [entries, pending, sessionId, removePending])

	// Track whether the user is pinned to the bottom before new content lands.
	const onScroll = () => {
		const el = scroller.current
		if (!el) return
		atBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 120
	}

	// biome-ignore lint/correctness/useExhaustiveDependencies: fire on new entries, a new optimistic bubble, an arriving question/plan card, or the working indicator toggling to keep the view pinned
	useLayoutEffect(() => {
		const el = scroller.current
		if (el && atBottom.current) el.scrollTop = el.scrollHeight
	}, [entries, visiblePending.length, working, inputPending?.toolUseId])

	// biome-ignore lint/correctness/useExhaustiveDependencies: reset scroll intent when switching sessions
	useEffect(() => {
		atBottom.current = true
	}, [sessionId])

	// The scroller shrinks when the software keyboard opens (useVisualViewportHeight
	// resizes the whole column) and when the composer autogrows. Without this, its
	// scrollTop stays put and the newest messages slide out of view behind the
	// composer — re-pin instead, for anyone who was reading the bottom.
	useEffect(() => {
		const el = scroller.current
		if (!el) return
		const ro = new ResizeObserver(() => {
			if (atBottom.current) el.scrollTop = el.scrollHeight
		})
		ro.observe(el)
		return () => ro.disconnect()
	}, [])

	// A workspace still setting up has no chat yet — but if its first prompt is
	// waiting on that setup, showing it beats an empty pane that looks like a loss.
	if (!sessionId && !showQueued) return <Empty>No active session in this workspace.</Empty>

	const empty = entries.length === 0 && visiblePending.length === 0 && !showQueued && !inputPending

	return (
		<div className="relative flex min-h-0 min-w-0 flex-1">
			<div ref={scroller} onScroll={onScroll} className="min-w-0 flex-1 overflow-y-auto overflow-x-hidden px-3 py-3">
				{loading && empty ? (
					<Spinner label="Loading transcript…" />
				) : error && empty ? (
					<Empty>{error}</Empty>
				) : empty && !working ? (
					<Empty>No messages yet.</Empty>
				) : (
					<div className="flex min-w-0 flex-col gap-2.5">
						{buildRows(entries, working ?? false, liveSteps).map(row =>
							row.kind === 'steps' ? (
								<StepGroup key={row.key} entries={row.entries} sessionId={sessionId} />
							) : row.kind === 'turn' ? (
								<TurnSummaryRow key={row.key} files={row.files} seconds={row.seconds} />
							) : (
								<Entry key={row.key} e={row.e} sessionId={sessionId} />
							)
						)}
						{visiblePending.map(p => (
							<PendingEntry
								key={p.id}
								p={p}
								onRetry={() =>
									sendPrompt({ id: p.id, sessionId: p.sessionId, workspaceId: p.workspaceId, text: p.text })
								}
								onDismiss={() => removePending(p.id)}
							/>
						))}
						{showQueued ? (
							<QueuedEntry
								queued={showQueued}
								onRetry={sessionId ? () => sendPrompt({ sessionId, workspaceId, text: showQueued.text }) : undefined}
								onDismiss={() => dismiss(showQueued)}
							/>
						) : null}
						{/* A sibling of the entry list, never inside groupSteps — a question the
						    agent is waiting on must not fold into a closed "N steps" disclosure. */}
						{inputPending && sessionId ? (
							<InputRequest
								key={inputPending.toolUseId}
								pending={inputPending}
								sessionId={sessionId}
								workspaceId={workspaceId}
							/>
						) : null}
						{working ? <WorkingIndicator since={workingSince} /> : null}
					</div>
				)}
			</div>
			{/* Reads the transcript's own DOM (`data-user-msg`), so it needs no entry list of its own. */}
			<MessageNav scroller={scroller} />
		</div>
	)
}

type Row =
	| { kind: 'entry'; key: string; e: TranscriptEntry }
	| { kind: 'steps'; key: string; entries: TranscriptEntry[] }
	| { kind: 'turn'; key: string; files: TurnFile[]; seconds: number | null }

interface TurnFile {
	name: string
	adds: number
	dels: number
}

const rowKey = (e: TranscriptEntry) => `${e.rowid}-${e.id}`

/** Both timestamp shapes the relay serves: ISO (with ms) and SQLite's UTC-sans-Z. */
const parseTs = (ts: string): number | null => {
	const ms = Date.parse(ts.includes('T') ? ts : `${ts.replace(' ', 'T')}Z`)
	return Number.isNaN(ms) ? null : ms
}

/**
 * Fold each run of the agent's own work (thinking + tool calls) between two
 * spoken messages into one collapsible group — a turn is mostly plumbing, and on
 * a phone that plumbing buries the prose. A run of one stays inline: wrapping a
 * single row in a disclosure hides it without saving anything. While the agent
 * is working, the trailing run stays as individual live rows (the Mac's
 * behaviour) and folds only once the turn ends — group identity is the first
 * row's key either way, so the collapse doesn't lose expansion state elsewhere.
 */
function groupSteps(entries: TranscriptEntry[], unfoldTrailing = false): Row[] {
	const rows: Row[] = []
	let run: TranscriptEntry[] = []
	const flush = (asIndividual = false) => {
		if (!asIndividual && run.length > 1) rows.push({ kind: 'steps', key: `steps-${rowKey(run[0])}`, entries: run })
		else for (const e of run) rows.push({ kind: 'entry', key: rowKey(e), e })
		run = []
	}
	for (const e of entries) {
		if (e.role === 'tool' || e.role === 'thinking') {
			run.push(e)
			continue
		}
		flush()
		rows.push({ kind: 'entry', key: rowKey(e), e })
	}
	flush(unfoldTrailing)
	return rows
}

/**
 * The full row stream: entries segmented into turns (`turnId`, NULL on
 * pre-May-2026 rows — those merge into one summary-less span), steps folded per
 * turn, and a Mac-style summary row — duration plus per-file `+N −M` chips —
 * after each *completed* turn that edited files. The trailing turn's summary
 * always waits for the turn to end; whether its steps stream unfolded meanwhile
 * is the `liveSteps` setting (Connect sheet, collapsed by default).
 */
function buildRows(entries: TranscriptEntry[], working: boolean, liveSteps = false): Row[] {
	const turns: TranscriptEntry[][] = []
	let lastTurnId: string | undefined
	for (const e of entries) {
		if (!turns.length || (e.turnId && lastTurnId && e.turnId !== lastTurnId)) turns.push([])
		turns[turns.length - 1].push(e)
		if (e.turnId) lastTurnId = e.turnId
	}
	const rows: Row[] = []
	turns.forEach((turn, i) => {
		const trailing = i === turns.length - 1
		rows.push(...groupSteps(turn, trailing && working && liveSteps))
		if (trailing && working) return
		const summary = turnSummary(turn)
		if (summary) rows.push(summary)
	})
	return rows
}

/** Per-file totals + elapsed for one turn, or null when it edited nothing. */
function turnSummary(turn: TranscriptEntry[]): Row | null {
	const edits = turn.filter(e => e.adds !== undefined || e.dels !== undefined)
	if (!edits.length || !turn.some(e => e.turnId)) return null
	const byFile = new Map<string, TurnFile>()
	for (const e of edits) {
		const name = basename(e.detail ?? '') || 'files'
		const file = byFile.get(name) ?? { name, adds: 0, dels: 0 }
		file.adds += e.adds ?? 0
		file.dels += e.dels ?? 0
		byFile.set(name, file)
	}
	const first = parseTs(turn[0].ts)
	const last = parseTs(turn[turn.length - 1].ts)
	const seconds = first !== null && last !== null && last > first ? Math.round((last - first) / 1000) : null
	return { kind: 'turn', key: `turn-${rowKey(turn[0])}`, files: [...byFile.values()], seconds }
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|heic)$/i
const basename = (p: string) => p.split('/').pop() ?? p

/** "6m 59s" — coarse, no live ticking (this row only exists for finished turns). */
function turnDuration(seconds: number): string {
	if (seconds < 60) return `${seconds}s`
	const m = Math.floor(seconds / 60)
	if (m < 60) return `${m}m ${seconds % 60}s`
	return `${Math.floor(m / 60)}h ${m % 60}m`
}

/** The end-of-turn receipt: how long it ran, which files it touched, how much. */
function TurnSummaryRow({ files, seconds }: { files: TurnFile[]; seconds: number | null }) {
	return (
		<div className="flex flex-wrap items-center gap-1.5 px-0.5 text-[11px] text-faint">
			{seconds !== null ? <span className="shrink-0">{turnDuration(seconds)}</span> : null}
			{files.map(f => (
				<span
					key={f.name}
					className="flex items-center gap-1.5 rounded-md border border-border-soft bg-surface/60 px-2 py-0.5 font-mono"
				>
					<span className="max-w-40 truncate text-muted">{f.name}</span>
					{f.adds ? <span className="text-add">+{f.adds}</span> : null}
					{f.dels ? <span className="text-del">−{f.dels}</span> : null}
				</span>
			))}
		</div>
	)
}

/**
 * The collapsed run of steps. Closed by default, but the header carries the last
 * step's label — which keeps updating while the agent works — so the group reads
 * as live activity without being opened, and any tool failure inside is counted
 * on the header rather than hidden behind it.
 */
function StepGroup({ entries, sessionId }: { entries: TranscriptEntry[]; sessionId: string | null }) {
	const failed = entries.filter(e => e.error).length
	const last = entries[entries.length - 1]
	const lastLabel = last.role === 'thinking' ? 'Thinking' : last.text
	return (
		<details className="group/steps min-w-0 overflow-hidden rounded-xl border border-border-soft bg-surface/40">
			<summary className="flex cursor-pointer select-none list-none items-baseline gap-2 overflow-hidden whitespace-nowrap px-3 py-1.5 [&::-webkit-details-marker]:hidden">
				<span className="shrink-0 font-mono text-[11px] text-faint transition-transform group-open/steps:rotate-90">
					▸
				</span>
				<span className="shrink-0 text-[12.5px] text-muted">{entries.length} steps</span>
				<span className="min-w-0 flex-1 truncate text-[11px] text-faint group-open/steps:invisible">{lastLabel}</span>
				{failed ? <span className="shrink-0 text-[11px] text-del">{failed} failed</span> : null}
			</summary>
			<div className="flex min-w-0 flex-col gap-2.5 border-t border-border-soft px-2 py-2.5">
				{entries.map(e => (
					<Entry key={rowKey(e)} e={e} sessionId={sessionId} />
				))}
			</div>
		</details>
	)
}

/**
 * A chip naming a transcript-referenced image, which taps open in a lightbox.
 * Fetched with the auth header (an `<img src>` can't carry one) through
 * `GET /api/sessions/:id/file` — the endpoint only serves paths this chat's
 * transcript actually references, so the chip can't be aimed anywhere else.
 */
function ImageChip({ sessionId, path, name }: { sessionId: string | null; path: string; name: string }) {
	const token = useApp(s => s.token)
	const [src, setSrc] = useState<string | null>(null)
	const [failed, setFailed] = useState(false)
	const open = async () => {
		if (src || !sessionId) return
		try {
			const r = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/file?path=${encodeURIComponent(path)}`, {
				headers: { Authorization: `Bearer ${token ?? ''}` }
			})
			if (!r.ok) throw new Error(String(r.status))
			setSrc(URL.createObjectURL(await r.blob()))
		} catch {
			setFailed(true)
		}
	}
	return (
		<>
			<button
				type="button"
				onClick={open}
				className="flex max-w-full shrink-0 items-center gap-1.5 rounded-md border border-border-soft bg-surface/80 px-2 py-0.5 font-mono text-[11px] text-muted active:bg-surface-2"
			>
				<ImageIcon size={11} className={cn('shrink-0', failed ? 'text-del' : 'text-add')} />
				<span className="truncate">{name}</span>
			</button>
			{src ? (
				<button
					type="button"
					aria-label="Close image"
					onClick={() => setSrc(null)}
					className="fixed inset-0 z-50 flex cursor-default items-center justify-center bg-black/80 p-4"
				>
					<img src={src} alt={name} className="max-h-full max-w-full rounded-lg object-contain" />
				</button>
			) : null}
		</>
	)
}

/**
 * A prompt still with the relay: the workspace's first prompt waiting on setup, or
 * one parked for the lock screen (`reason` says which). Not a `PendingMessage` —
 * it outlives this app being open, and delivery belongs to the relay.
 *
 * `failed` is the relay saying it gave up, so the text is offered back rather than
 * lost: Retry sends it as an ordinary prompt (which also clears the entry), Dismiss
 * drops it. A first prompt is still pre-filled in Conductor's composer either way.
 */
function QueuedEntry({
	queued,
	onRetry,
	onDismiss
}: {
	queued: PendingPrompt
	onRetry?: () => void
	onDismiss: () => void
}) {
	const failed = queued.status === 'failed'
	return (
		<div className="flex flex-col items-end gap-1" data-user-msg={messagePreview(queued.text)} data-msg-state="queued">
			<Bubble className={cn('max-w-[85%] bg-accent-soft text-text opacity-60', failed && 'border border-del/40')}>
				<Markdown>{queued.text}</Markdown>
			</Bubble>
			{failed ? (
				<div className="flex items-center gap-2 pr-1 text-[11px] text-del">
					<AlertTriangle size={11} className="shrink-0" />
					<span className="max-w-[55vw] truncate">{queued.error || 'Didn’t send'}</span>
					{onRetry ? (
						<button type="button" onClick={onRetry} className="font-semibold underline underline-offset-2">
							Retry
						</button>
					) : null}
					<button type="button" onClick={onDismiss} className="text-faint underline underline-offset-2">
						Dismiss
					</button>
				</div>
			) : (
				<span className="flex items-center gap-1 pr-1 text-[11px] text-faint">
					<Loader2 size={11} className="animate-spin" />
					{queued.reason ?? 'Sends when the workspace is ready'}
				</span>
			)}
		</div>
	)
}

/** An optimistic user prompt: greyed while `sending`, or a red bubble with Retry/Dismiss on failure. */
function PendingEntry({ p, onRetry, onDismiss }: { p: PendingMessage; onRetry: () => void; onDismiss: () => void }) {
	if (p.status === 'error') {
		return (
			<div className="flex flex-col items-end gap-1" data-user-msg={messagePreview(p.text)} data-msg-state="failed">
				<Bubble className="max-w-[85%] border border-del/40 bg-accent-soft text-text">
					<Markdown>{p.text}</Markdown>
				</Bubble>
				<div className="flex items-center gap-2 pr-1 text-[11px] text-del">
					<AlertTriangle size={11} className="shrink-0" />
					<span className="max-w-[55vw] truncate">{p.error || 'Didn’t send'}</span>
					<button type="button" onClick={onRetry} className="font-semibold underline underline-offset-2">
						Retry
					</button>
					<button type="button" onClick={onDismiss} className="text-faint underline underline-offset-2">
						Dismiss
					</button>
				</div>
			</div>
		)
	}
	return (
		<div className="flex flex-col items-end gap-1" data-user-msg={messagePreview(p.text)} data-msg-state="sending">
			<Bubble className="max-w-[85%] bg-accent-soft text-text opacity-60">
				<Markdown>{p.text}</Markdown>
			</Bubble>
			<span className="flex items-center gap-1 pr-1 text-[11px] text-faint">
				<Loader2 size={11} className="animate-spin" />
				Sending…
			</span>
		</div>
	)
}

function Entry({ e, sessionId }: { e: TranscriptEntry; sessionId: string | null }) {
	if (e.role === 'user') {
		// `data-user-msg` is what MessageNav reads: the entry's position is this node's, and
		// the attributes are the row it draws in the sheet. Every user-side bubble carries
		// one — an optimistic send and the relay's queued prompt are your messages too, and
		// they're exactly the ones you scroll back to check on.
		return (
			<div className="flex flex-col items-end gap-0.5" data-user-msg={messagePreview(e.text)} data-msg-ts={e.ts}>
				<Bubble className={cn('max-w-[85%] bg-accent-soft text-text', e.queued && 'opacity-60')}>
					{e.queued ? <Label>queued</Label> : null}
					<Markdown>{e.text}</Markdown>
					{e.attachments?.length ? (
						<div className="mt-1.5 flex flex-wrap gap-1.5">
							{e.attachments.map(a =>
								IMAGE_EXT.test(a.path) ? (
									<ImageChip key={a.path} sessionId={sessionId} path={a.path} name={a.name} />
								) : (
									<span
										key={a.path}
										className="flex items-center gap-1.5 rounded-md border border-border-soft bg-surface/80 px-2 py-0.5 font-mono text-[11px] text-muted"
									>
										<FileText size={11} className="shrink-0" />
										<span className="truncate">{a.name}</span>
									</span>
								)
							)}
						</div>
					) : null}
				</Bubble>
				<span className="pr-1 text-[11px] text-faint">{messageTime(e.ts)}</span>
			</div>
		)
	}
	if (e.role === 'tool') {
		if (e.error) {
			return (
				<div className="overflow-hidden rounded-xl border border-del/30 bg-del/5 px-3 py-2">
					{/* biome-ignore format: keep {e.text} inline so <pre> doesn't render JSX indentation */}
					<pre className="line-clamp-4 whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-del/80 [overflow-wrap:anywhere]">{e.text}</pre>
				</div>
			)
		}
		// An edit with a hunk expands into the Mac-style mini diff; the row itself
		// carries the file chip with its +N −M.
		const isEdit = e.adds !== undefined || e.dels !== undefined
		const imagePath = e.detail && IMAGE_EXT.test(e.detail) ? e.detail : null
		const rowBody = (
			<>
				<span className="shrink-0 font-mono text-[11px] text-faint">▸</span>
				<span className={cn('truncate text-[12.5px] text-muted', imagePath ? 'shrink-0' : 'max-w-full')}>
					{imagePath && e.text === e.tool ? `${e.text} image` : e.text}
				</span>
				{imagePath ? (
					<ImageChip sessionId={sessionId} path={imagePath} name={basename(imagePath)} />
				) : isEdit && e.detail ? (
					<span className="flex min-w-0 flex-1 items-baseline gap-1.5 font-mono text-[11px]">
						<span className="truncate text-faint">{basename(e.detail)}</span>
						{e.adds ? <span className="shrink-0 text-add">+{e.adds}</span> : null}
						{e.dels ? <span className="shrink-0 text-del">−{e.dels}</span> : null}
					</span>
				) : e.detail ? (
					<span className="min-w-0 flex-1 truncate font-mono text-[11px] text-faint">{e.detail}</span>
				) : null}
			</>
		)
		if (e.hunk) {
			return (
				<details className="group/hunk min-w-0 overflow-hidden rounded-xl border border-border-soft bg-surface/60">
					<summary className="flex cursor-pointer select-none list-none items-baseline gap-2 overflow-hidden whitespace-nowrap px-3 py-1.5 [&::-webkit-details-marker]:hidden">
						{rowBody}
					</summary>
					{/* biome-ignore format: keep the map inline so <pre> spacing stays exact */}
					<pre className="overflow-x-auto border-t border-border-soft px-3 py-2 font-mono text-[11px] leading-relaxed">{e.hunk.split('\n').map((line, i) => (
						// biome-ignore lint/suspicious/noArrayIndexKey: a hunk is an immutable string — its lines never reorder
						<div key={i} className={line.startsWith('+') ? 'text-add' : line.startsWith('-') ? 'text-del' : 'text-faint'}>{line || ' '}</div>
					))}</pre>
				</details>
			)
		}
		return (
			<div className="flex min-w-0 items-baseline gap-2 overflow-hidden whitespace-nowrap rounded-xl border border-border-soft bg-surface/60 px-3 py-1.5">
				{rowBody}
			</div>
		)
	}
	if (e.role === 'thinking') {
		// Named group: a plain `group` would also answer to the enclosing StepGroup's open state.
		return (
			<details className="group/think px-1">
				<summary className="cursor-pointer select-none list-none text-[11px] font-semibold uppercase tracking-wide text-faint [&::-webkit-details-marker]:hidden">
					<span className="mr-1 inline-block transition-transform group-open/think:rotate-90">▸</span>
					Thinking
				</summary>
				<div className="mt-1 border-l-2 border-border-soft pl-3 text-[13px] italic leading-relaxed text-muted">
					<Markdown>{e.text}</Markdown>
				</div>
			</details>
		)
	}
	if (e.role === 'system') {
		// An error notice gets Conductor's own treatment — the bordered mono
		// capsule ("INTERRUPTED BY USER") — while unknown-frame raw dumps keep
		// the dim centered line, so Conductor drift stays visible as itself.
		if (e.error) {
			return (
				<div className="px-0.5 py-1">
					<span className="inline-block rounded-lg border border-border px-3 py-1.5 font-mono text-[11px] uppercase tracking-wider text-muted">
						{e.text}
					</span>
				</div>
			)
		}
		return <div className="px-2 text-center text-[11px] text-faint">{e.text}</div>
	}
	// assistant
	return (
		<div className="flex justify-start">
			{/* No fill on the agent's side — it's the bulk of the transcript, so the user's
			    tinted bubbles read as the reply and this reads as the page. Padding drops with
			    the background or the text would sit inset from everything around it. */}
			<Bubble className="max-w-[92%] px-0.5">
				<Markdown>{e.text}</Markdown>
			</Bubble>
		</div>
	)
}

/**
 * The classic three-dot "typing" bubble, shown under the last message while the agent
 * works — with how long the current answer has been running beside it. `since` is the
 * turn's dispatch time, so steering the agent mid-answer keeps the clock running and
 * only a fresh prompt starts it over (see `turn_started_at` in src/reads.ts).
 */
function WorkingIndicator({ since }: { since?: number | null }) {
	const [now, setNow] = useState(() => Date.now())
	useEffect(() => {
		if (!since) return
		setNow(Date.now())
		const timer = setInterval(() => setNow(Date.now()), 1000)
		return () => clearInterval(timer)
	}, [since])
	return (
		<div className="fade-in flex items-center justify-start gap-2">
			<div className="flex items-center gap-1 px-0.5 py-3">
				<span className="typing-dot" />
				<span className="typing-dot" />
				<span className="typing-dot" />
			</div>
			{since ? <span className="text-[11px] tabular-nums text-faint">{elapsed(now - since)}</span> : null}
		</div>
	)
}

function Bubble({ children, className }: { children: React.ReactNode; className?: string }) {
	return (
		<div
			className={cn(
				'min-w-0 rounded-2xl px-3.5 py-2.5 text-[14px] leading-relaxed [overflow-wrap:anywhere]',
				className
			)}
		>
			{children}
		</div>
	)
}

function Label({ children }: { children: string }) {
	return <div className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">{children}</div>
}
