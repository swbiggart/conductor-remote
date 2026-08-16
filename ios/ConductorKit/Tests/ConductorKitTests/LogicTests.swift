import Foundation
import Testing

@testable import ConductorKit

private func entry(
	_ rowid: Int64, _ role: Role, text: String = "", error: Bool = false, queued: Bool = false,
	turnId: String? = nil, detail: String? = nil, adds: Int? = nil, dels: Int? = nil, ts: String = "2026-08-15 10:00:00"
) -> TranscriptEntry {
	TranscriptEntry(
		id: "\(rowid)", rowid: rowid, role: role, text: text, tool: nil, detail: detail,
		error: error ? true : nil, ts: ts, queued: queued, turnId: turnId, adds: adds, dels: dels)
}

@Suite struct GroupingTests {
	@Test func runsCollapseSinglesStayInline() {
		let items = TranscriptGrouping.fold([
			entry(1, .user, text: "do it"),
			entry(2, .tool, text: "Reading files"),
			entry(3, .assistant, text: "starting"),
			entry(4, .tool, text: "Editing a.ts"),
			entry(5, .thinking, text: "hmm"),
			entry(6, .tool, text: "Running tests", error: true),
			entry(7, .assistant, text: "done")
		])
		guard case .message = items[0], case .step = items[1], case .message = items[2],
			case .steps(let group) = items[3], case .message = items[4]
		else {
			Issue.record("unexpected shape: \(items)")
			return
		}
		#expect(items.count == 5)
		#expect(group.count == 3)
		#expect(group.failedCount == 1)
		#expect(group.lastLabel == "Running tests")
	}

	@Test func thinkingLastLabelReadsThinking() {
		let items = TranscriptGrouping.fold([
			entry(1, .tool, text: "Editing"),
			entry(2, .thinking, text: "private reasoning")
		])
		guard case .steps(let group) = items[0] else {
			Issue.record("expected a group")
			return
		}
		#expect(group.lastLabel == "Thinking")
	}

	@Test func trailingRunStaysLiveWhileWorking() {
		let entries = [entry(1, .user, turnId: "t1"), entry(2, .tool, turnId: "t1"), entry(3, .tool, turnId: "t1")]
		// Working: each trailing step is its own live row, and no summary yet.
		let live = TranscriptGrouping.fold(entries, trailingTurnActive: true)
		#expect(live.count == 3)
		guard case .step = live[1], case .step = live[2] else {
			Issue.record("live trailing steps should stay individual")
			return
		}
		// Turn over: the same run folds, group id = first row's key as always.
		let done = TranscriptGrouping.fold(entries, trailingTurnActive: false)
		guard case .steps(let group) = done[1] else {
			Issue.record("finished trailing run should fold")
			return
		}
		#expect(group.id == entries[1].key)
	}

	@Test func completedTurnGetsSummaryWithFileTotals() {
		let items = TranscriptGrouping.fold([
			entry(1, .user, turnId: "t1", ts: "2026-08-15 10:00:00"),
			entry(2, .tool, turnId: "t1", detail: "src/a.ts", adds: 3, dels: 1),
			entry(3, .tool, turnId: "t1", detail: "src/a.ts", adds: 2),
			entry(4, .assistant, turnId: "t1", ts: "2026-08-15 10:01:30"),
			entry(5, .user, turnId: "t2"),
			entry(6, .assistant, turnId: "t2")
		])
		guard case .turnSummary(let summary) = items.first(where: { if case .turnSummary = $0 { true } else { false } })
		else {
			Issue.record("edited turn should get a summary")
			return
		}
		// Per-file totals aggregate across the turn's edits; names are basenames.
		#expect(summary.files == [TurnSummary.File(name: "a.ts", adds: 5, dels: 1)])
		#expect(summary.seconds == 90)
		// The second turn edited nothing → exactly one summary in the stream.
		#expect(items.count(where: { if case .turnSummary = $0 { true } else { false } }) == 1)
	}

	@Test func groupIdentityStableAcrossAppends() {
		let base = [entry(1, .tool), entry(2, .tool)]
		let grown = base + [entry(3, .tool)]
		guard case .steps(let a) = TranscriptGrouping.fold(base)[0],
			case .steps(let b) = TranscriptGrouping.fold(grown)[0]
		else {
			Issue.record("expected groups")
			return
		}
		// A growing tail must not change the group's identity, or SwiftUI
		// re-creates the disclosure and loses its expansion state.
		#expect(a.id == b.id)
	}

	@Test func trailingRunFlushes() {
		let items = TranscriptGrouping.fold([entry(1, .user), entry(2, .tool), entry(3, .tool)])
		#expect(items.count == 2)
		guard case .steps = items[1] else {
			Issue.record("trailing run should fold")
			return
		}
	}
}

@Suite struct ReadMarksTests {
	@Test func sameColumnLexicalComparison() {
		var marks = ReadMarks()
		#expect(marks.isUnread(sessionID: "s1", at: "2026-08-15 11:00:00"))
		marks.markRead(sessionID: "s1", updatedAt: "2026-08-15 11:00:00")
		#expect(!marks.isUnread(sessionID: "s1", at: "2026-08-15 11:00:00"))
		// The agent's next message pushes updated_at past the mark → relights.
		#expect(marks.isUnread(sessionID: "s1", at: "2026-08-15 11:00:01"))
	}

