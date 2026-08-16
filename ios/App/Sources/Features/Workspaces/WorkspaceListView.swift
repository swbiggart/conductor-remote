// The board: every agent, one card each, grouped and live. Things 3 chrome,
// Flighty status rings, Linear grouping semantics.

import ConductorKit
import SwiftUI

struct WorkspaceListView: View {
	@Binding var selection: String?
	@Environment(AppModel.self) private var model
	@AppStorage("view.groupBy") private var groupBy = "status"
	@AppStorage("view.sortBy") private var sortBy = "updated"
	@AppStorage("view.repoFilter") private var repoFilter = ""
	@State private var showFilters = false
	@State private var showSettings = false
	@State private var showNewWorkspace = false
	@State private var collapsed: Set<String> = []

	var body: some View {
		List(selection: $selection) {
			if !model.online {
				ReconnectingBanner()
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
			}
			let groups = organize()
			ForEach(groups, id: \.key) { group in
				Section {
					if !collapsed.contains(group.key) {
						ForEach(group.workspaces) { workspace in
							WorkspaceRow(workspace: workspace)
								.tag(workspace.id)
						}
					}
				} header: {
					if groups.count > 1 || group.key != "all" {
						groupHeader(group)
					}
				}
			}
		}
		.listStyle(.plain)
		.background(Color.appBackground)
		.scrollContentBackground(.hidden)
		.navigationTitle("Workspaces")
		.overlay(alignment: .bottomTrailing) {
			newWorkspaceButton
		}
		.overlay {
			if model.workspaces.isEmpty {
				emptyState
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				Button {
					showSettings = true
				} label: {
					Image(systemName: "gearshape")
				}
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					showFilters = true
				} label: {
					Image(systemName: "line.3.horizontal.decrease.circle")
						.symbolVariant(repoFilter.isEmpty ? .none : .fill)
				}
			}
		}
		.sheet(isPresented: $showFilters) {
			FilterSheet(groupBy: $groupBy, sortBy: $sortBy, repoFilter: $repoFilter)
				.presentationDetents([.medium])
		}
		.sheet(isPresented: $showSettings) {
			SettingsView()
		}
		.sheet(isPresented: $showNewWorkspace) {
			NewWorkspaceSheet { workspaceID in
				selection = workspaceID
			}
		}
	}

	private var newWorkspaceButton: some View {
		Button {
			showNewWorkspace = true
		} label: {
			Image(systemName: "plus")
				.font(.title2.weight(.semibold))
				.frame(width: 56, height: 56)
		}
		.buttonStyle(.glassProminent)
		.clipShape(Circle())
		.padding(20)
		.accessibilityLabel("New workspace")
	}

	private var emptyState: some View {
		Group {
			if model.stateLoaded {
				ContentUnavailableView(
					"No workspaces",
					systemImage: "sparkles",
					description: Text("Tap + to start an agent."))
			} else if !model.online {
				ContentUnavailableView(
					"Connecting…",
					systemImage: "antenna.radiowaves.left.and.right",
					description: Text("Looking for the relay on your Mac."))
			} else {
				ProgressView()
			}
		}
	}

	private func groupHeader(_ group: WorkspaceGroup) -> some View {
		Button {
			withAnimation(.spring(duration: 0.35)) {
				if collapsed.contains(group.key) {
					collapsed.remove(group.key)
				} else {
					collapsed.insert(group.key)
				}
			}
		} label: {
			HStack(spacing: 6) {
				if group.key != "pinned" {
					Circle()
						.fill(Color.status(group.statusKey))
						.frame(width: 7, height: 7)
				} else {
					Image(systemName: "star.fill")
						.font(.system(size: 9))
						.foregroundStyle(Color.working)
				}
				Text(group.title.uppercased())
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
				Text("\(group.workspaces.count)")
					.font(.footnote.monospacedDigit())
					.foregroundStyle(.tertiary)
				Spacer()
				Image(systemName: "chevron.down")
					.font(.caption2.weight(.semibold))
					.foregroundStyle(.tertiary)
					.rotationEffect(.degrees(collapsed.contains(group.key) ? -90 : 0))
			}
		}
		.buttonStyle(.plain)
	}

	// MARK: Organizing (pinned float, group, filter, sort)

	struct WorkspaceGroup {
		let key: String
		let title: String
		let statusKey: String?
		var workspaces: [Workspace]
	}

	private func organize() -> [WorkspaceGroup] {
		var items = model.workspaces
		if !repoFilter.isEmpty {
			items = items.filter { $0.repoName == repoFilter }
		}
		items.sort { a, b in
			switch sortBy {
			case "created": a.createdAt > b.createdAt
			case "name": Format.workspaceLabel(a).localizedCaseInsensitiveCompare(Format.workspaceLabel(b)) == .orderedAscending
			default: a.updatedAt > b.updatedAt
			}
		}

		let pinned = items.filter { $0.pinnedAt != nil }
		let rest = items.filter { $0.pinnedAt == nil }
		var groups: [WorkspaceGroup] = []
		if !pinned.isEmpty {
			groups.append(WorkspaceGroup(key: "pinned", title: "Pinned", statusKey: nil, workspaces: pinned))
		}

		switch groupBy {
		case "repo":
			let byRepo = Dictionary(grouping: rest) { $0.repoName ?? "no repo" }
			for repo in byRepo.keys.sorted() {
				groups.append(WorkspaceGroup(key: "repo:\(repo)", title: repo, statusKey: nil, workspaces: byRepo[repo] ?? []))
			}
		case "none":
			if !rest.isEmpty {
				groups.append(WorkspaceGroup(key: "all", title: "All", statusKey: nil, workspaces: rest))
			}
		default:
			let byStatus = Dictionary(grouping: rest) { Format.status($0) ?? "backlog" }
			for status in byStatus.keys.sorted(by: { Format.statusRank($0) < Format.statusRank($1) }) {
				groups.append(
					WorkspaceGroup(
						key: "status:\(status)", title: StatusStyle.label(status), statusKey: status,
						workspaces: byStatus[status] ?? []))
			}
		}
		return groups
	}
}

struct ReconnectingBanner: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		HStack(spacing: 8) {
			ProgressView().controlSize(.small)
			if model.update?.available == true && model.update?.mode == "auto" {
				Text("Updating relay — reconnecting…")
			} else {
				Text("Reconnecting to the Mac…")
			}
		}
		.font(.footnote)
		.foregroundStyle(Color.working)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 6)
	}
}
