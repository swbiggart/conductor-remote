import Foundation
import Testing

@testable import ConductorKit

@Suite struct SQLiteDateTests {
	@Test func parsesAsUTC() throws {
		let date = try #require(SQLiteDate.parse("2026-08-15 12:00:00"))
		// The whole point of this parser: 12:00:00 is noon *UTC*, regardless
		// of the phone's zone (the PWA parses it as local time — a bug).
		let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z"))
		#expect(date == expected)
	}

	@Test func stripsFractionalSeconds() throws {
		let plain = try #require(SQLiteDate.parse("2026-08-15 12:00:00"))
		let fractional = try #require(SQLiteDate.parse("2026-08-15 12:00:00.123"))
		#expect(plain == fractional)
	}

	@Test func parsesISO8601UpdatedAt() throws {
		// Conductor's updated_at is ISO with milliseconds (verified live);
		// created_at is SQLite format. Both must parse.
		let iso = try #require(SQLiteDate.parse("2026-08-16T00:48:19.600Z"))
		#expect(abs(iso.timeIntervalSince1970 - 1_786_841_299.6) < 0.01)
		#expect(SQLiteDate.parse("2026-08-16T00:48:19Z") != nil)
	}

	@Test func rejectsGarbage() {
		#expect(SQLiteDate.parse(nil) == nil)
		#expect(SQLiteDate.parse("") == nil)
		#expect(SQLiteDate.parse("not a date") == nil)
	}
}

@Suite struct DecodingTests {
	private let decoder = JSONDecoder()

	@Test func workspaceMinimal() throws {
		// parked_prompts omitted entirely (relay drops the key when empty),
		// unknown icon kind must not sink the row.
		let json = """
			{"id":"w1","directory_name":"auckland","workspace_name":null,"branch":"swb/x",
			 "pr_title":null,"derived_status":null,"manual_status":"in-progress","state":"ready",
			 "created_at":"2026-08-15 10:00:00","updated_at":"2026-08-15 11:00:00",
			 "unread_sessions":[{"id":"s1","at":"2026-08-15 11:00:00"}],
			 "pinned_at":null,"active_session_id":"s1","intended_target_branch":null,
			 "repo_name":"conductor-remote","session_status":"working","session_title":"Chat",
			 "model":"claude-opus-5","context_used_percent":42.5,
			 "icon":{"kind":"hologram","value":"?"},"pr_status":"mergeable","pending_prompt":null}
			"""
		let w = try decoder.decode(Workspace.self, from: Data(json.utf8))
		#expect(w.parkedPrompts.isEmpty)
		#expect(w.icon == nil)
		#expect(w.prStatus == .mergeable)
		#expect(w.unreadSessions.count == 1)
		#expect(Format.workspaceLabel(w) == "X")
	}

	@Test func unknownPrStatusIsNilNotFatal() throws {
		let json = """
			{"id":"w1","directory_name":null,"workspace_name":"N","branch":null,"pr_title":null,
			 "derived_status":null,"manual_status":null,"state":"ready",
			 "created_at":"2026-08-15 10:00:00","updated_at":"2026-08-15 11:00:00",
			 "unread_sessions":[],"pinned_at":null,"active_session_id":null,
			 "intended_target_branch":null,"repo_name":null,"session_status":null,
			 "session_title":null,"model":null,"context_used_percent":null,"icon":null,
			 "pr_status":"quantum"}
			"""
		let w = try decoder.decode(Workspace.self, from: Data(json.utf8))
		#expect(w.prStatus == nil)
	}

