import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the relay lives and how to talk to it. Persisted in the Keychain by
/// the app (TokenStore); the Kit only ever holds it in memory.
public struct RelayCredentials: Sendable, Equatable, Codable {
	public let baseURL: URL
	public let token: String

	public init(baseURL: URL, token: String) {
		self.baseURL = baseURL
		self.token = token
	}
}

/// The three client budgets, mirroring web/src/lib/api.ts. The header value is
/// the relay's retry budget; the URLRequest timeout sits 5 s above it so the
/// phone never abandons work the relay is still doing ("the relay never
/// outlasts its caller" — the invariant is re-paired here, not hand-tuned).
public enum TimeoutTier: Sendable {
	case poll
	case action
	case send

	var headerMs: Int {
		switch self {
		case .poll: 6000
		case .action: 45000
		case .send: 75000
		}
	}

	var requestTimeout: TimeInterval { TimeInterval(headerMs) / 1000 + 5 }
}

public actor APIClient {
	private var credentials: RelayCredentials?
	private var etags: [String: String] = [:]
	private let session: URLSession
	private let decoder = JSONDecoder()
	private let encoder = JSONEncoder()

	/// `protocolClasses` is the test seam — URLProtocol stubs slot in there.
	public init(credentials: RelayCredentials? = nil, protocolClasses: [AnyClass]? = nil) {
		self.credentials = credentials
		let config = URLSessionConfiguration.ephemeral
		// Per-request timeouts come from TimeoutTier; this is only the outer bound.
		config.timeoutIntervalForRequest = 85
		config.waitsForConnectivity = false
		config.urlCache = nil
		config.requestCachePolicy = .reloadIgnoringLocalCacheData
		if let protocolClasses { config.protocolClasses = protocolClasses }
		self.session = URLSession(configuration: config)
	}

	public func setCredentials(_ credentials: RelayCredentials?) {
		self.credentials = credentials
		etags.removeAll()
	}

	// MARK: - Reads (GETs return nil on a 304 ETag hit)

	public func state() async throws -> StateResponse? {
		try await get("/api/state", tier: .poll)
	}

	public func sessions(workspaceID: String) async throws -> SessionsResponse? {
		try await get("/api/workspaces/\(escape(workspaceID))/sessions", tier: .poll)
	}

	/// Raw bytes of a transcript-referenced image (the relay only serves paths
	/// this chat's entries actually name). Bytes rather than a URL because the
	/// auth rides a header AsyncImage can't send.
	public func fileData(sessionID: String, path filePath: String) async throws -> Data {
		let escaped = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath
		let (data, http) = try await perform(
			try request(path: "/api/sessions/\(escape(sessionID))/file?path=\(escaped)", tier: .action, revalidate: false))
		guard http.statusCode == 200 else { throw serverError(data: data, status: http.statusCode) }
		return data
	}

	public func messages(sessionID: String, after cursor: Int64) async throws -> MessagesResponse? {
		// A cursor-0 fetch is a transcript that holds *nothing* — there is no
		// state a 304 could tell it to keep, so it must never be conditional.
		// An If-None-Match here (its ETag left over from an earlier life of the
		// chat) met a body that hadn't changed, and an idle chat's body never
		// changes — the transcript stayed blank on every poll, forever, with no
		// error anywhere. Live incremental polls (cursor > 0) keep the ETag: for
		// them "nothing changed" genuinely means "keep what you have".
		try await get("/api/sessions/\(escape(sessionID))/messages?after=\(cursor)", tier: .poll, revalidate: cursor > 0)
	}

	public func diff(workspaceID: String) async throws -> WorkspaceDiff? {
		// Action tier, not poll: a big worktree diff is a real git run on the
		// Mac (measured 25 s / 755 KB on a branch adding a whole app) and the
		// 6 s poll budget times it out forever. The polling loop only starts
		// the next fetch after this one returns, so slow diffs self-pace.
		try await get("/api/workspaces/\(escape(workspaceID))/diff", tier: .action)
	}

	public func logs(file: String?, limit: Int = 300) async throws -> LogsResponse? {
		var path = "/api/logs?limit=\(limit)"
		if let file { path += "&file=\(escape(file))" }
		return try await get(path, tier: .poll)
	}

	public func repos() async throws -> ReposResponse? {
		try await get("/api/repos", tier: .action)
	}

	/// Raw icon bytes, fetched with the auth *header* — never `?token=` in a
	/// URL, which would leak the token into Funnel/proxy logs (same rationale
	/// as the web client's object-URL dance).
	public func repoIcon(name: String) async throws -> Data {
		let (data, response) = try await perform(request(path: "/api/repos/\(escape(name))/icon", tier: .action))
		guard response.statusCode == 200 else { throw APIError.server(status: response.statusCode, message: "no icon") }
		return data
	}

	/// Live-enumerates Conductor's model menu — seconds of stolen Mac focus.
	/// Callers go through ModelCache; never poll this.
	public func models(sessionID: String, workspaceID: String) async throws -> ModelsResult {
		try decode(
			await perform(
				request(
					path: "/api/sessions/\(escape(sessionID))/models?workspaceId=\(escape(workspaceID))",
					tier: .action)),
			bodyCarriesErrors: true)
	}

	// MARK: - Writes

	/// The send. 200 = landed, 202 = parked behind the lock screen (decodes the
	/// same SendResult shape with parked:true — success-ish: the relay owns it
	/// now), 502 = failed with the reason in the body.
	public func sendPrompt(
		sessionID: String, workspaceID: String, text: String, agent: AgentPatch?
	) async throws -> SendResult {
		struct Body: Encodable {
			let text: String
			let workspaceId: String
			let agent: AgentPatch?
		}
		return try decode(
			await perform(
				request(
					path: "/api/sessions/\(escape(sessionID))/prompt", method: "POST",
					body: Body(text: text, workspaceId: workspaceID, agent: agent), tier: .send)),
			bodyCarriesErrors: true)
	}

	public func setAgent(sessionID: String, workspaceID: String, patch: AgentPatch) async throws -> AgentResult {
		struct Body: Encodable {
			let effort: String?
			let plan: Bool?
			let fast: Bool?
			let model: String?
			let workspaceId: String
		}
		let body = Body(
			effort: patch.effort, plan: patch.plan, fast: patch.fast, model: patch.model, workspaceId: workspaceID)
		return try decode(
			await perform(request(path: "/api/sessions/\(escape(sessionID))/agent", method: "POST", body: body, tier: .action)),
			bodyCarriesErrors: true)
	}

	public func newChat(workspaceID: String) async throws -> NewChatResult {
		try decode(
			await perform(
				request(path: "/api/workspaces/\(escape(workspaceID))/sessions", method: "POST", tier: .action)),
			bodyCarriesErrors: true)
	}

	public func createWorkspace(repo: String?, prompt: String?) async throws -> CreateWorkspaceResult {
		struct Body: Encodable {
			let repo: String?
			let prompt: String?
		}
		return try decode(
			await perform(request(path: "/api/workspaces", method: "POST", body: Body(repo: repo, prompt: prompt), tier: .action)),
			bodyCarriesErrors: true)
	}

	public func setStatus(workspaceID: String, status: WorkspaceStatus) async throws -> StatusResult {
		struct Body: Encodable {
			let status: String
		}
		return try decode(
			await perform(
				request(
					path: "/api/workspaces/\(escape(workspaceID))/status", method: "POST",
					body: Body(status: status.rawValue), tier: .action)),
			bodyCarriesErrors: true)
	}

	/// Merge failures come back as HTTP 409 with the reason in the body — a
	/// state conflict, not a transport error.
	public func merge(workspaceID: String) async throws -> MergeResult {
		try decode(
			await perform(request(path: "/api/workspaces/\(escape(workspaceID))/merge", method: "POST", tier: .action)),
			bodyCarriesErrors: true)
	}

	/// Dismiss an undelivered first prompt (relay-owned; we may only display or drop it).
	public func dismissFirstPrompt(workspaceID: String) async throws {
		_ = try okBody(
			await perform(request(path: "/api/workspaces/\(escape(workspaceID))/prompt", method: "DELETE", tier: .action)))
	}

	/// Dismiss all prompts parked for a chat.
	public func dismissParkedPrompts(sessionID: String) async throws {
		_ = try okBody(
			await perform(request(path: "/api/sessions/\(escape(sessionID))/prompt", method: "DELETE", tier: .action)))
	}

	// MARK: - Plumbing

	private func escape(_ component: String) -> String {
		component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
	}

	private func request(
		path: String, method: String = "GET", tier: TimeoutTier, revalidate: Bool = true
	) throws -> URLRequest {
		guard let credentials else { throw APIError.unauthorized }
		guard let url = URL(string: path, relativeTo: credentials.baseURL) else {
			throw APIError.offline("bad URL \(path)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = tier.requestTimeout
		request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
		// The relay caps its own internal retrying at this budget so it never
		// answers a caller that has already given up.
		request.setValue(String(tier.headerMs), forHTTPHeaderField: "x-client-timeout-ms")
		if method == "GET", revalidate, let etag = etags[path] {
			request.setValue(etag, forHTTPHeaderField: "If-None-Match")
		}
		return request
	}

	private func request(
		path: String, method: String, body: some Encodable, tier: TimeoutTier
	) throws -> URLRequest {
		var request = try request(path: path, method: method, tier: tier)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try encoder.encode(body)
		return request
	}

	private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			// Timeouts and transport errors all read as offline — the Mac may
			// just be asleep. Only the relay itself can log this phone out.
			throw APIError.offline(String(describing: error))
		}
		guard let http = response as? HTTPURLResponse else {
			throw APIError.offline("non-HTTP response")
		}
		if http.statusCode == 401 { throw APIError.unauthorized }
		return (data, http)
	}

	/// Decode a body that is meaningful on success *and* on relay-reported
	/// failure (SendResult on 200/202/502, MergeResult on 200/409, …). Statuses
	/// without a decodable body still become APIError.server.
	private func decode<T: Decodable>(
		_ pair: (Data, HTTPURLResponse), bodyCarriesErrors: Bool
	) throws -> T {
		let (data, http) = pair
		if let decoded = try? decoder.decode(T.self, from: data), bodyCarriesErrors || http.statusCode == 200 {
			return decoded
		}
		throw serverError(data: data, status: http.statusCode)
	}

	private func okBody(_ pair: (Data, HTTPURLResponse)) throws -> Bool {
		let (data, http) = pair
		guard (200..<300).contains(http.statusCode) else {
			throw serverError(data: data, status: http.statusCode)
		}
		return true
	}

	private func serverError(data: Data, status: Int) -> APIError {
		struct ErrorBody: Decodable {
			let error: String?
		}
		let message = (try? decoder.decode(ErrorBody.self, from: data))?.error
		if status == 200 { return .decoding(String(data: data.prefix(200), encoding: .utf8) ?? "unreadable") }
		return .server(status: status, message: message ?? "relay error \(status)")
	}

	/// GET with ETag revalidation: a 304 returns nil ("nothing changed") and
	/// the caller keeps its current value. This is what makes the 1–2.5 s polls
	/// nearly free over the Funnel. `revalidate: false` forces an unconditional
	/// fetch for a caller that holds no current value (a fresh transcript).
	private func get<T: Decodable>(_ path: String, tier: TimeoutTier, revalidate: Bool = true) async throws -> T? {
		let (data, http) = try await perform(try request(path: path, tier: tier, revalidate: revalidate))
		if http.statusCode == 304 { return nil }
		guard http.statusCode == 200 else { throw serverError(data: data, status: http.statusCode) }
		do {
			let decoded = try decoder.decode(T.self, from: data)
			// Only after a successful decode: an ETag recorded for a body the
			// caller never received makes the *next* fetch 304 — the failure
			// stops reproducing and the caller silently keeps nothing. (Seen
			// live as a permanently blank transcript with a clean log.)
			if let etag = http.value(forHTTPHeaderField: "Etag") { etags[path] = etag }
			return decoded
		} catch {
			throw APIError.decoding(String(describing: error))
		}
	}
}
