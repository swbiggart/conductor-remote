// swift-tools-version:6.2
// ConductorKit — everything testable in the iOS app, kept UIKit-free on purpose:
// the package also targets macOS so `swift build` / `swift test` run under bare
// Command Line Tools, before Xcode is installed (see CLAUDE.md ▸ ios).
import PackageDescription

let package = Package(
	name: "ConductorKit",
	platforms: [.iOS("26.0"), .macOS("15.0")],
	products: [.library(name: "ConductorKit", targets: ["ConductorKit"])],
	dependencies: [
		// The one external dependency, deliberately parsing-only: cmark-correct
		// GFM (tables, task lists, nested lists) feeding a pure block tree the
		// app renders with its own SwiftUI views. Apple-maintained.
		.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0")
	],
	targets: [
		.target(
			name: "ConductorKit",
			dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
		.testTarget(name: "ConductorKitTests", dependencies: ["ConductorKit"])
	]
)
