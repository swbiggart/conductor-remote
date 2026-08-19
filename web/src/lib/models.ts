/**
 * The model list, cached across app loads.
 *
 * The relay now serves it from a catalog extracted out of Conductor's own binary
 * — instant, no Accessibility — so the fetch is cheap; this cache is what lets
 * the picker paint offline, and it carries the id↔label mapping between opens.
 * The expensive path still exists behind the picker's manual refresh (`refresh=1`
 * opens the real menu on the Mac — seconds of stolen focus), which is why the
 * mapping is persisted rather than refetched casually.
 *
 * Keyed by `agent_type` (claude | codex | cursor | acp), which is what decides
 * the menu's contents — not by session, or every new chat would start cold. The
 * timestamp seeds React Query's `initialDataUpdatedAt`, so a list older than the
 * stale window refetches on open and a fresh one doesn't.
 */
import type { ModelEntry } from './types.ts'

const KEY = 'conductor-remote-models'

export interface CachedModels {
	models: string[]
	/** Epoch ms the list was last read off Conductor. */
	at: number
	/** id+label pairs when the relay served its catalog — what maps a tapped label to the id it stages. */
	entries?: ModelEntry[]
}

function readAll(): Record<string, CachedModels> {
	try {
		return JSON.parse(localStorage.getItem(KEY) ?? '{}') as Record<string, CachedModels>
	} catch {
		return {}
	}
}

export function readModelCache(agentType: string): CachedModels | undefined {
	const hit = readAll()[agentType]
	return hit?.models?.length ? hit : undefined
}

export function writeModelCache(agentType: string, models: string[], at: number, entries?: ModelEntry[]): void {
	try {
		localStorage.setItem(KEY, JSON.stringify({ ...readAll(), [agentType]: { models, at, entries } }))
	} catch {}
}

/**
 * The id a picker label stages, and the label a staged id shows. Both lean on the
 * last list the relay served; a label or id the cache doesn't know passes through
 * unchanged, which is exactly the legacy behaviour (label-currency all the way).
 */
export function labelToId(agentType: string, label: string): string | undefined {
	return readModelCache(agentType)?.entries?.find(e => e.label === label)?.id
}

export function idToLabel(agentType: string, id: string): string | undefined {
	return readModelCache(agentType)?.entries?.find(e => e.id === id)?.label
}
