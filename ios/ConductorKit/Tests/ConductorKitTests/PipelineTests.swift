import Foundation
import Testing

@testable import ConductorKit

private func message(_ rowid: Int64, _ role: Role, _ text: String, queued: Bool = false) -> TranscriptEntry {
	TranscriptEntry(
		id: "\(rowid)", rowid: rowid, role: role, text: text, tool: nil, detail: nil, error: nil,
		ts: "2026-08-15 10:00:00", queued: queued)
}

@Suite(.serialized) @MainActor struct TranscriptModelTests {
	@Test func cursorAdvancesOnlyWithEntries() {
		let model = TranscriptModel(sessionID: "s1")
		model.apply(MessagesResponse(entries: [message(5, .user, "hello")], cursor: 5))
		#expect(model.cursor == 5)
		// An empty response echoes the cursor — keep ours, don't regress.
		model.apply(MessagesResponse(entries: [], cursor: 0))
		#expect(model.cursor == 5)
		#expect(model.entries.count == 1)
	}

	@Test func applyReturnsNewUserTexts() {
		let model = TranscriptModel(sessionID: "s1")
		let texts = model.apply(
			MessagesResponse(
				entries: [message(1, .user, "do the thing"), message(2, .assistant, "on it")], cursor: 2))
		#expect(texts == ["do the thing"])
	}
}

@MainActor struct SendPipelineTests {
	private func makePipeline(
		host: String, handler: @escaping StubProtocol.Handler
	) -> (SendPipeline, AgentDraftStore) {
		let client = stubbedClient(host: host, handler: handler)
		let kv = InMemoryKeyValueStore()
		let drafts = AgentDraftStore(store: kv)
		return (SendPipeline(client: client, drafts: DraftStore(store: kv), agentDrafts: drafts), drafts)
	}


	@Test func deliveredThenReconciled() async {
		let (pipeline, _) = makePipeline(host: "send-ok.test") { _ in (200, [:], okSendBody) }
		await pipeline.send(sessionID: "s1", workspaceID: "w1", text: "  run tests  ")
		#expect(pipeline.pendings(sessionID: "s1").count == 1)
		// The real row arrives via the poll (trimmed by the relay) → retires the bubble.
		pipeline.reconcile(sessionID: "s1", userTexts: ["run tests"])
		#expect(pipeline.pendings(sessionID: "s1").isEmpty)
	}

	@Test func parkedRemovesPendingImmediately() async {
		let (pipeline, _) = makePipeline(host: "send-parked.test") { _ in
			(
				202, [:],
				Data(
					"""
					{"ok":false,"parked":true,"strategy":"applescript",
					 "queued":{"workspaceId":"w1","sessionId":"s1","text":"hi","status":"waiting",
					           "attempts":0,"createdAt":1},"error":"locked"}
					""".utf8)
			)
		}
		await pipeline.send(sessionID: "s1", workspaceID: "w1", text: "hi")
		// The relay owns it now; the bubble renders from parked_prompts instead.
		#expect(pipeline.pendings(sessionID: "s1").isEmpty)
	}

	@Test func failureKeepsTextWithRetry() async {
		let (pipeline, _) = makePipeline(host: "send-fail.test") { _ in
			(502, [:], Data(#"{"ok":false,"strategy":"applescript","error":"Conductor was asleep"}"#.utf8))
		}
		await pipeline.send(sessionID: "s1", workspaceID: "w1", text: "hi")
		let pending = pipeline.pendings(sessionID: "s1").first
		#expect(pending?.status == .failed("Conductor was asleep"))

		// Retry reuses the same bubble (same id), now succeeding.
		StubProtocol.register(host: "send-fail.test") { _ in (200, [:], okSendBody) }
		if let pending {
			await pipeline.send(sessionID: "s1", workspaceID: "w1", text: pending.text, retrying: pending.id)
		}
		#expect(pipeline.pendings(sessionID: "s1").first?.status == .sending)
		#expect(pipeline.pendings(sessionID: "s1").count == 1)
	}

	@Test func suspensionMarksUnconfirmedAndReconciles() async {
		let (pipeline, _) = makePipeline(host: "send-suspend.test") { _ in (200, [:], okSendBody) }
		await pipeline.send(sessionID: "s1", workspaceID: "w1", text: "hi")
		pipeline.markInFlightUnconfirmed()
		#expect(pipeline.pendings(sessionID: "s1").first?.status == .unconfirmed)
		// Reopen: the transcript shows the row — the send did land.
		pipeline.reconcile(sessionID: "s1", userTexts: ["hi"])
		#expect(pipeline.pendings(sessionID: "s1").isEmpty)
	}

	@Test func stagedSettingsRideAndClearKeyByKey() async {
		let sawAgent = CapturedRequest()
		let (pipeline, agentDrafts) = makePipeline(host: "send-agent.test") { request in
			sawAgent.store(request)
			return (200, [:], okSendBody)
		}
		agentDrafts.stage(sessionID: "s1") { $0.effort = "max" }
		await pipeline.send(sessionID: "s1", workspaceID: "w1", text: "go")
		// The staged patch rode along and was cleared once applied.
		#expect(agentDrafts.draft(sessionID: "s1").isEmpty)
		let body = sawAgent.request.flatMap(bodyData)
		let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
		#expect((json?["agent"] as? [String: Any])?["effort"] as? String == "max")
	}
}

/// httpBody is nil on requests captured via URLProtocol — the body arrives as a stream.
private func bodyData(_ request: URLRequest) -> Data? {
	if let body = request.httpBody { return body }
	guard let stream = request.httpBodyStream else { return nil }
	stream.open()
	defer { stream.close() }
	var data = Data()
	let size = 4096
	let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
	defer { buffer.deallocate() }
	while stream.hasBytesAvailable {
		let read = stream.read(buffer, maxLength: size)
		if read <= 0 { break }
		data.append(buffer, count: read)
	}
	return data
}

private let okSendBody = Data(#"{"ok":true,"strategy":"applescript","attempts":1}"#.utf8)
