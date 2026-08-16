// The root store: owns the API client, the polling engine, the synced state
// and every client-side dictionary. Views read this; the engine writes it.
// Lives in the Kit (no UIKit anywhere) so the whole orchestration is testable
// under `swift test` on a Mac with no Xcode.

import Foundation
import Observation
import os

@MainActor
@Observable
public final class AppModel {
	/// Sync-path tracing: which focus is set, which scopes run, why a tick
	/// failed. `log stream --predicate 'subsystem == "com.conductor.remote"'`.
	static let syncLog = Logger(subsystem: "com.conductor.remote", category: "sync")
	// MARK: Identity

	public private(set) var credentials: RelayCredentials?
	@ObservationIgnored public let client: APIClient
	@ObservationIgnored private let tokenStore: TokenStore
	@ObservationIgnored private let keyValueStore: KeyValueStore
	@ObservationIgnored public private(set) var engine: PollingEngine!

	// MARK: Synced state

	public private(set) var workspaces: [Workspace] = []
	public private(set) var actuator: ActuatorInfo?
	public private(set) var relayVersion: String?
	public private(set) var update: UpdateStatus?
	public private(set) var online = true
	public private(set) var lastSyncAt: Date?
	/// True once the first /api/state has landed — before that the list shows
	/// the persisted snapshot, never a spinner.
	public private(set) var stateLoaded = false

	public private(set) var sessionsByWorkspace: [String: [Session]] = [:]
	public private(set) var diffs: [String: WorkspaceDiff] = [:]
	public private(set) var logsData: LogsResponse?
	@ObservationIgnored private var transcripts: [String: TranscriptModel] = [:]
	/// The chat tab *this phone* last had open, per workspace — persisted, because
	/// Conductor's own `active_session_id` tracks whatever the Mac has open (which
	/// can be a hidden chat with no tab at all) and makes a poor default here.
	@ObservationIgnored private var lastViewedChat: [String: String]

	// MARK: Client-owned state

	public private(set) var readMarks: ReadMarks
	@ObservationIgnored public let drafts: DraftStore
	@ObservationIgnored public let agentDrafts: AgentDraftStore
	@ObservationIgnored public let modelCache: ModelCache
	public let sends: SendPipeline

	/// Optimistic "the agent is working" bridge: set at send time, valid 15 s,
	/// covers the gap before the DB poll catches up. sessionID → expiry.
	private var workingHints: [String: Date] = [:]
	private static let workingHintTTL: TimeInterval = 15
	private static let readMarksKey = "conductor-remote-read"
	private static let snapshotKey = "conductor-remote-state-snapshot"
	private static let lastViewedKey = "conductor-remote-last-viewed-chat"

	/// Bumped when a workspace's turn verifiably ends (working → idle held for
	/// one more tick — same flap guard as the relay's push watcher). The UI
	/// hangs a success haptic off it.
	public private(set) var turnEndCount = 0
	private var lastSessionStatus: [String: String] = [:]
	private var pendingTurnEnd: Set<String> = []

	// MARK: - Init

	public init(tokenStore: TokenStore = KeychainTokenStore(), keyValueStore: KeyValueStore = UserDefaults.standard) {
		self.tokenStore = tokenStore
		self.keyValueStore = keyValueStore
		let credentials = tokenStore.load()
		self.credentials = credentials
		self.client = APIClient(credentials: credentials)
		self.drafts = DraftStore(store: keyValueStore)
		self.agentDrafts = AgentDraftStore(store: keyValueStore)
		self.modelCache = ModelCache(store: keyValueStore)
		self.readMarks = ReadMarks(marks: keyValueStore.decode([String: String].self, forKey: Self.readMarksKey) ?? [:])
		self.lastViewedChat = keyValueStore.decode([String: String].self, forKey: Self.lastViewedKey) ?? [:]
		self.sends = SendPipeline(client: client, drafts: drafts, agentDrafts: agentDrafts)
		// Cold launch paints from the last known state instantly (Flighty
		// rule: never a spinner over a list we already know).
		if let snapshot = keyValueStore.decode([Workspace].self, forKey: Self.snapshotKey) {
			self.workspaces = snapshot
		}
		self.engine = PollingEngine { [weak self] scope in
			await self?.tick(scope) ?? .failure
		}
		sends.onOutcome { [weak self] outcome in
			self?.handleSendOutcome(outcome)
		}
	}

