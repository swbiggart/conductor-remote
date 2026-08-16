// Mirrors the relay's JSON responses (src/reads.ts, src/git.ts, src/writes.ts),
// field-for-field with web/src/lib/types.ts. Snake_case keys are mapped with
// explicit CodingKeys — the relay mixes snake_case (DB rows) and camelCase
// (relay-owned objects), so a blanket key strategy would corrupt one side.
//
// Timestamp fields stay `String` wherever the product compares them lexically
// (read marks against `updated_at` — same-column comparisons only, never date
// math; see ReadMarks.swift). Display parsing goes through SQLiteDate.

import Foundation

/// How to render a repo's avatar. `file` is fetched from `/api/repos/:name/icon`
/// with the auth header; `github` loads `github.com/<owner>.png`. Unknown or
/// absent → letter monogram.
public enum RepoIcon: Sendable, Equatable {
	case emoji(String)
	case named(String)
	case file
	case github(owner: String)
}

extension RepoIcon: Codable {
	private enum CodingKeys: String, CodingKey {
		case kind, value, owner
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		switch try c.decode(String.self, forKey: .kind) {
		case "emoji": self = .emoji(try c.decode(String.self, forKey: .value))
		case "named": self = .named(try c.decode(String.self, forKey: .value))
		case "file": self = .file
		case "github": self = .github(owner: try c.decode(String.self, forKey: .owner))
		case let kind:
			throw DecodingError.dataCorruptedError(
				forKey: .kind, in: c, debugDescription: "unknown icon kind \(kind)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .emoji(let value):
			try c.encode("emoji", forKey: .kind)
			try c.encode(value, forKey: .value)
		case .named(let value):
			try c.encode("named", forKey: .kind)
			try c.encode(value, forKey: .value)
		case .file:
			try c.encode("file", forKey: .kind)
		case .github(let owner):
			try c.encode("github", forKey: .kind)
			try c.encode(owner, forKey: .owner)
		}
	}
}

/// GitHub PR state of the branch — drives the workspace ring colour.
/// Decoded leniently: an unknown future state must not sink the whole
/// `/api/state` payload, so it maps to nil at the use site instead.
public enum PrStatus: String, Codable, Sendable {
	case merged, draft, conflicts, mergeable
}

/// A chat Conductor flags unread; `at` is the session's `updated_at`.
/// Compare `at` only against a mark taken from the same column.
public struct UnreadSession: Codable, Sendable, Equatable {
	public let id: String
	public let at: String
}

public struct Workspace: Codable, Sendable, Identifiable, Equatable {
	public let id: String
	public let directoryName: String?
	public let workspaceName: String?
	public let branch: String?
	public let prTitle: String?
	public let derivedStatus: String?
	public let manualStatus: String?
	/// Conductor lifecycle: "ready" or "setting_up".
	public let state: String?
	public let createdAt: String
	public let updatedAt: String
	public let unreadSessions: [UnreadSession]
	public let pinnedAt: String?
	public let activeSessionId: String?
	public let intendedTargetBranch: String?
	public let repoName: String?
	public let sessionStatus: String?
	public let sessionTitle: String?
	public let model: String?
	public let contextUsedPercent: Double?
	public let icon: RepoIcon?
	public let prStatus: PrStatus?
	public let prNumber: Int?
	public let prUrl: String?
	/// A first prompt the relay hasn't delivered yet — rendered in this workspace's chat.
	public let pendingPrompt: PendingPrompt?
	/// Prompts parked behind the Mac's lock screen, each naming its chat.
	/// The relay omits the key entirely when empty.
	public let parkedPrompts: [PendingPrompt]

