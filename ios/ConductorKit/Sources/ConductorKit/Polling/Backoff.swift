// Per-scope backoff: polls double their interval on consecutive failures and
// snap back on the first success. Capped low — the app's whole sync model is
// polling, so "offline" must recover within seconds of the Mac waking, not
// after a minutes-long backoff drains away.

import Foundation

public struct Backoff: Sendable, Equatable {
	public static let cap: TimeInterval = 30

	public let base: TimeInterval
	public private(set) var failures: Int = 0

	public init(base: TimeInterval) {
		self.base = base
	}

	public var interval: TimeInterval {
		guard failures > 0 else { return base }
		let scaled = base * pow(2, Double(min(failures, 10)))
		return min(scaled, Self.cap)
	}

	public mutating func recordSuccess() {
		failures = 0
	}

	public mutating func recordFailure() {
		failures += 1
	}
}