	public var isPaired: Bool { credentials != nil }

	// MARK: - Pairing

	public func connect(_ credentials: RelayCredentials) async {
		self.credentials = credentials
		tokenStore.save(credentials)
		await client.setCredentials(credentials)
		stateLoaded = false
		recomputeScopes()
		engine.kick(.state)
	}

	/// 401 or explicit disconnect: drop the token, keep the local dictionaries
	/// (drafts and read marks survive re-pairing to the same relay).
	public func disconnect() async {
		credentials = nil
		tokenStore.clear()
		await client.setCredentials(nil)
		engine.setScopes([])
		workspaces = []
		sessionsByWorkspace = [:]
		transcripts = [:]
		stateLoaded = false
	}

	// MARK: - Scope focus (navigation → polling)

	// Scopes are *composed* from stored focus state, never overwritten by
	// whichever screen spoke last — a full-screen diff cover and the session
	// screen underneath it both contribute, and one re-firing its task must
	// not cancel the other's poll mid-flight (the bug that shipped first).
	private var focusWorkspaceID: String?
	private var focusSessionID: String?
	private var diffWorkspaceID: String?
	private var visibleLogsFile: String?
	private var logsVisible = false

	/// Navigation position: which workspace/chat is on screen.
	public func setFocus(workspaceID: String? = nil, sessionID: String? = nil) {
		Self.syncLog.info("setFocus ws=\(workspaceID ?? "nil", privacy: .public) session=\(sessionID ?? "nil", privacy: .public)")
		focusWorkspaceID = workspaceID
		focusSessionID = sessionID
		recomputeScopes()
	}

	/// The screen declares *workspace* focus the moment it appears but can only
	/// name a chat once sessions exist. That nil→named handoff used to ride a
	/// SwiftUI `.task(id:)` restart that intermittently never fired — traced
	/// live 2026-08-15: tabs rendered, no second setFocus, transcript blank
	/// until a send happened to kick the scope. So the model resolves it
	/// itself when a sessions poll lands for the focused workspace, using the
	/// same ladder SessionScreen renders with (last-viewed → Conductor's
	/// active → first); a screen or user pick that names a chat later simply
	/// overwrites this.
	private func autoFocusSession(workspaceID: String) {
		guard focusWorkspaceID == workspaceID, focusSessionID == nil else { return }
		let sessions = sessionsByWorkspace[workspaceID] ?? []
		let resolved =
			lastViewedChat[workspaceID].flatMap { id in sessions.first { $0.id == id } }
			?? workspaces.first(where: { $0.id == workspaceID })?.activeSessionId.flatMap { id in
				sessions.first { $0.id == id }
			}
			?? sessions.first
		guard let resolved else { return }
		Self.syncLog.info(
			"autoFocus ws=\(workspaceID.prefix(8), privacy: .public) → session=\(resolved.id.prefix(8), privacy: .public)")
		focusSessionID = resolved.id
		recomputeScopes()
	}

	/// The diff cover is on screen for this workspace (nil = closed).
	public func setDiffVisible(_ workspaceID: String?) {
		diffWorkspaceID = workspaceID
		recomputeScopes()
	}

	/// The log viewer is on screen, tailing `file` (nil file = the live ring).
	public func setLogsVisible(_ visible: Bool, file: String? = nil) {
		logsVisible = visible
		visibleLogsFile = file
		recomputeScopes()
	}

	private func recomputeScopes() {
		guard isPaired else {
			engine.setScopes([])
			return
		}
		var scopes: Set<PollingEngine.Scope> = [.state]
		if let focusWorkspaceID {
			scopes.insert(.sessions(workspaceID: focusWorkspaceID))
		}
		if let focusSessionID {
			scopes.insert(.messages(sessionID: focusSessionID))
		}
		if let diffWorkspaceID {
			scopes.insert(.diff(workspaceID: diffWorkspaceID))
		}
		if logsVisible {
			scopes.insert(.logs(file: visibleLogsFile))
		}
		Self.syncLog.info("scopes: \(scopes.map { String(describing: $0) }.sorted().joined(separator: " | "), privacy: .public)")
		engine.setScopes(scopes)
	}

	public func setActive(_ active: Bool) {
		engine.setActive(active)
		if !active { sends.markInFlightUnconfirmed() }
	}

