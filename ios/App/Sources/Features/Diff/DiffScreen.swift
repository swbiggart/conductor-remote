// Changes: Working Copy structure — merge banner with one state-driven
// action, file list with counts, then the patch in per-file collapsible
// sections with tinted lines.

import ConductorKit
import SwiftUI

struct DiffScreen: View {
	let workspace: Workspace
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss

	private var diff: WorkspaceDiff? { model.diffs[workspace.id] }

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				List {
					if let diff {
						MergeBanner(workspace: workspace, diff: diff)
							.listRowBackground(Color.clear)
							.listRowSeparator(.hidden)

						Section("\(diff.files.count) files vs \(diff.base)") {
							ForEach(diff.files) { file in
								Button {
									withAnimation { proxy.scrollTo("file:\(file.path)", anchor: .top) }
								} label: {
									HStack {
										Text(file.path)
											.font(.footnote.monospaced())
											.lineLimit(1)
											.truncationMode(.middle)
										Spacer()
										Text("+\(file.added)")
											.font(.caption.monospacedDigit())
											.foregroundStyle(Color.diffAdd)
										Text("−\(file.removed)")
											.font(.caption.monospacedDigit())
											.foregroundStyle(Color.diffDelete)
									}
								}
							}
						}

						PatchView(patch: diff.patch, truncated: diff.truncated)
					} else {
						HStack {
							Spacer()
							ProgressView()
							Spacer()
						}
						.listRowBackground(Color.clear)
					}
				}
				.listStyle(.plain)
			}
			.background(Color.appBackground)
			.scrollContentBackground(.hidden)
			.navigationTitle("Changes · \(workspace.branch ?? "")")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
			.onAppear {
				model.setDiffVisible(workspace.id)
			}
			.onDisappear {
				model.setDiffVisible(nil)
			}
		}
	}
}

/// One primary action from state: merged receipt ≻ commit&push ≻ resolve ≻
/// merge-with-confirm ≻ draft note. "Commit & push" and "Resolve" are chat
/// messages to the agent — same as the PWA.
struct MergeBanner: View {
	let workspace: Workspace
	let diff: WorkspaceDiff
	@Environment(AppModel.self) private var model
	@State private var confirmMerge = false
	@State private var merging = false
	@State private var mergedLocally: String?
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			content
			if let error {
				Text(error)
					.font(.caption)
					.foregroundStyle(Color.diffDelete)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
		.sensoryFeedback(.success, trigger: mergedLocally)
	}

	@ViewBuilder private var content: some View {
		if workspace.prStatus == .merged || mergedLocally != nil {
			HStack {
				Label(mergedLocally.map { "Merged (\($0))" } ?? "Merged", systemImage: "checkmark.seal.fill")
					.foregroundStyle(Color.prMerged)
				Spacer()
				prLink
			}
		} else if diff.dirty || diff.unpushed {
			banner(
				icon: "exclamationmark.circle.fill", color: .working,
				title: diff.dirty ? "Uncommitted changes" : "Unpushed commits",
				button: "Commit & push"
			) {
				sendToAgent(
					"Commit all outstanding changes with a clear message and push the branch to the remote.")
			}
		} else if workspace.prStatus == .conflicts {
			banner(
				icon: "arrow.triangle.merge", color: .prConflicts,
				title: "PR has conflicts", button: "Resolve"
			) {
				sendToAgent(
					"Merge the base branch into this branch and resolve any conflicts, then push.")
			}
		} else if workspace.prStatus == .mergeable {
			banner(icon: "checkmark.circle.fill", color: .prMergeable, title: "Ready to merge", button: merging ? "Merging…" : "Merge") {
				confirmMerge = true
			}
			.confirmationDialog("Merge this PR?", isPresented: $confirmMerge) {
				Button("Merge", role: .destructive) { merge() }
			} message: {
				Text("Merges via gh with the repo's configured method.")
			}
		} else if workspace.prStatus == .draft {
			HStack {
				Label("Draft PR", systemImage: "doc.badge.clock")
					.foregroundStyle(Color.prDraft)
				Spacer()
				prLink
			}
		}
	}

	@ViewBuilder private var prLink: some View {
		if let prUrl = workspace.prUrl, let url = URL(string: prUrl) {
			Link(destination: url) {
				Text(workspace.prNumber.map { "#\($0) ↗" } ?? "PR ↗")
					.font(.footnote.weight(.medium))
			}
		}
	}

	private func banner(
		icon: String, color: Color, title: String, button: String, action: @escaping () -> Void
	) -> some View {
		HStack {
			Label(title, systemImage: icon)
				.foregroundStyle(color)
				.font(.subheadline.weight(.medium))
			Spacer()
			prLink
			Button(button, action: action)
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(merging)
		}
	}

	private func sendToAgent(_ text: String) {
		guard let sessionID = workspace.activeSessionId else { return }
		Task {
			await model.sends.send(sessionID: sessionID, workspaceID: workspace.id, text: text)
		}
	}

	private func merge() {
		merging = true
		error = nil
		Task {
			do {
				let result = try await model.merge(workspaceID: workspace.id)
				if result.ok {
					// Local receipt until the PR cache (≤60 s stale) catches up.
					mergedLocally = result.method ?? "merged"
				} else {
					error = result.error ?? "Merge failed."
				}
			} catch let apiError as APIError {
				error = apiError.message
			} catch {
				self.error = String(describing: error)
			}
			merging = false
		}
	}
}

/// The unified patch, split per file so each is a collapsible section with
/// its path pinned in the header.
struct PatchView: View {
	let patch: String
	let truncated: Bool

	private var files: [(path: String, lines: [String])] {
		var result: [(String, [String])] = []
		var currentPath: String?
		var lines: [String] = []
		for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
			if line.hasPrefix("diff --git") {
				if let path = currentPath { result.append((path, lines)) }
				lines = []
				// "diff --git a/x b/x" → "x"
				currentPath = line.split(separator: " ").last.map { String($0.dropFirst(2)) } ?? String(line)
			} else if currentPath != nil {
				lines.append(String(line))
			}
		}
		if let path = currentPath { result.append((path, lines)) }
		return result
	}

	var body: some View {
		ForEach(files, id: \.path) { file in
			Section {
				DisclosureGroup {
					VStack(alignment: .leading, spacing: 0) {
						ScrollView(.horizontal, showsIndicators: false) {
							VStack(alignment: .leading, spacing: 0) {
								ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
									Text(line.isEmpty ? " " : line)
										.font(.caption.monospaced())
										.foregroundStyle(lineColor(line))
										.frame(maxWidth: .infinity, alignment: .leading)
										.background(lineBackground(line))
								}
							}
						}
					}
				} label: {
					Text(file.path)
						.font(.footnote.monospaced().weight(.medium))
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.id("file:\(file.path)")
			}
		}
		if truncated {
			Text("… diff truncated — open in Conductor for the rest …")
				.font(.caption)
				.foregroundStyle(.tertiary)
				.frame(maxWidth: .infinity, alignment: .center)
				.listRowBackground(Color.clear)
		}
	}

	private func lineColor(_ line: String) -> Color {
		if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index") { return Color(.tertiaryLabel) }
		if line.hasPrefix("+") { return .diffAdd }
		if line.hasPrefix("-") { return .diffDelete }
		if line.hasPrefix("@@") { return .accent }
		return Color(.secondaryLabel)
	}

	private func lineBackground(_ line: String) -> Color {
		if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
		if line.hasPrefix("+") { return Color.diffAdd.opacity(0.08) }
		if line.hasPrefix("-") { return Color.diffDelete.opacity(0.08) }
		return .clear
	}
}
