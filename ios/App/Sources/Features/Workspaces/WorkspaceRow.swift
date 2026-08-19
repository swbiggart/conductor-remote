import ConductorKit
import SwiftUI

struct WorkspaceRow: View {
	let workspace: Workspace
	@Environment(AppModel.self) private var model
	@State private var iconData: Data?
	@State private var statusSheet = false
	// The text-size setting reaches this list as *density*, not font scale:
	// smaller settings tighten padding and shrink the avatar. Two lines per
	// row, always — model/context moved out of the list (they're in the chat
	// header where they're actionable).
	@AppStorage("ui.textScale") private var textScale = TextScale.system

	private var isWorking: Bool { workspace.sessionStatus == "working" }
	private var unread: Int { model.unreadCount(workspace) }
	private var settingUp: Bool { workspace.state == "setting_up" }
	private var density: ListDensity { textScale.listDensity }

	var body: some View {
		HStack(spacing: density.rowSpacing) {
			RepoAvatar(
				workspace: workspace, iconData: iconData, isWorking: isWorking,
				size: density.avatarSize)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					// A blocked agent outranks the unread dot: clipboard = plan
					// waiting for approval, red ? = question waiting for answers.
					if workspace.awaitingPlan {
						Image(systemName: "list.bullet.clipboard.fill")
							.font(.caption)
							.foregroundStyle(Color.accent)
					} else if workspace.awaitingQuestion {
						Image(systemName: "questionmark.circle.fill")
							.font(.caption)
							.foregroundStyle(Color.diffDelete)
					} else if unread > 0 {
						Circle().fill(Color.accent).frame(width: 6, height: 6)
					}
					Text(Format.workspaceLabel(workspace))
						.font(.subheadline.weight(unread > 0 ? .bold : .semibold))
						.lineLimit(1)
				}
				HStack(spacing: 6) {
					if settingUp {
						Text("SETTING UP")
							.font(.caption2.weight(.bold))
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(Color.working.opacity(0.18), in: Capsule())
							.foregroundStyle(Color.working)
					}
					if let repo = workspace.repoName {
						Text(repo)
							.font(.footnote)
							.foregroundStyle(.tertiary)
					}
					if let branch = workspace.branch {
						// Owner prefix dropped ("swbiggart/fix-x" → "fix-x") —
						// it's the same username on every row, pure noise here.
						Text(branch.contains("/") ? String(branch.split(separator: "/").dropFirst().joined(separator: "/")) : branch)
							.font(.footnote.monospaced())
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
				}
			}

			Spacer(minLength: 4)

			VStack(alignment: .trailing, spacing: 6) {
				if let updated = SQLiteDate.parse(workspace.updatedAt) {
					// One narrow unit ("4d ago"), not the two-unit live style —
					// the 2.5 s poll re-renders rows, so it stays fresh anyway.
					Text(updated, format: .relative(presentation: .numeric, unitsStyle: .narrow))
						.font(.caption.monospacedDigit())
						.foregroundStyle(.tertiary)
				}
				HStack(spacing: 4) {
					if unread > 1 {
						Text("\(unread)")
							.font(.caption2.weight(.bold))
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(Color.accent, in: Capsule())
							.foregroundStyle(.black)
					}
					Image(systemName: StatusStyle.symbol(Format.status(workspace)))
						.font(.footnote)
						.foregroundStyle(Color.status(Format.status(workspace)))
				}
			}
		}
		.padding(.vertical, density.rowVerticalPadding)
		.listRowBackground(Color.appBackground)
		.task(id: workspace.repoName) {
			await loadIcon()
		}
		.swipeActions(edge: .trailing) {
			Button {
				statusSheet = true
			} label: {
				Label("Status", systemImage: "flag")
			}
			.tint(.accent)
		}
		.contextMenu {
			if let prUrl = workspace.prUrl, let url = URL(string: prUrl) {
				Link(destination: url) {
					Label(workspace.prNumber.map { "PR #\($0)" } ?? "Open PR", systemImage: "arrow.up.right.square")
				}
			}
			Button {
				statusSheet = true
			} label: {
				Label("Set status", systemImage: "flag")
			}
			if let branch = workspace.branch {
				Button {
					UIPasteboard.general.string = branch
				} label: {
					Label("Copy branch", systemImage: "document.on.document")
				}
			}
		}
		.sheet(isPresented: $statusSheet) {
			StatusPickerSheet(workspace: workspace)
				.presentationDetents([.height(400)])
		}
	}

	private func loadIcon() async {
		guard case .file = workspace.icon, let repo = workspace.repoName, iconData == nil else { return }
		iconData = try? await model.client.repoIcon(name: repo)
	}
}
