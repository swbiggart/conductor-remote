// Composer drafts, one per workspace (port of web/src/lib/draft.ts). Kept
// out of view state because they must survive app relaunches and because a
// failed send puts its text back here — one tap from going again.

import Foundation

public struct DraftStore: Sendable {
	private static let prefix = "conductor-remote-draft:"
	private let store: KeyValueStore

	public init(store: KeyValueStore) {
		self.store = store
	}

	public func draft(workspaceID: String) -> String {
		store.decode(String.self, forKey: Self.prefix + workspaceID) ?? ""
	}

	public func setDraft(_ text: String, workspaceID: String) {
		let trimmedEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		store.encode(trimmedEmpty ? nil : text, forKey: Self.prefix + workspaceID)
	}

	public func clear(workspaceID: String) {
		store.set(nil, forKey: Self.prefix + workspaceID)
	}
}

/// Staged agent settings, one patch per session (port of web/src/lib/agentDraft.ts).
/// A tap only *stages* a change; the patch rides along with the next send and
/// the prompt is dropped if it didn't stick. Staging works with the relay
/// down — that's the point of keeping it client-side.
public struct AgentDraftStore: Sendable {
	private static let prefix = "conductor-remote-agent:"
	private let store: KeyValueStore

	public init(store: KeyValueStore) {
		self.store = store
	}

	public func draft(sessionID: String) -> AgentPatch {
		store.decode(AgentPatch.self, forKey: Self.prefix + sessionID) ?? AgentPatch()
	}

	/// Stage one field. Setting a field back to Conductor's live value should
	/// pass nil — unstaging it — so flipping back never queues a no-op trip.
	public func stage(sessionID: String, mutate: (inout AgentPatch) -> Void) {
		var patch = draft(sessionID: sessionID)
		mutate(&patch)
		store.encode(patch.isEmpty ? nil : patch, forKey: Self.prefix + sessionID)
	}

	/// Clear key-by-key after a send applied them: a value staged *during* the
	/// send (differing from what was applied) survives for the next one
	/// instead of being swallowed — same contract as the PWA's clearAgentDraft.
	public func clearApplied(sessionID: String, applied: AgentPatch) {
		var patch = draft(sessionID: sessionID)
		if patch.effort == applied.effort { patch.effort = nil }
		if patch.plan == applied.plan { patch.plan = nil }
		if patch.fast == applied.fast { patch.fast = nil }
		if patch.model == applied.model { patch.model = nil }
		store.encode(patch.isEmpty ? nil : patch, forKey: Self.prefix + sessionID)
	}
}
