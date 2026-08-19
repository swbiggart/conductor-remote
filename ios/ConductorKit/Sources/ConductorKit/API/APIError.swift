import Foundation

/// Errors the UI branches on. The web client's rule survives: a timeout reads
/// as offline (the Mac may just be asleep), only a 401 reads as logged out.
public enum APIError: Error, Sendable, Equatable {
	/// Network failure or timeout — render as offline, keep the token.
	case offline(String)
	/// The relay rejected the token — clear it and return to pairing.
	case unauthorized
	/// Relay answered with a non-2xx and (when parseable) its `error` string.
	case server(status: Int, message: String)
	/// The body didn't decode — a relay/app version drift canary.
	case decoding(String)

	public var message: String {
		switch self {
		case .offline: "Can't reach the relay — the Mac may be asleep."
		case .unauthorized: "The relay rejected this phone's token."
		case .server(_, let message): message
		case .decoding(let detail): "Unexpected response from the relay (\(detail))."
		}
	}
}
