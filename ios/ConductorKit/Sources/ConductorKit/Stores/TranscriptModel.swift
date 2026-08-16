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

	/// Whether the trailing turn is live — while true the fold keeps the final
	/// run of steps as individual rows and withholds its summary (the Mac's
	/// behaviour). Set from the session's working status by the ticks.
	private var trailingTurnActive = false

	/// Returns the trimmed texts of newly-arrived user rows so the send
	/// pipeline can retire matching optimistic bubbles.
	@discardableResult
	public func apply(_ response: MessagesResponse, trailingTurnActive: Bool? = nil) -> [String] {
		loaded = true
		if let trailingTurnActive { self.trailingTurnActive = trailingTurnActive }
		guard !response.entries.isEmpty else { return [] }
		entries.append(contentsOf: response.entries)
		cursor = max(cursor, response.cursor)
		// Full refold on append: O(n) over a few thousand entries at 1 Hz is
		// nothing, and group identity is stable (first row's key) so SwiftUI
		// keeps expansion state. Don't add incremental merge complexity until
		// a profile demands it.
		items = TranscriptGrouping.fold(entries, trailingTurnActive: self.trailingTurnActive)
		return response.entries.filter { $0.role == .user }.map(\.text)
	}

	/// Working flipped with no new rows (the sessions poll saw the turn end or
	/// start): refold so the live steps collapse — or a fresh turn's unfold —
	/// without waiting for the next message.
	public func setTrailingTurnActive(_ active: Bool) {
		guard active != trailingTurnActive else { return }
		trailingTurnActive = active
		items = TranscriptGrouping.fold(entries, trailingTurnActive: active)
	}
}
