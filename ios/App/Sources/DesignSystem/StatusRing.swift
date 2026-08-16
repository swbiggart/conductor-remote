// The Flighty move: status and identity fuse into one glanceable element. A
// thin ring around the repo avatar carries the PR state's color at rest; while
// the agent works it becomes a rotating comet-tail arc in working amber.
// Driven by TimelineView, not `repeatForever`, so it survives List cell reuse.

import ConductorKit
import SwiftUI

struct StatusRing: View {
	let color: Color
	let isWorking: Bool
	var lineWidth: CGFloat = 3

	var body: some View {
		if isWorking {
			TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
				let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
				Circle()
					.trim(from: 0, to: 0.72)
					.stroke(
						AngularGradient(
							colors: [Color.working.opacity(0), .working],
							center: .center,
							startAngle: .degrees(0),
							endAngle: .degrees(260)),
						style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
					)
					.rotationEffect(.degrees(phase * 360 - 90))
			}
		} else {
			Circle().strokeBorder(color, lineWidth: lineWidth)
		}
	}
}

/// Repo avatar with the four-way resolution chain (emoji → SF-symbolish named
/// glyph → relay-served file → GitHub owner avatar) and letter monogram
/// fallback, wrapped in the status ring.
struct RepoAvatar: View {
	let workspace: Workspace
	let iconData: Data?
	let isWorking: Bool
	var size: CGFloat = 44

	private var ringColor: Color { .pr(workspace.prStatus) }

	var body: some View {
		ZStack {
			Circle()
				.fill(Color.surfaceRaised)
			glyph
		}
		.frame(width: size, height: size)
		.overlay(
			StatusRing(color: ringColor, isWorking: isWorking)
				.frame(width: size + 8, height: size + 8)
		)
		.padding(4)
	}

	@ViewBuilder private var glyph: some View {
		switch workspace.icon {
		case .emoji(let value):
			Text(value).font(.system(size: size * 0.5))
		case .github(let owner):
			AsyncImage(url: URL(string: "https://github.com/\(owner).png?size=96")) { image in
				image.resizable().scaledToFill()
			} placeholder: {
				monogram
			}
			.frame(width: size, height: size)
			.clipShape(Circle())
		case .file:
			if let iconData, let image = UIImage(data: iconData) {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(width: size * 0.6, height: size * 0.6)
			} else {
				monogram
			}
		case .named, nil:
			monogram
		}
	}

	private var monogram: some View {
		Text(String((workspace.repoName ?? "?").prefix(1)).uppercased())
			.font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
			.foregroundStyle(.secondary)
	}
}
