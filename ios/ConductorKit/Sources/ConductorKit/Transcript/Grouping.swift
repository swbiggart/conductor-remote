// Folds the relay's flat transcript into what the chat renders: spoken
// messages inline, and every consecutive run of tool/thinking entries between
// them collapsed into one expandable "N steps" block. A run of exactly one
// stays inline — same rule as the PWA (web/src/components/Transcript.tsx),
// where this fold is the single biggest readability win on a phone.

public enum TranscriptItem: Sendable, Equatable, Identifiable {
	case message(TranscriptEntry)
	/// One inline step (a lone tool/thinking row between spoken messages —
	/// or any step of the live trailing run while the agent works).
	case step(TranscriptEntry)
	case steps(StepGroup)
	/// The end-of-turn receipt: duration + per-file `+N −M` chips.
	case turnSummary(TurnSummary)

	public var id: String {
		switch self {
		case .message(let entry), .step(let entry): entry.key
		case .steps(let group): group.id
		case .turnSummary(let summary): summary.id
		}
	}
}

/// One completed turn's accounting, shown as the Mac's summary row.
public struct TurnSummary: Sendable, Equatable, Identifiable {
	public struct File: Sendable, Equatable, Identifiable {
		public let name: String
		public var adds: Int
		public var dels: Int
		public var id: String { name }
	}

	/// The turn head's key — stable for the turn's lifetime.
	public let id: String
	public let files: [File]
	/// Turn elapsed, first entry to last, or nil when a timestamp won't parse.
	public let seconds: Int?
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
	/// `trailingTurnActive` = the agent is working: the final run of steps stays
	/// as individual live rows (the Mac's behaviour) and the trailing turn gets
	/// no summary yet — both appear when the turn ends. Interior groups keep
	/// their identity (first row's key) either way, so the eventual collapse
	/// can't lose expansion state elsewhere.
	public static func fold(_ entries: [TranscriptEntry], trailingTurnActive: Bool = false) -> [TranscriptItem] {
		// Segment into turns first (turnId is NULL on pre-May-2026 rows — those
		// merge into one span that simply never gets a summary).
		var turns: [[TranscriptEntry]] = []
		var lastTurnId: String?
		for entry in entries {
			let changed = entry.turnId != nil && lastTurnId != nil && entry.turnId != lastTurnId
			if turns.isEmpty || changed { turns.append([]) }
			turns[turns.count - 1].append(entry)
			if let turnId = entry.turnId { lastTurnId = turnId }
		}

		var items: [TranscriptItem] = []
		for (index, turn) in turns.enumerated() {
			let trailing = index == turns.count - 1
			items.append(contentsOf: foldTurn(turn, unfoldTrailingRun: trailing && trailingTurnActive))
			if trailing && trailingTurnActive { continue }
			if let summary = summarize(turn) { items.append(.turnSummary(summary)) }
		}
		return items
	}

	private static func foldTurn(_ entries: [TranscriptEntry], unfoldTrailingRun: Bool) -> [TranscriptItem] {
		var items: [TranscriptItem] = []
		var run: [TranscriptEntry] = []

		func flush(asIndividual: Bool = false) {
			if run.count == 1 || (asIndividual && !run.isEmpty) {
				items.append(contentsOf: run.map { .step($0) })
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
		flush(asIndividual: unfoldTrailingRun)
		return items
	}

	/// Per-file totals + elapsed for one turn, or nil when it edited nothing.
	private static func summarize(_ turn: [TranscriptEntry]) -> TurnSummary? {
		let edits = turn.filter { $0.adds != nil || $0.dels != nil }
		guard !edits.isEmpty, turn.contains(where: { $0.turnId != nil }), let head = turn.first else { return nil }
		var order: [String] = []
		var byFile: [String: TurnSummary.File] = [:]
		for entry in edits {
			let name = (entry.detail ?? "").split(separator: "/").last.map(String.init) ?? "files"
			var file = byFile[name] ?? TurnSummary.File(name: name, adds: 0, dels: 0)
			if byFile[name] == nil { order.append(name) }
			file.adds += entry.adds ?? 0
			file.dels += entry.dels ?? 0
			byFile[name] = file
		}
		var seconds: Int?
		if let first = SQLiteDate.parse(head.ts), let last = SQLiteDate.parse(turn[turn.count - 1].ts),
			last > first {
			seconds = Int(last.timeIntervalSince(first).rounded())
		}
		return TurnSummary(id: "turn-\(head.key)", files: order.compactMap { byFile[$0] }, seconds: seconds)
	}
}