	private enum CodingKeys: String, CodingKey {
		case id
		case directoryName = "directory_name"
		case workspaceName = "workspace_name"
		case branch
		case prTitle = "pr_title"
		case derivedStatus = "derived_status"
		case manualStatus = "manual_status"
		case state
		case createdAt = "created_at"
		case updatedAt = "updated_at"
		case unreadSessions = "unread_sessions"
		case pinnedAt = "pinned_at"
		case activeSessionId = "active_session_id"
		case intendedTargetBranch = "intended_target_branch"
		case repoName = "repo_name"
		case sessionStatus = "session_status"
		case sessionTitle = "session_title"
		case model
		case contextUsedPercent = "context_used_percent"
		case icon
		case prStatus = "pr_status"
		case prNumber = "pr_number"
		case prUrl = "pr_url"
		case pendingPrompt = "pending_prompt"
		case parkedPrompts = "parked_prompts"
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		directoryName = try c.decodeIfPresent(String.self, forKey: .directoryName)
		workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
		branch = try c.decodeIfPresent(String.self, forKey: .branch)
		prTitle = try c.decodeIfPresent(String.self, forKey: .prTitle)
		derivedStatus = try c.decodeIfPresent(String.self, forKey: .derivedStatus)
		manualStatus = try c.decodeIfPresent(String.self, forKey: .manualStatus)
		state = try c.decodeIfPresent(String.self, forKey: .state)
		createdAt = try c.decode(String.self, forKey: .createdAt)
		updatedAt = try c.decode(String.self, forKey: .updatedAt)
		unreadSessions = try c.decodeIfPresent([UnreadSession].self, forKey: .unreadSessions) ?? []
		pinnedAt = try c.decodeIfPresent(String.self, forKey: .pinnedAt)
		activeSessionId = try c.decodeIfPresent(String.self, forKey: .activeSessionId)
		intendedTargetBranch = try c.decodeIfPresent(String.self, forKey: .intendedTargetBranch)
		repoName = try c.decodeIfPresent(String.self, forKey: .repoName)
		sessionStatus = try c.decodeIfPresent(String.self, forKey: .sessionStatus)
		sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
		model = try c.decodeIfPresent(String.self, forKey: .model)
		contextUsedPercent = try c.decodeIfPresent(Double.self, forKey: .contextUsedPercent)
		icon = try? c.decodeIfPresent(RepoIcon.self, forKey: .icon)
		prStatus = try? c.decodeIfPresent(PrStatus.self, forKey: .prStatus)
		prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
		prUrl = try c.decodeIfPresent(String.self, forKey: .prUrl)
		pendingPrompt = try c.decodeIfPresent(PendingPrompt.self, forKey: .pendingPrompt)
		parkedPrompts = try c.decodeIfPresent([PendingPrompt].self, forKey: .parkedPrompts) ?? []
	}
}

/// A prompt the relay is holding: a workspace's first prompt waiting on setup,
/// or one parked behind the lock screen (those carry `sessionId` and `reason`).
/// The relay owns delivery; the phone may only display, Retry (as an ordinary
/// send) or Dismiss (DELETE).
public struct PendingPrompt: Codable, Sendable, Equatable {
	public let workspaceId: String
	public let sessionId: String?
	public let text: String
	/// "waiting" | "failed" — failed means the relay gave up and `error` says why.
	public let status: String
	public let attempts: Int
	/// Epoch milliseconds (relay clock).
	public let createdAt: Double
	/// What it waits for, in words ("Sends when the Mac is unlocked"). First prompts omit it.
	public let reason: String?
	public let error: String?

	public var failed: Bool { status == "failed" }
}

public struct ActuatorInfo: Codable, Sendable, Equatable {
	public let name: String
	public let caveat: String
	public let precise: Bool
	public let available: Bool
}

public struct UpdateStatus: Codable, Sendable, Equatable {
	public let current: String
	public let latest: String?
	public let available: Bool
	public let checkedAt: Double?
	/// "off" | "check" | "auto"
	public let mode: String
	public let lastError: String?
}

public struct StateResponse: Codable, Sendable {
	public let workspaces: [Workspace]
	public let actuator: ActuatorInfo
	public let version: String?
	public let update: UpdateStatus?
}

public struct Session: Codable, Sendable, Identifiable, Equatable {
	public let id: String
	/// "working" | "idle" | "error" | null.
	public let status: String?
	public let title: String?
	public let model: String?
	/// "plan" when the chat is in plan mode, else "default".
	public let permissionMode: String?
	/// low | medium | high | xhigh | max | ultracode (null for non-Claude agents).
	public let claudeEffortLevel: String?
	/// 1 when Conductor's "Fast" toggle is on.
	public let fastMode: Int?
	/// claude | codex | cursor | acp.
	public let agentType: String?
	public let contextUsedPercent: Double?
	public let unreadCount: Int?
	public let createdAt: String
	public let updatedAt: String
	public let lastUserMessageAt: String?
	/// When the answer now in flight was dispatched — what the elapsed timer
	/// counts from. Deliberately not lastUserMessageAt: steering doesn't restart it.
	public let turnStartedAt: String?

