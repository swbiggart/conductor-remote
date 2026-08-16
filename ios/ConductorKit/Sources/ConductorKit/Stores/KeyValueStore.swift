import Foundation

/// The persistence seam for the small client-owned dictionaries (read marks,
/// drafts, staged agent settings, model cache). UserDefaults in the app,
/// in-memory in tests. Everything stored is tiny Codable JSON — deliberately
/// no database: these are exactly the PWA's localStorage keys.
public protocol KeyValueStore: Sendable {
	func data(forKey key: String) -> Data?
	func set(_ data: Data?, forKey key: String)
}

extension UserDefaults: KeyValueStore, @retroactive @unchecked Sendable {
	public func set(_ data: Data?, forKey key: String) {
		if let data {
			set(data as Any, forKey: key)
		} else {
			removeObject(forKey: key)
		}
	}
}

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
	private var storage: [String: Data] = [:]
	private let lock = NSLock()

	public init() {}

	public func data(forKey key: String) -> Data? {
		lock.withLock { storage[key] }
	}

	public func set(_ data: Data?, forKey key: String) {
		lock.withLock { storage[key] = data }
	}
}

extension KeyValueStore {
	func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
		guard let data = data(forKey: key) else { return nil }
		return try? JSONDecoder().decode(type, from: data)
	}

	func encode(_ value: (some Encodable)?, forKey key: String) {
		guard let value, let data = try? JSONEncoder().encode(value) else {
			set(nil, forKey: key)
			return
		}
		set(data, forKey: key)
	}
}
