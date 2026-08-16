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

	/// Returns the trimmed texts of newly-arrived user rows so the send
	/// pipeline can retire matching optimistic bubbles.
	@discardableResult
	public func apply(_ response: MessagesResponse) -> [String] {
		loaded = true
		guard !response.entries.isEmpty else { return [] }
		entries.append(contentsOf: response.entries)
		cursor = max(cursor, response.cursor)
		// Full refold on append: O(n) over a few thousand entries at 1 Hz is
		// nothing, and group identity is stable (first row's key) so SwiftUI
		// keeps expansion state. Don't add incremental merge complexity until
		// a profile demands it.
		items = TranscriptGrouping.fold(entries)
		return response.entries.filter { $0.role == .user }.map(\.text)
	}
}