	private enum CodingKeys: String, CodingKey {
		case id, status, title, model
		case permissionMode = "permission_mode"
		case claudeEffortLevel = "claude_effort_level"
		case fastMode = "fast_mode"
		case agentType = "agent_type"
		case contextUsedPercent = "context_used_percent"
		case unreadCount = "unread_count"
		case createdAt = "created_at"
		case updatedAt = "updated_at"
		case lastUserMessageAt = "last_user_message_at"
		case turnStartedAt = "turn_started_at"
	}

	public var working: Bool { status == "working" }
}

/// What the phone can change about a chat's agent (mirrors AgentOptions in src/writes.ts).
public struct AgentPatch: Codable, Sendable, Equatable {
	public var effort: String?
	public var plan: Bool?
	public var fast: Bool?
	public var model: String?

	public init(effort: String? = nil, plan: Bool? = nil, fast: Bool? = nil, model: String? = nil) {
		self.effort = effort
		self.plan = plan
		self.fast = fast
		self.model = model
	}

	public var isEmpty: Bool { effort == nil && plan == nil && fast == nil && model == nil }
}

public struct AgentResult: Codable, Sendable {
	public let ok: Bool
	public let session: Session?
	public let error: String?
}

public struct ModelsResult: Codable, Sendable {
	public let ok: Bool
	public let models: [String]?
	public let error: String?
}

public struct Repo: Codable, Sendable, Identifiable, Equatable {
	public let name: String
	/// Absolute checkout path — what create-workspace targets.
	public let rootPath: String?
	public let defaultBranch: String?
	public let icon: RepoIcon?

	public var id: String { name }

	private enum CodingKeys: String, CodingKey {
		case name
		case rootPath = "root_path"
		case defaultBranch = "default_branch"
		case icon
	}
}

public struct ReposResponse: Codable, Sendable {
	public let repos: [Repo]
}

public struct CreateWorkspaceResult: Codable, Sendable {
	public let ok: Bool
	public let workspaceId: String?
	public let workspace: Workspace?
	/// Echoed back — the relay delivers it itself once the worktree is ready.
	public let pendingPrompt: String?
	public let sent: Bool?
	public let warning: String?
	public let error: String?
}

public struct SessionsResponse: Codable, Sendable {
	public let sessions: [Session]
}

public enum Role: String, Codable, Sendable {
	case user, assistant, tool, thinking, system
}

public struct TranscriptEntry: Codable, Sendable, Identifiable, Equatable {
	/// "<row.id>:<index>" for multi-entry rows, plain row id otherwise. Unique
	/// only together with `rowid` — key UI lists on `key`, not `id`.
	public let id: String
	public let rowid: Int64
	public let role: Role
	public let text: String
	public let tool: String?
	/// Mono secondary line for tool rows (command, path, pattern, …).
	public let detail: String?
	/// True when this row is a failed tool result.
	public let error: Bool?
	/// SQLite "yyyy-MM-dd HH:mm:ss", UTC without T/Z — parse via SQLiteDate.
	public let ts: String
	/// Typed into Conductor's queue but not yet dispatched to the agent.
	public let queued: Bool
	/// Files the user attached on the Mac — rendered as chips under the bubble.
	public let attachments: [AttachmentRef]?
	/// Conductor's turn id — groups a turn's entries for the end-of-turn summary.
	public let turnId: String?
	/// A Task/Agent tool_use's own id — the id its sub-agent's entries reference.
	public let agentId: String?
	/// Set on every entry a sub-agent emitted: the spawning Task's id.
	public let parentToolUseId: String?
	/// Line counts for a file-editing tool call, plus the clipped hunk behind the chip.
	public let adds: Int?
	public let dels: Int?
	public let hunk: String?

