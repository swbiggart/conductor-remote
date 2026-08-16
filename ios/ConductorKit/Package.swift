// swift-tools-version:6.2
// ConductorKit — everything testable in the iOS app, kept UIKit-free on purpose:
// the package also targets macOS so `swift build` / `swift test` run under bare
// Command Line Tools, before Xcode is installed (see CLAUDE.md ▸ ios).
import PackageDescription

let package = Package(
	name: "ConductorKit",
	platforms: [.iOS("26.0"), .macOS("15.0")],
	products: [.library(name: "ConductorKit", targets: ["ConductorKit"])],
	targets: [
		.target(name: "ConductorKit"),
		.testTarget(name: "ConductorKitTests", dependencies: ["ConductorKit"])
	]
)
