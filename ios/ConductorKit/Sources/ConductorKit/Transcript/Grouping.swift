// Folds the relay's flat transcript into what the chat renders: spoken
// messages inline, and every consecutive run of tool/thinking entries between
// them collapsed into one expandable "N steps" block. A run of exactly one
// stays inline — same rule as the PWA (web/src/components/Transcript.tsx),
// where this fold is the single biggest readability win on a phone.

public enum TranscriptItem: Sendable, Equatable, Identifiable {
	case message(TranscriptEntry)
	/// One inline step (a lone tool/thinking row between spoken messages).
	case step(TranscriptEntry)
	case steps(StepGroup)

	public var id: String {
		switch self {
		case .message(let entry), .step(let entry): entry.key
		case .steps(let group): group.id
		}
	}
}

/// A collapsed run of agent activity. The header a closed group shows — the
/// *last* step's label — keeps changing while the agent works, so the group
/// reads as live activity without being open.
public struct StepGroup: Sendable, Equatable, Identifiable {
	public let entries: [TranscriptEntry]

	/// Stable across appends: the first row's key. A growing tail must not
	/// change the group's identity or SwiftUI re-creates (and re-collapses) it.
	public var id: String { entries.first.map(\.key) ?? "steps-empty" }
	public var count: Int { entries.count }
	public var failedCount: Int { entries.count(where: \.isError) }

	/// What the collapsed header shows beside the count.
	public var lastLabel: String {
		guard let last = entries.last else { return "" }
		return last.role == .thinking ? "Thinking" : last.text
	}
}

public enum TranscriptGrouping {
	public static func fold(_ entries: [TranscriptEntry]) -> [TranscriptItem] {
		var items: [TranscriptItem] = []
		var run: [TranscriptEntry] = []

		func flush() {
			if run.count == 1 {
				items.append(.step(run[0]))
			} else if run.count > 1 {
				items.append(.steps(StepGroup(entries: run)))
			}
			run.removeAll(keepingCapacity: true)
		}

		for entry in entries {
			switch entry.role {
			case .tool, .thinking:
				run.append(entry)
			case .user, .assistant, .system:
				flush()
				items.append(.message(entry))
			}
		}
		flush()
		return items
	}
}
