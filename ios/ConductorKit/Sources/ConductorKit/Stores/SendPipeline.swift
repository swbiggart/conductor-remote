// The send path, ported behaviour-for-behaviour from useSendPrompt
// (web/src/hooks.ts): fire-and-forget from the composer's point of view, an
// optimistic bubble as the only feedback, silent reconciliation against the
// transcript (the delivered prompt appearing as a real row *is* the receipt —
// deliberately no "Sent" toast), and failure as an inline Retry/Dismiss state
// that never loses the text.
//
// Staged agent settings ride in the same request so a locked Mac parks the
// two together; the relay applies them before the prompt and the prompt only
// goes if they stuck.

import Foundation
import Observation

@MainActor
@Observable
public final class SendPipeline {
	public struct Pending: Identifiable, Sendable, Equatable {
		public enum Status: Sendable, Equatable {
			case sending
			case failed(String)
			/// The app was suspended mid-send and the outcome is unknown; the
			/// next transcript poll resolves it (the relay confirms delivery
			/// against the transcript itself, so a landed send shows up).
			case unconfirmed
		}

		public let id: UUID
		public let sessionID: String
		public let workspaceID: String
		public let text: String
		public var status: Status
	}

	public private(set) var pendings: [Pending] = []

	private let client: APIClient
	private let agentDrafts: AgentDraftStore
	private let drafts: DraftStore
	/// Called after any send outcome so the owner can kick polls / set hints.
	private var onOutcome: (@MainActor (SendOutcome) -> Void)?

	public enum SendOutcome: Sendable {
		case delivered(sessionID: String)
		case parked(sessionID: String)
		case failed(sessionID: String, error: String)
	}

	public init(client: APIClient, drafts: DraftStore, agentDrafts: AgentDraftStore) {
		self.client = client
		self.drafts = drafts
		self.agentDrafts = agentDrafts
	}

	public func onOutcome(_ handler: @escaping @MainActor (SendOutcome) -> Void) {
		self.onOutcome = handler
	}

	public func pendings(sessionID: String) -> [Pending] {
		pendings.filter { $0.sessionID == sessionID }
	}

	/// Send `text` to a chat, carrying any staged agent settings. The composer
	/// clears immediately (its draft is already saved); the bubble is the truth.
	public func send(sessionID: String, workspaceID: String, text: String, retrying retryID: UUID? = nil) async {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let id = retryID ?? UUID()
		if let index = pendings.firstIndex(where: { $0.id == id }) {
			pendings[index].status = .sending
		} else {
			pendings.append(Pending(id: id, sessionID: sessionID, workspaceID: workspaceID, text: text, status: .sending))
		}
		drafts.clear(workspaceID: workspaceID)

		let staged = agentDrafts.draft(sessionID: sessionID)
		let agent = staged.isEmpty ? nil : staged

		do {
			let result = try await client.sendPrompt(
				sessionID: sessionID, workspaceID: workspaceID, text: text, agent: agent)
			if result.ok {
				// Delivered. The real row arrives on the next 1 s poll and
				// retires the bubble by text match; the 4 s purge is the
				// fallback for a relay-side trim mismatch.
				if let agent { agentDrafts.clearApplied(sessionID: sessionID, applied: agent) }
				schedulePurge(id: id)
				onOutcome?(.delivered(sessionID: sessionID))
			} else if result.parked == true {
				// The Mac is locked: the relay owns the prompt now. The parked
				// bubble is rendered from /api/state's parked_prompts — not
				// from this pending, which would double it.
				if let agent { agentDrafts.clearApplied(sessionID: sessionID, applied: agent) }
				pendings.removeAll { $0.id == id }
				onOutcome?(.parked(sessionID: sessionID))
			} else {
				fail(id: id, message: result.error ?? "Send didn't land — try again.", sessionID: sessionID)
			}
		} catch let error as APIError {
			fail(id: id, message: error.message, sessionID: sessionID)
		} catch {
			fail(id: id, message: String(describing: error), sessionID: sessionID)
		}
	}

	public func dismiss(_ id: UUID) {
		pendings.removeAll { $0.id == id }
	}

	/// New user rows arrived from the transcript poll: any pending whose
	/// trimmed text matches one is delivered — including an "unconfirmed" one
	/// from a send the app was suspended in the middle of.
	public func reconcile(sessionID: String, userTexts: [String]) {
		guard !userTexts.isEmpty else { return }
		let arrived = Set(userTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
		pendings.removeAll {
			$0.sessionID == sessionID && arrived.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	/// The app is being suspended with sends in flight: their outcome is
	/// unknown, not failed. Reconciliation on reopen resolves them.
	public func markInFlightUnconfirmed() {
		for index in pendings.indices where pendings[index].status == .sending {
			pendings[index].status = .unconfirmed
		}
	}

	private func fail(id: UUID, message: String, sessionID: String) {
		guard let index = pendings.firstIndex(where: { $0.id == id }) else { return }
		pendings[index].status = .failed(message)
		onOutcome?(.failed(sessionID: sessionID, error: message))
	}

	private func schedulePurge(id: UUID) {
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(4))
			self?.pendings.removeAll { $0.id == id && $0.status == .sending }
		}
	}
}
