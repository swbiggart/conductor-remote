import { useQueryClient } from '@tanstack/react-query'
import { Check, ChevronDown, RefreshCw, Zap } from 'lucide-react'
import { useState } from 'react'
import { useModels } from '../hooks.ts'
import { client } from '../lib/api.ts'
import { cn } from '../lib/cn.ts'
import { shortModel } from '../lib/format.ts'
import { idToLabel, labelToId, writeModelCache } from '../lib/models.ts'
import type { AgentPatch, Session } from '../lib/types.ts'
import { useApp } from '../store.ts'

/**
 * Conductor's own composer controls, mirrored for the phone — and rendered
 * *inside* the composer card (Composer.tsx) so the whole thing has one left edge
 * and one border, like the desktop app.
 *
 * Values are read from the DB (durable, like every other read). Changes are
 * **staged, not sent**: pushing one costs a slow, focus-stealing AppleScript trip
 * and only decides what the *next* prompt runs on, so a tap is instant and local,
 * and the send applies it (hooks.ts ▸ `useSendPrompt`) before the prompt goes.
 * A staged pill is coloured, and flipping a value back to what Conductor already
 * has drops the staged one rather than queuing a no-op round trip.
 */
const EFFORT_LABELS: Record<string, string> = {
	low: 'Low',
	medium: 'Medium',
	high: 'High',
	xhigh: 'Extra high',
	max: 'Max',
	ultracode: 'Ultracode'
}
const EFFORT_ORDER = Object.keys(EFFORT_LABELS)

/** Nothing staged — a stable identity so the selector can't loop. */
const NOTHING: AgentPatch = {}

/** A staged value only exists while it differs from Conductor's; flipping back clears it. */
function change<T>(next: T, current: T): T | undefined {
	return next === current ? undefined : next
}

/**
 * The pill shows the DB's model id (`opus-5-1m`) prettified through the cached
 * id↔label map when it can be; the picker lists labels and stages *ids*, so a
 * staged value is directly comparable to `sessions.model` (which is also what
 * lets the store's reconcile drop a draft the Mac has caught up with). Labels
 * with no mapping — a live menu read, an older relay — pass through as labels,
 * the legacy currency the relay still accepts.
 */
function modelPill(session: Session): string {
	const raw = shortModel(session.model)
	if (!raw) return 'Model'
	return raw.includes(':') ? (raw.split('/').pop() ?? raw) : raw
}

