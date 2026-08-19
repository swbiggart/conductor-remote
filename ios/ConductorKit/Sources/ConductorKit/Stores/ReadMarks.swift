// The phone's own unread bookkeeping — a port of web/src/lib/read.ts, and the
// semantics matter more than the code: Conductor clears its unread flag only
// when the workspace is opened *on the Mac*, and the relay reads the DB
// read-only, so a chat read on the phone would shout forever. The mark stored
// is the session's own `updated_at` string at the moment it was on screen —
// never the phone's clock — because it is only ever compared against that same
// column, lexically. Same-column comparison is what makes it immune to
// phone/Mac clock skew; the agent's next message pushes `updated_at` past the
// mark and relights the chat.

import Foundation

public struct ReadMarks: Sendable, Equatable {
	/// Keep the newest N marks — matches the PWA's prune so an old phone
	/// doesn't accumulate marks for workspaces long deleted.
	public static let limit = 300

	public private(set) var marks: [String: String]

	public init(marks: [String: String] = [:]) {
		self.marks = marks
	}

	/// Is this unread entry still unread for us? `at` and the stored mark both
	/// come from `sessions.updated_at`, so plain string comparison is correct
	/// (the format sorts lexically) and deliberate.
	public func isUnread(sessionID: String, at: String) -> Bool {
		guard let mark = marks[sessionID] else { return true }
		return mark < at
	}

	/// Unread chats among a workspace's flagged sessions (what the badge counts —
	/// unread *chats*, never Conductor's meaningless 0/1 column value).
	public func unreadCount(_ workspace: Workspace) -> Int {
		workspace.unreadSessions.count { isUnread(sessionID: $0.id, at: $0.at) }
	}

	/// Mark a chat read up to `updatedAt` — only ever the session actually on
	/// screen, and only while the app is foregrounded; callers own that rule.
	/// Never moves a mark backwards.
	public mutating func markRead(sessionID: String, updatedAt: String) {
		if let existing = marks[sessionID], existing >= updatedAt { return }
		marks[sessionID] = updatedAt
		prune()
	}

	private mutating func prune() {
		guard marks.count > Self.limit else { return }
		// Values sort lexically as recency; drop the oldest overflow.
		let sorted = marks.sorted { $0.value > $1.value }
		marks = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.limit).map { ($0.key, $0.value) })
	}
}
