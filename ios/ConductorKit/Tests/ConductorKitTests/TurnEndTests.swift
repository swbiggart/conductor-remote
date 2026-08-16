import Foundation
import Testing

@testable import ConductorKit

/// A TokenStore that never touches the real Keychain.
struct NullTokenStore: TokenStore {
	func load() -> RelayCredentials? { nil }
	func save(_ credentials: RelayCredentials) {}
	func clear() {}
}

@MainActor struct TurnEndTests {
	private func workspace(_ id: String, status: String) throws -> Workspace {
		let json = """
			{"id":"\(id)","directory_name":null,"workspace_name":"W","branch":null,"pr_title":null,
			 "derived_status":null,"manual_status":null,"state":"ready",
			 "created_at":"2026-08-15 10:00:00","updated_at":"2026-08-15 11:00:00",
			 "unread_sessions":[],"pinned_at":null,"active_session_id":null,
			 "intended_target_branch":null,"repo_name":null,"session_status":"\(status)",
			 "session_title":null,"model":null,"context_used_percent":null,"icon":null}
			"""
		return try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
	}

	@Test func firesOnlyAfterConfirmationTick() throws {
		let model = AppModel(tokenStore: NullTokenStore(), keyValueStore: InMemoryKeyValueStore())
		model.detectTurnEnds([try workspace("w1", status: "working")])
		model.detectTurnEnds([try workspace("w1", status: "idle")])
		// One tick of idle is not a finish yet.
		#expect(model.turnEndCount == 0)
		model.detectTurnEnds([try workspace("w1", status: "idle")])
		#expect(model.turnEndCount == 1)
		// Staying idle fires nothing further.
		model.detectTurnEnds([try workspace("w1", status: "idle")])
		#expect(model.turnEndCount == 1)
	}

	@Test func flapIsDiscarded() throws {
		let model = AppModel(tokenStore: NullTokenStore(), keyValueStore: InMemoryKeyValueStore())
		model.detectTurnEnds([try workspace("w1", status: "working")])
		model.detectTurnEnds([try workspace("w1", status: "idle")])
		// A queued prompt restarted the turn before the confirmation tick.
		model.detectTurnEnds([try workspace("w1", status: "working")])
		#expect(model.turnEndCount == 0)
	}
}