export function AgentBar({ session, workspaceId }: { session: Session; workspaceId: string }) {
	const [picking, setPicking] = useState(false)
	const staged = useApp(s => s.agentDrafts[session.id]) ?? NOTHING
	const stageAgent = useApp(s => s.stageAgent)
	// A send in flight is what pushes the staged settings. The controls stay live
	// through it — anything changed mid-send simply stages for the next one, which
	// the store's key-wise `clearAgentDraft` is what makes safe.
	const sending = useApp(s => s.pending.some(p => p.sessionId === session.id && p.status === 'sending'))
	const { data: models, isFetching, isError } = useModels(session, workspaceId, picking)
	const agentType = session.agent_type ?? 'claude'
	const queryClient = useQueryClient()
	const [refreshing, setRefreshing] = useState(false)
	const [refreshError, setRefreshError] = useState<string | null>(null)

	const stage = (patch: AgentPatch) => stageAgent(session.id, patch)

	// The one deliberately expensive tap: opens the real picker on the Mac. For a
	// catalog that disagrees with the live menu (an account-gated model, a renamed
	// label) — the escape hatch, not the default.
	const refreshLive = async () => {
		setRefreshing(true)
		setRefreshError(null)
		try {
			const r = await client.models(session.id, workspaceId, true)
			if (!r.ok || !r.models?.length) throw new Error(r.error ?? 'could not read the model list')
			writeModelCache(agentType, r.models, Date.now(), r.entries)
			queryClient.setQueryData(['models', agentType], r.models)
		} catch (err) {
			setRefreshError(err instanceof Error ? err.message : String(err))
		} finally {
			setRefreshing(false)
		}
	}

	const dbEffort = session.claude_effort_level ?? undefined
	const dbPlan = session.permission_mode === 'plan'
	const dbFast = Boolean(session.fast_mode)
	const effort = staged.effort ?? dbEffort
	const planOn = staged.plan ?? dbPlan
	const fastOn = staged.fast ?? dbFast
	const anyStaged = Object.keys(staged).length > 0

	// Tapping effort steps to the next level, matching the desktop button's own behaviour.
	const nextEffort = () => EFFORT_ORDER[(EFFORT_ORDER.indexOf(effort ?? '') + 1) % EFFORT_ORDER.length]

	return (
		<div className="min-w-0 flex-1">
			<div className="flex flex-wrap items-center gap-0.5">
				<div className="relative">
					{/* Not gated on `online`: picking is local, and the cached list means the
					    picker still works with the relay down — the change goes when the send does. */}
					<button
						type="button"
						onClick={() => setPicking(p => !p)}
						className={cn('ctl flex max-w-40 items-center gap-1', staged.model && 'ctl-staged ctl-staged-on')}
					>
						<span className="truncate">
							{staged.model ? (idToLabel(agentType, staged.model) ?? staged.model) : modelPill(session)}
						</span>
						<ChevronDown size={13} className="shrink-0" />
					</button>
					{picking ? (
						<>
							{/* Tap-anywhere-else dismiss — a phone has no blur to lean on. */}
							<button
								type="button"
								aria-label="Close model picker"
								onClick={() => setPicking(false)}
								className="fixed inset-0 z-30 cursor-default"
							/>
							<div className="absolute bottom-full left-0 z-40 mb-2 max-h-64 w-56 overflow-y-auto rounded-xl border border-border bg-surface-2 py-1 shadow-xl shadow-black/40">
								<div className="flex items-center gap-1.5 px-3 py-1 text-[11px] text-faint">
									Model
									{isFetching ? <RefreshCw size={10} className="animate-spin" /> : null}
								</div>
								{models?.length ? (
									models.map(m => {
										// Rows show labels and stage ids when the mapping is known;
										// with ids, "current" is markable and tapping it stages nothing.
										const rowValue = labelToId(agentType, m) ?? m
										const dbModel = session.model ?? undefined
										const selected = staged.model ? rowValue === staged.model : rowValue === dbModel
										return (
											<button
												type="button"
												key={m}
												onClick={() => {
													setPicking(false)
													stage({
														model: rowValue === staged.model || rowValue === dbModel ? undefined : rowValue
													})
												}}
												className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm active:bg-surface"
											>
												<span className="min-w-0 flex-1 truncate">{m}</span>
												<Check size={13} className={cn('shrink-0 text-accent', !selected && 'invisible')} />
											</button>
										)
									})
								) : (
									<div className="px-3 py-2 text-sm text-muted">
										{isError ? 'Couldn’t read the model list.' : 'Reading the model list…'}
									</div>
								)}
								{/* A refresh that failed on top of a cached list: say so, keep the list usable. */}
								{isError && models?.length ? (
									<div className="px-3 py-1.5 text-[11px] text-del">Couldn’t refresh — showing the last list.</div>
								) : null}
								<button
									type="button"
									onClick={refreshLive}
									disabled={refreshing}
									className="flex w-full items-center gap-2 border-border border-t px-3 py-2 text-left text-[12px] text-muted active:bg-surface"
								>
									<RefreshCw size={12} className={cn('shrink-0', refreshing && 'animate-spin')} />
									{refreshing ? 'Reading Conductor’s menu…' : 'Refresh from Conductor'}
								</button>
								{refreshError ? <div className="px-3 py-1.5 text-[11px] text-del">{refreshError}</div> : null}
							</div>
						</>
					) : null}
				</div>
				{effort ? (
					<button
						type="button"
						onClick={() => stage({ effort: change(nextEffort(), dbEffort) })}
						className={cn('ctl', staged.effort && 'ctl-staged ctl-staged-on')}
					>
						{EFFORT_LABELS[effort]}
					</button>
				) : null}
				{/* Fill = the value the next prompt runs with; dashed outline = staged.
				    Solid is reserved for Conductor's own state, so a staged-to-on pill
				    (tinted + dashed) can't be mistaken for already-on. */}
				<button
					type="button"
					onClick={() => stage({ plan: change(!planOn, dbPlan) })}
					className={cn(
						'ctl',
						staged.plan === undefined ? planOn && 'ctl-on' : cn('ctl-staged', planOn && 'ctl-staged-on')
					)}
				>
					Plan
				</button>
				<button
					type="button"
					onClick={() => stage({ fast: change(!fastOn, dbFast) })}
					className={cn(
						'ctl flex items-center gap-1',
						staged.fast === undefined ? fastOn && 'ctl-on' : cn('ctl-staged', fastOn && 'ctl-staged-on')
					)}
				>
					<Zap size={13} />
					Fast
				</button>
			</div>
			{anyStaged ? (
				<div className="px-2 pt-0.5 text-[11px] text-faint">{sending ? 'Applying…' : 'Applies when you send'}</div>
			) : null}
		</div>
	)
}
