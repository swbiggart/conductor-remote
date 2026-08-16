// Conductor's model menu, cached per agent_type (port of web/src/lib/models.ts).
// Reading the list live opens the real menu on the Mac and steals focus for
// seconds, so the picker paints from the last list and refreshes behind it —
// and a refresh that fails keeps the stale list on screen rather than
// emptying it. Never poll the live endpoint.

import Foundation

public struct ModelCache: Sendable {
	public struct CachedModels: Codable, Sendable, Equatable {
		public let models: [String]
		/// Epoch seconds when fetched (phone clock — only compared to itself).
		public let at: Double
	}

	public static let staleness: TimeInterval = 600
	private static let key = "conductor-remote-models"
	private let store: KeyValueStore

	public init(store: KeyValueStore) {
		self.store = store
	}

	public func cached(agentType: String) -> CachedModels? {
		all()[agentType]
	}

	public func isFresh(agentType: String, now: Date = Date()) -> Bool {
		guard let entry = cached(agentType: agentType) else { return false }
		return now.timeIntervalSince1970 - entry.at < Self.staleness
	}

	public func save(agentType: String, models: [String], now: Date = Date()) {
		var entries = all()
		entries[agentType] = CachedModels(models: models, at: now.timeIntervalSince1970)
		store.encode(entries, forKey: Self.key)
	}

	private func all() -> [String: CachedModels] {
		store.decode([String: CachedModels].self, forKey: Self.key) ?? [:]
	}
}