	@Test func neverMovesBackwards() {
		var marks = ReadMarks()
		marks.markRead(sessionID: "s1", updatedAt: "2026-08-15 11:00:00")
		marks.markRead(sessionID: "s1", updatedAt: "2026-08-15 10:00:00")
		#expect(!marks.isUnread(sessionID: "s1", at: "2026-08-15 11:00:00"))
	}

	@Test func prunesOldestBeyondLimit() {
		var marks = ReadMarks()
		for i in 0...(ReadMarks.limit + 10) {
			marks.markRead(sessionID: "s\(i)", updatedAt: String(format: "2026-08-15 %02d:%02d:00", i / 60, i % 60))
		}
		#expect(marks.marks.count == ReadMarks.limit)
		// The oldest marks fell off; a re-read of the newest survives.
		#expect(marks.marks["s0"] == nil)
		#expect(marks.marks["s\(ReadMarks.limit + 10)"] != nil)
	}

	@Test func unreadCountCountsChatsNotFlags() throws {
		let json = """
			{"id":"w1","directory_name":null,"workspace_name":"N","branch":null,"pr_title":null,
			 "derived_status":null,"manual_status":null,"state":"ready",
			 "created_at":"2026-08-15 10:00:00","updated_at":"2026-08-15 11:00:00",
			 "unread_sessions":[{"id":"a","at":"2026-08-15 11:00:00"},{"id":"b","at":"2026-08-15 10:30:00"}],
			 "pinned_at":null,"active_session_id":null,"intended_target_branch":null,
			 "repo_name":null,"session_status":null,"session_title":null,"model":null,
			 "context_used_percent":null,"icon":null}
			"""
		let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
		var marks = ReadMarks()
		#expect(marks.unreadCount(workspace) == 2)
		marks.markRead(sessionID: "a", updatedAt: "2026-08-15 11:00:00")
		#expect(marks.unreadCount(workspace) == 1)
	}
}

@Suite struct BackoffTests {
	@Test func doublesAndCaps() {
		var backoff = Backoff(base: 2.5)
		#expect(backoff.interval == 2.5)
		backoff.recordFailure()
		#expect(backoff.interval == 5)
		backoff.recordFailure()
		#expect(backoff.interval == 10)
		for _ in 0..<10 { backoff.recordFailure() }
		#expect(backoff.interval == Backoff.cap)
		backoff.recordSuccess()
		#expect(backoff.interval == 2.5)
	}
}

@Suite struct PairingParserTests {
	@Test func parsesHashTokenURL() throws {
		let creds = try #require(PairingParser.parse("https://mac.tail1234.ts.net/#token=deadbeefdeadbeefdeadbeefdeadbeef"))
		#expect(creds.baseURL.absoluteString == "https://mac.tail1234.ts.net")
		#expect(creds.token == "deadbeefdeadbeefdeadbeefdeadbeef")
	}

	@Test func parsesQueryTokenAndLocalhost() throws {
		let creds = try #require(PairingParser.parse("http://127.0.0.1:8787/?token=abc123&x=1"))
		#expect(creds.baseURL.absoluteString == "http://127.0.0.1:8787")
		#expect(creds.token == "abc123")
	}

	@Test func rejectsBareTokenAndWhitespace() {
		// A bare token has no host to talk to — the UI asks for the full URL.
		#expect(PairingParser.parse("deadbeefdeadbeef") == nil)
		#expect(PairingParser.parse("https://x.ts.net/#token=a b") == nil)
		#expect(PairingParser.parse("") == nil)
	}
}

@Suite struct DraftStoreTests {
	@Test func agentDraftStageAndUnstage() {
		let store = AgentDraftStore(store: InMemoryKeyValueStore())
		store.stage(sessionID: "s1") { $0.effort = "max" }
		store.stage(sessionID: "s1") { $0.plan = true }
		#expect(store.draft(sessionID: "s1") == AgentPatch(effort: "max", plan: true))
		// Flipping a value back to Conductor's own unstages it, not a no-op trip.
		store.stage(sessionID: "s1") { $0.effort = nil }
		#expect(store.draft(sessionID: "s1") == AgentPatch(plan: true))
	}

	@Test func clearAppliedIsKeyByKey() {
		let store = AgentDraftStore(store: InMemoryKeyValueStore())
		store.stage(sessionID: "s1") { $0.effort = "max" }
		let applied = store.draft(sessionID: "s1")
		// A change staged *during* the send survives for the next one.
		store.stage(sessionID: "s1") { $0.effort = "low" }
		store.clearApplied(sessionID: "s1", applied: applied)
		#expect(store.draft(sessionID: "s1") == AgentPatch(effort: "low"))
	}

	@Test func composerDraftRoundTrip() {
		let store = DraftStore(store: InMemoryKeyValueStore())
		store.setDraft("half a thought", workspaceID: "w1")
		#expect(store.draft(workspaceID: "w1") == "half a thought")
		store.setDraft("   ", workspaceID: "w1")
		#expect(store.draft(workspaceID: "w1") == "")
	}
}

@Suite struct ModelCacheTests {
	@Test func staleWhileRevalidate() {
		let cache = ModelCache(store: InMemoryKeyValueStore())
		let past = Date(timeIntervalSinceNow: -ModelCache.staleness - 1)
		cache.save(agentType: "claude", models: ["Opus 5"], now: past)
		#expect(cache.cached(agentType: "claude")?.models == ["Opus 5"])
		#expect(!cache.isFresh(agentType: "claude"))
		cache.save(agentType: "claude", models: ["Opus 5", "Sonnet 5"])
		#expect(cache.isFresh(agentType: "claude"))
	}
}