	// MARK: - Reads

	public func workspace(_ id: String) -> Workspace? {
		workspaces.first { $0.id == id }
	}

	public func sessions(workspaceID: String) -> [Session] {
		sessionsByWorkspace[workspaceID] ?? []
	}

	public func transcript(sessionID: String) -> TranscriptModel {
		if let existing = transcripts[sessionID] { return existing }
		let model = TranscriptModel(sessionID: sessionID)
		transcripts[sessionID] = model
		return model
	}

	/// The chat this phone last viewed in a workspace, if it's still one of the
	/// workspace's tabs — the session screen's first choice when nothing is picked.
	public func lastViewedChat(workspaceID: String) -> String? {
		lastViewedChat[workspaceID]
	}

	public func rememberViewedChat(workspaceID: String, sessionID: String) {
		guard lastViewedChat[workspaceID] != sessionID else { return }
		lastViewedChat[workspaceID] = sessionID
		keyValueStore.encode(lastViewedChat, forKey: Self.lastViewedKey)
	}

	public func unreadCount(_ workspace: Workspace) -> Int {
		readMarks.unreadCount(workspace)
	}

	public func isUnread(session: Session) -> Bool {
		guard (session.unreadCount ?? 0) > 0 else { return false }
		return readMarks.isUnread(sessionID: session.id, at: session.updatedAt)
	}

	/// Working = the DB says so, or a fresh local hint bridges the poll gap.
	public func isWorking(session: Session) -> Bool {
		if session.working { return true }
		if let expiry = workingHints[session.id], expiry > Date() { return true }
		return false
	}

	/// Same question by id, across whatever workspace's sessions are cached.
	/// Nil when the session isn't cached anywhere — caller keeps its last state.
	private func sessionWorking(_ sessionID: String) -> Bool? {
		for sessions in sessionsByWorkspace.values {
			if let session = sessions.first(where: { $0.id == sessionID }) { return isWorking(session: session) }
		}
		return nil
	}

	/// What the elapsed timer counts from: `turn_started_at` when the DB
	/// agrees it's working (steering doesn't move it), else the local hint's
	/// start. Nil → show the dots with no timer (pre-May-2026 sessions).
	public func workingSince(session: Session) -> Date? {
		if session.working, let started = SQLiteDate.parse(session.turnStartedAt) { return started }
		if let expiry = workingHints[session.id], expiry > Date() {
			return expiry.addingTimeInterval(-Self.workingHintTTL)
		}
		return nil
	}

	/// Mark the chat actually on screen read — caller guarantees visibility.
	public func markRead(session: Session) {
		readMarks.markRead(sessionID: session.id, updatedAt: session.updatedAt)
		keyValueStore.encode(readMarks.marks, forKey: Self.readMarksKey)
	}

	// MARK: - Ticks

	private func tick(_ scope: PollingEngine.Scope) async -> PollingEngine.TickOutcome {
		do {
			switch scope {
			case .state:
				if let response = try await client.state() { applyState(response) }
				markSynced()
			case .sessions(let workspaceID):
				if let response = try await client.sessions(workspaceID: workspaceID) {
					sessionsByWorkspace[workspaceID] = response.sessions
					autoFocusSession(workspaceID: workspaceID)
					// A turn ending (or starting) between messages ticks must
					// collapse (or unfold) the live steps without new rows.
					for session in response.sessions {
						transcripts[session.id]?.setTrailingTurnActive(isWorking(session: session))
					}
				}
				markSynced()
			case .messages(let sessionID):
				let model = transcript(sessionID: sessionID)
				let cursor = model.cursor
				if let response = try await client.messages(sessionID: sessionID, after: cursor) {
					let newUserTexts = model.apply(response, trailingTurnActive: sessionWorking(sessionID))
					sends.reconcile(sessionID: sessionID, userTexts: newUserTexts)
					Self.syncLog.info(
						"messages \(sessionID.prefix(8), privacy: .public) after=\(cursor) got \(response.entries.count) → items \(model.items.count)"
					)
				} else {
					Self.syncLog.info("messages \(sessionID.prefix(8), privacy: .public) after=\(cursor) 304")
				}
				markSynced()
			case .diff(let workspaceID):
				if let response = try await client.diff(workspaceID: workspaceID) {
					diffs[workspaceID] = response
				}
			case .logs(let file):
				// Log failures never flip the offline banner — a missing log
				// file is not a dead relay (same carve-out as the PWA).
				if let response = try await client.logs(file: file) { logsData = response }
			}
			return .success
		} catch APIError.unauthorized {
			await disconnect()
			return .failure
		} catch {
			Self.syncLog.error("tick \(String(describing: scope), privacy: .public) failed: \(String(describing: error), privacy: .public)")
			if case .state = scope { online = false }
			return .failure
		}
	}

