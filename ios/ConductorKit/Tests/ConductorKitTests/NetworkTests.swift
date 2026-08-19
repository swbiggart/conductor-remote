import Foundation
import Testing

@testable import ConductorKit

/// URLProtocol stub: handlers are registered per fake *host*, so suites
/// running in parallel never see each other's stubs.
final class StubProtocol: URLProtocol {
	typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

	private static let lock = NSLock()
	nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

	static func register(host: String, handler: @escaping Handler) {
		lock.withLock { handlers[host] = handler }
	}

	private static func handler(host: String?) -> Handler? {
		lock.withLock { host.flatMap { handlers[$0] } }
	}

	override static func canInit(with request: URLRequest) -> Bool { true }
	override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url, let handler = Self.handler(host: url.host) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		let (status, headers, body) = handler(request)
		let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

func stubbedClient(host: String, handler: @escaping StubProtocol.Handler) -> APIClient {
	StubProtocol.register(host: host, handler: handler)
	return APIClient(
		credentials: RelayCredentials(baseURL: URL(string: "https://\(host)")!, token: "t0k3n"),
		protocolClasses: [StubProtocol.self])
}

private let stateBody = Data(
	"""
	{"workspaces":[],"actuator":{"name":"applescript","caveat":"","precise":true,"available":true},
	 "version":"1.0.0"}
	""".utf8)

@Suite struct APIClientTests {
	@Test func sendsAuthAndTimeoutHeaders() async throws {
		let captured = CapturedRequest()
		let client = stubbedClient(host: "headers.test") { request in
			captured.store(request)
			return (200, [:], stateBody)
		}
		_ = try await client.state()
		let request = try #require(captured.request)
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k3n")
		// The relay's retry budget rides on every request; the poll tier is 6 s.
		#expect(request.value(forHTTPHeaderField: "x-client-timeout-ms") == "6000")
	}

	@Test func etagRoundTrip() async throws {
		let captured = CapturedRequest()
		let client = stubbedClient(host: "etag.test") { request in
			captured.store(request)
			if request.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"" {
				return (304, [:], Data())
			}
			return (200, ["Etag": "W/\"abc\""], stateBody)
		}
		let first = try await client.state()
		#expect(first != nil)
		// Second poll revalidates and gets a 304 → nil ("nothing changed").
		let second = try await client.state()
		#expect(second == nil)
		#expect(captured.request?.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"")
	}

	@Test func unauthorizedIsDistinct() async {
		let client = stubbedClient(host: "auth.test") { _ in
			(401, [:], Data(#"{"error":"unauthorized"}"#.utf8))
		}
		await #expect(throws: APIError.unauthorized) {
			_ = try await client.state()
		}
	}

	@Test func parkedSendDecodesOn202() async throws {
		let client = stubbedClient(host: "parked.test") { _ in
			(
				202, [:],
				Data(
					"""
					{"ok":false,"parked":true,"strategy":"applescript",
					 "queued":{"workspaceId":"w1","sessionId":"s1","text":"hi","status":"waiting",
					           "attempts":0,"createdAt":1723700000000,"reason":"Sends when the Mac is unlocked"},
					 "error":"The Mac is locked"}
					""".utf8)
			)
		}
		let result = try await client.sendPrompt(sessionID: "s1", workspaceID: "w1", text: "hi", agent: nil)
		#expect(result.parked == true)
		#expect(result.ok == false)
	}

	@Test func serverErrorCarriesRelayMessage() async {
		let client = stubbedClient(host: "conflict.test") { _ in
			(409, [:], Data(#"{"error":"worktree path unresolved"}"#.utf8))
		}
		await #expect(throws: APIError.server(status: 409, message: "worktree path unresolved")) {
			_ = try await client.diff(workspaceID: "w1")
		}
	}
}

/// Boxed capture for the stub handler (it runs off the test actor).
final class CapturedRequest: @unchecked Sendable {
	private let lock = NSLock()
	private var _request: URLRequest?

	var request: URLRequest? {
		lock.withLock { _request }
	}

	func store(_ request: URLRequest) {
		lock.withLock { _request = request }
	}
}