	@Test func repoIconVariants() throws {
		#expect(try decoder.decode(RepoIcon.self, from: Data(#"{"kind":"emoji","value":"🚀"}"#.utf8)) == .emoji("🚀"))
		#expect(try decoder.decode(RepoIcon.self, from: Data(#"{"kind":"file"}"#.utf8)) == .file)
		#expect(
			try decoder.decode(RepoIcon.self, from: Data(#"{"kind":"github","owner":"anthropics"}"#.utf8))
				== .github(owner: "anthropics"))
	}

	@Test func sendResultParked() throws {
		let json = """
			{"ok":false,"parked":true,"strategy":"applescript",
			 "queued":{"workspaceId":"w1","sessionId":"s1","text":"hi","status":"waiting",
			           "attempts":0,"createdAt":1723700000000,
			           "reason":"Sends when the Mac is unlocked"},
			 "error":"The Mac is locked"}
			"""
		let result = try decoder.decode(SendResult.self, from: Data(json.utf8))
		#expect(result.ok == false)
		#expect(result.parked == true)
		#expect(result.queued?.reason == "Sends when the Mac is unlocked")
	}
}

@Suite struct FormatTests {
	@Test func labelPrecedence() {
		#expect(Format.humanizeBranch("swb/fix-the-composer") == "Fix the composer")
		#expect(Format.humanizeBranch("main") == "Main")
	}

	@Test func shortModel() {
		#expect(Format.shortModel("claude-opus-5-20250514") == "opus-5")
		#expect(Format.shortModel("claude-sonnet-5-latest") == "sonnet-5")
		#expect(Format.shortModel("gpt-5") == "gpt-5")
		#expect(Format.shortModel(nil) == nil)
	}

	@Test func statusRankOrdersKnownBeforeUnknown() {
		// Active work first, finished last (user-requested flip, 2026-08-15).
		#expect(Format.statusRank("in-progress") < Format.statusRank("in-review"))
		#expect(Format.statusRank("in-review") < Format.statusRank("done"))
		#expect(Format.statusRank("done") < Format.statusRank("someday"))
	}
}

@Suite struct PendingInputTests {
	@Test func decodesPendingOnMessages() throws {
		let json = """
			{"entries":[],"cursor":7,"pending":{"kind":"question","toolUseId":"tu1","rowid":9,
			 "questions":[{"question":"Which color?","options":[{"label":"Green"},{"label":"Blue","description":"calmer"}]}],
			 "ts":"2026-08-16 01:00:00"}}
			"""
		let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
		let pending = try #require(response.pending)
		#expect(pending.answerable)
		#expect(pending.questions?.first?.options.count == 2)
		// Older relay without the field: absent → nil, not a decode failure.
		let old = try JSONDecoder().decode(MessagesResponse.self, from: Data(#"{"entries":[],"cursor":0}"#.utf8))
		#expect(old.pending == nil)
	}

	@Test func multiSelectIsNotAnswerable() throws {
		let json = """
			{"kind":"question","toolUseId":"t","rowid":1,"ts":"2026-08-16 01:00:00",
			 "questions":[{"question":"Pick many","multiSelect":true,"options":[{"label":"A"}]}]}
			"""
		let pending = try JSONDecoder().decode(PendingInput.self, from: Data(json.utf8))
		#expect(!pending.answerable)
		let plan = try JSONDecoder().decode(
			PendingInput.self,
			from: Data(#"{"kind":"plan","toolUseId":"t","rowid":1,"ts":"2026-08-16 01:00:00","plan":"do x"}"#.utf8))
		#expect(plan.answerable && plan.isPlan)
	}
}

@Suite @MainActor struct TranscriptPendingTests {
	@Test func pendingUpdatesEvenOnEmptyBatch() {
		let model = TranscriptModel(sessionID: "s1")
		let pending = PendingInput(
			kind: "plan", toolUseId: "tu", rowid: 1, questions: nil, plan: "p", ts: "2026-08-16 01:00:00")
		model.apply(MessagesResponse(entries: [], cursor: 0, pending: pending))
		#expect(model.pending?.toolUseId == "tu")
		// Answered on the Mac: pending drops on a poll with no new rows.
		model.apply(MessagesResponse(entries: [], cursor: 0, pending: nil))
		#expect(model.pending == nil)
	}
}
