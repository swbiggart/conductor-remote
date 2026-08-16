// The sync engine. There is no SSE or WebSocket anywhere in the relay — short
// polling with ETag revalidation *is* the protocol, so this engine treats it
// as one: a task per active scope, cadences matching the PWA's measured ones,
// backoff per scope, everything cancelled the moment the app leaves the
// foreground and refired instantly on return (no waiting out an interval).
//
// Navigation declares what it is looking at via setScopes; the engine diffs
// the set. Screens never own timers.

import Foundation

@MainActor
public final class PollingEngine {
	public enum Scope: Hashable, Sendable {
		case state
		case sessions(workspaceID: String)
		case messages(sessionID: String)
		case diff(workspaceID: String)
		case logs(file: String?)

		/// Cadences ported from the PWA (hooks.ts) — measured against real
		/// relay behaviour, not chosen. Don't re-guess them.
		var interval: TimeInterval {
			switch self {
			case .state: 2.5
			case .sessions: 2
			case .messages: 1
			case .diff: 5
			case .logs: 3
			}
		}
	}

	public enum TickOutcome: Sendable {
		case success
		case failure
	}

	public typealias Tick = @MainActor (Scope) async -> TickOutcome

	private let tick: Tick
	private var scopes: Set<Scope> = []
	private var tasks: [Scope: Task<Void, Never>] = [:]
	private var active = true

	public init(tick: @escaping Tick) {
		self.tick = tick
	}

	/// Declare the set of things currently on screen. Dropped scopes stop
	/// immediately; new ones fire their first tick right away.
	public func setScopes(_ next: Set<Scope>) {
		scopes = next
		guard active else { return }
		for (scope, task) in tasks where !next.contains(scope) {
			task.cancel()
			tasks[scope] = nil
		}
		for scope in next where tasks[scope] == nil {
			tasks[scope] = loop(scope)
		}
	}

	/// scenePhase wiring: background = stop burning radio on a screen nobody
	/// sees; foreground = every scope refires instantly.
	public func setActive(_ nowActive: Bool) {
		guard nowActive != active else { return }
		active = nowActive
		if nowActive {
			for scope in scopes where tasks[scope] == nil {
				tasks[scope] = loop(scope)
			}
		} else {
			for task in tasks.values {
				task.cancel()
			}
			tasks.removeAll()
		}
	}

	/// Refetch a scope now (after a send, a status change, a dismissal) without
	/// disturbing its cadence.
	public func kick(_ scope: Scope) {
		guard active, scopes.contains(scope) else { return }
		tasks[scope]?.cancel()
		tasks[scope] = loop(scope)
	}

	private func loop(_ scope: Scope) -> Task<Void, Never> {
		Task { [tick] in
			var backoff = Backoff(base: scope.interval)
			while !Task.isCancelled {
				switch await tick(scope) {
				case .success: backoff.recordSuccess()
				case .failure: backoff.recordFailure()
				}
				do {
					try await Task.sleep(for: .seconds(backoff.interval))
				} catch {
					return
				}
			}
		}
	}
}
