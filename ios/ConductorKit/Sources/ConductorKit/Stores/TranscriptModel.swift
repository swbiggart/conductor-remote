// One chat's transcript: the rowid cursor, the accumulated entries, and the
// grouped items the view renders. Transcripts are deliberately not persisted —
// a fresh open refetches from 0 (matches the PWA; the relay serves it in one
// cheap read) — but the model is kept per session for the life of the app so
// switching tabs doesn't refetch.

import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptModel {
	public let sessionID: String
	public private(set) var entries: [TranscriptEntry] = []
	public private(set) var items: [TranscriptItem] = []
	public private(set) var cursor: Int64 = 0
	public private(set) var loaded = false

	/// The user's own prompts, in order — what the message navigator steps
	/// between. Queued rows count too (they're visible bubbles).
	public var userEntries: [TranscriptEntry] {
		entries.filter { $0.role == .user }
	}

	public init(sessionID: String) {
		self.sessionID = sessionID
	}

	/// Whether the trailing turn is live — while true the fold withholds its
	/// summary, and (with `liveSteps` on) keeps the final run of steps as
	/// individual rows. Set from the session's working status by the ticks.
	private var trailingTurnActive = false
	/// The Settings toggle: stream the live run unfolded, or keep it collapsed
	/// like every other run. Product default is collapsed; AppModel pushes the
	/// persisted choice in.
	private var liveSteps = false

	/// The question/plan the agent is stopped on, riding every poll of this
	/// chat (additive relay field). Nil the moment it's answered anywhere.
	public private(set) var pending: PendingInput?

	/// Returns the trimmed texts of newly-arrived user rows so the send
	/// pipeline can retire matching optimistic bubbles.
	@discardableResult
	public func apply(_ response: MessagesResponse, trailingTurnActive: Bool? = nil) -> [String] {
		loaded = true
		if let trailingTurnActive { self.trailingTurnActive = trailingTurnActive }
		// Before the empty-entries guard: `pending` changes on polls that carry
		// no new rows (the card is answered on the Mac → pending goes nil with
		// an empty batch, and the tool_result row may arrive later or never).
		pending = response.pending
		guard !response.entries.isEmpty else { return [] }
		entries.append(contentsOf: response.entries)
		cursor = max(cursor, response.cursor)
		// Full refold on append: O(n) over a few thousand entries at 1 Hz is
		// nothing, and group identity is stable (first row's key) so SwiftUI
		// keeps expansion state. Don't add incremental merge complexity until
		// a profile demands it.
		refold()
		return response.entries.filter { $0.role == .user }.map(\.text)
	}

	/// Working flipped with no new rows (the sessions poll saw the turn end or
	/// start): refold so the live steps collapse — or a fresh turn's unfold —
	/// without waiting for the next message.
	public func setTrailingTurnActive(_ active: Bool) {
		guard active != trailingTurnActive else { return }
		trailingTurnActive = active
		refold()
	}

	/// The Settings toggle changed (or a fresh model needs the persisted value).
	public func setLiveSteps(_ enabled: Bool) {
		guard enabled != liveSteps else { return }
		liveSteps = enabled
		refold()
	}

	private func refold() {
		items = TranscriptGrouping.fold(entries, trailingTurnActive: trailingTurnActive, liveSteps: liveSteps)
	}
}