	private func markSynced() {
		online = true
		lastSyncAt = Date()
	}

	private func applyState(_ response: StateResponse) {
		detectTurnEnds(response.workspaces)
		workspaces = response.workspaces
		actuator = response.actuator
		relayVersion = response.version
		update = response.update
		stateLoaded = true
		keyValueStore.encode(response.workspaces, forKey: Self.snapshotKey)
	}

	/// working → idle must survive one more tick before it counts — a queued
	/// prompt restarting the turn is a flap, not a finish (the relay's push
	/// watcher applies the same rule).
	func detectTurnEnds(_ incoming: [Workspace]) {
		var fired = false
		for workspace in incoming {
			guard let status = workspace.sessionStatus else { continue }
			let previous = lastSessionStatus[workspace.id]
			if pendingTurnEnd.contains(workspace.id) {
				pendingTurnEnd.remove(workspace.id)
				if status == "idle" { fired = true }
			} else if previous == "working" && status == "idle" {
				pendingTurnEnd.insert(workspace.id)
			}
			lastSessionStatus[workspace.id] = status
		}
		if fired { turnEndCount += 1 }
	}

	private func handleSendOutcome(_ outcome: SendPipeline.SendOutcome) {
		switch outcome {
		case .delivered(let sessionID):
			workingHints[sessionID] = Date().addingTimeInterval(Self.workingHintTTL)
			engine.kick(.messages(sessionID: sessionID))
			engine.kick(.state)
		case .parked:
			// The parked bubble arrives via /api/state's parked_prompts.
			engine.kick(.state)
		case .failed:
			break
		}
	}

	// MARK: - Actions (thin wrappers that keep polls honest)

	public func dismissFirstPrompt(workspaceID: String) async throws {
		try await client.dismissFirstPrompt(workspaceID: workspaceID)
		engine.kick(.state)
	}

	public func dismissParkedPrompts(sessionID: String) async throws {
		try await client.dismissParkedPrompts(sessionID: sessionID)
		engine.kick(.state)
	}

	/// Non-optimistic by design: the relay drives Conductor's real menu and
	/// only answers once the DB agrees (~15 s). The UI shows a spinner on the
	/// current value until this returns.
	public func setStatus(workspaceID: String, status: WorkspaceStatus) async throws -> StatusResult {
		let result = try await client.setStatus(workspaceID: workspaceID, status: status)
		engine.kick(.state)
		return result
	}

	public func newChat(workspaceID: String) async throws -> NewChatResult {
		let result = try await client.newChat(workspaceID: workspaceID)
		engine.kick(.sessions(workspaceID: workspaceID))
		return result
	}

	public func merge(workspaceID: String) async throws -> MergeResult {
		let result = try await client.merge(workspaceID: workspaceID)
		engine.kick(.state)
		return result
	}

	public func createWorkspace(repo: String?, prompt: String?) async throws -> CreateWorkspaceResult {
		let result = try await client.createWorkspace(repo: repo, prompt: prompt)
		engine.kick(.state)
		return result
	}

	/// Model list with stale-while-revalidate against the expensive live read.
	public func models(session: Session, workspaceID: String) async -> (models: [String], stale: Bool, error: String?) {
		let agentType = session.agentType ?? "claude"
		let cached = modelCache.cached(agentType: agentType)?.models ?? []
		if modelCache.isFresh(agentType: agentType) {
			return (cached, false, nil)
		}
		do {
			let result = try await client.models(sessionID: session.id, workspaceID: workspaceID)
			if result.ok, let models = result.models {
				modelCache.save(agentType: agentType, models: models)
				return (models, false, nil)
			}
			return (cached, true, result.error ?? "Couldn't refresh — showing the last list.")
		} catch let error as APIError {
			return (cached, true, error.message)
		} catch {
			return (cached, true, String(describing: error))
		}
	}
}
