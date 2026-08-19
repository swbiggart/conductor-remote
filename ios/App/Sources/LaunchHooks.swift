#if DEBUG
import Foundation

/// Simulator launch hooks (`SIMCTL_CHILD_CONDUCTOR_* simctl launch …`) ride the
/// process environment, and iOS keeps that process alive across every
/// navigation and icon tap — so a hook read directly in `onAppear` re-fires
/// forever: the status sheet popping up on every workspace selection was
/// exactly this, and CONDUCTOR_SEND / CONDUCTOR_SET_STATUS would re-fire *real
/// writes*. Triggers must go through `consume`, which hands each key out once
/// per process. Plain filters (a hook that only narrows another hook's target)
/// may still read the environment directly.
@MainActor
enum LaunchHooks {
	private static var consumed: Set<String> = []

	static func consume(_ key: String) -> String? {
		guard let value = ProcessInfo.processInfo.environment[key], !consumed.contains(key) else { return nil }
		consumed.insert(key)
		return value
	}
}
#endif