	/// Stable list key (mirrors the PWA's `${rowid}-${id}`).
	public var key: String { "\(rowid)-\(id)" }
	public var isError: Bool { error == true }

	/// Explicit because the new optional fields default to nil — the memberwise
	/// init would force every construction site (tests) to name all of them.
	public init(
		id: String, rowid: Int64, role: Role, text: String, tool: String?, detail: String?, error: Bool?,
		ts: String, queued: Bool, attachments: [AttachmentRef]? = nil, turnId: String? = nil,
		adds: Int? = nil, dels: Int? = nil, hunk: String? = nil,
		agentId: String? = nil, parentToolUseId: String? = nil
	) {
		self.id = id
		self.rowid = rowid
		self.role = role
		self.text = text
		self.tool = tool
		self.detail = detail
		self.error = error
		self.ts = ts
		self.queued = queued
		self.attachments = attachments
		self.turnId = turnId
		self.adds = adds
		self.dels = dels
		self.hunk = hunk
		self.agentId = agentId
		self.parentToolUseId = parentToolUseId
	}
}

/// One attachment reference from a user prompt: display name + worktree-relative path.
public struct AttachmentRef: Codable, Sendable, Equatable, Identifiable {
	public let name: String
	public let path: String
	public var id: String { path }
}

public struct MessagesResponse: Codable, Sendable {
	public let entries: [TranscriptEntry]
	public let cursor: Int64
}

public struct DiffFile: Codable, Sendable, Identifiable, Equatable {
	public let path: String
	public let added: Int
	public let removed: Int

	public var id: String { path }
}

public struct WorkspaceDiff: Codable, Sendable, Equatable {
	public let base: String
	public let mergeBase: String?
	public let files: [DiffFile]
	public let patch: String
	public let truncated: Bool
	/// Uncommitted changes in the worktree (drives "Commit & push").
	public let dirty: Bool
	/// Commits on HEAD not on the remote-tracking branch (also drives "Commit & push").
	public let unpushed: Bool
}

public struct SendResult: Codable, Sendable {
	public let ok: Bool
	public let strategy: String?
	public let warning: String?
	public let error: String?
	/// Runs the relay needed to land the prompt (it retries internally).
	public let attempts: Int?
	/// The Mac is locked: the relay parked the prompt and delivers it on unlock.
	public let parked: Bool?
	/// The parked entry, when `parked` — the shape `/api/state` will carry.
	public let queued: PendingPrompt?
}

public struct NewChatResult: Codable, Sendable {
	public let ok: Bool
	public let sessionId: String?
	public let error: String?
}

public enum LogLevel: String, Codable, Sendable {
	case info, warn, error
}

/// One relay log line. `t` is null for unstamped on-disk lines.
public struct LogEntry: Codable, Sendable, Equatable {
	public let t: Double?
	public let level: LogLevel
	public let text: String
}

public struct LogFileInfo: Codable, Sendable, Equatable {
	public let name: String
	public let size: Int
	public let modifiedAt: Double?
}

public struct LogsResponse: Codable, Sendable {
	/// "live" = the relay process's captured console; otherwise the tailed file name.
	public let source: String
	/// False when the relay isn't the LaunchAgent — files belong to a different process.
	public let managed: Bool
	public let startedAt: Double
	/// Relay clock, so ages render right even if the phone's clock disagrees.
	public let now: Double
	public let files: [LogFileInfo]
	public let entries: [LogEntry]
}

public struct MergeResult: Codable, Sendable {
	public let ok: Bool
	public let branch: String?
	/// "squash" | "merge" | "rebase"
	public let method: String?
	public let error: String?
}

public struct StatusResult: Codable, Sendable {
	public let ok: Bool
	/// The workspace as re-read *after* Conductor recorded the change.
	public let workspace: Workspace?
	public let error: String?
}

/// The five manual workspace statuses, in Conductor's own spelling and sidebar
/// order ("canceled" is taken from Conductor's menu — don't correct it).
public enum WorkspaceStatus: String, CaseIterable, Sendable {
	case done
	case inReview = "in-review"
	case inProgress = "in-progress"
	case settingUp = "setting-up"
	case backlog
	case canceled
}
