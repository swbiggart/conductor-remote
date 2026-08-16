// Relay credentials live in the Keychain — the token is the only secret in
// the system (it gates a publicly-funneled relay), so it never touches
// UserDefaults. The Security framework exists on macOS too, which keeps this
// file inside the CLT-buildable package.

import Foundation
import Security

public protocol TokenStore: Sendable {
	func load() -> RelayCredentials?
	func save(_ credentials: RelayCredentials)
	func clear()
}

public struct KeychainTokenStore: TokenStore {
	private static let service = "conductor-remote"
	private static let account = "relay"

	public init() {}

	public func load() -> RelayCredentials? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: Self.service,
			kSecAttrAccount as String: Self.account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			let data = item as? Data
		else { return nil }
		return try? JSONDecoder().decode(RelayCredentials.self, from: data)
	}

	public func save(_ credentials: RelayCredentials) {
		guard let data = try? JSONEncoder().encode(credentials) else { return }
		let base: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: Self.service,
			kSecAttrAccount as String: Self.account
		]
		let update: [String: Any] = [kSecValueData as String: data]
		let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
		if status == errSecItemNotFound {
			var add = base
			add[kSecValueData as String] = data
			// Available after first unlock so a background reply action (phase
			// 5) can read it; never synced off the device.
			add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			SecItemAdd(add as CFDictionary, nil)
		}
	}

	public func clear() {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: Self.service,
			kSecAttrAccount as String: Self.account
		]
		SecItemDelete(query as CFDictionary)
	}
}

/// Parses what the user pastes or scans: the relay's own pairing URL
/// (`https://host/#token=<hex>`), any URL carrying `token=`, or a bare token
/// pasted next to a host. Mirrors parseTokenInput in web/src/lib/api.ts.
public enum PairingParser {
	public static func parse(_ input: String) -> RelayCredentials? {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
		guard let range = trimmed.range(of: "token=") else { return nil }
		let token = String(trimmed[range.upperBound...])
			.split(separator: "&").first.map(String.init) ?? ""
		guard !token.isEmpty else { return nil }
		// Origin = everything before the #fragment or ?query carrying the token.
		var origin = String(trimmed[..<range.lowerBound])
		while let last = origin.last, "#?&/".contains(last) {
			origin.removeLast()
		}
		guard let url = URL(string: origin), url.scheme?.hasPrefix("http") == true, url.host != nil else {
			return nil
		}
		return RelayCredentials(baseURL: url, token: token)
	}
}
