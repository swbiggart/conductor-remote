// Start an agent from the phone: repo picker + optional first prompt. The
// relay answers as soon as the workspace row exists (~2 s); the first prompt
// is delivered by the relay's own queue once the worktree turns ready, and it
// shows up in the chat as a queued bubble until then.

import ConductorKit
import SwiftUI

struct NewWorkspaceSheet: View {
	let onCreated: (String) -> Void
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var repos: [Repo] = []
	@State private var selectedRepo = ""
	@State private var prompt = ""
	@State private var creating = false
	@State private var error: String?
	@FocusState private var promptFocused: Bool

	var body: some View {
		NavigationStack {
			Form {
				Section("Repository") {
					Picker("Repository", selection: $selectedRepo) {
						ForEach(repos) { repo in
							Text(repo.name).tag(repo.name)
						}
					}
					.pickerStyle(.menu)
				}
				Section("First prompt") {
					TextField("What should the agent do? (optional)", text: $prompt, axis: .vertical)
						.lineLimit(4...10)
						.focused($promptFocused)
				}
				if let error {
					Text(error)
						.font(.footnote)
						.foregroundStyle(Color.diffDelete)
				}
			}
			.navigationTitle("New workspace")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(creating ? "Creating…" : buttonLabel) {
						create()
					}
					.disabled(creating || selectedRepo.isEmpty)
				}
			}
			.task {
				if let response = try? await model.client.repos() {
					repos = response.repos
					// Default to the first repo so the target is never implicit.
					if selectedRepo.isEmpty { selectedRepo = repos.first?.name ?? "" }
				}
				promptFocused = true
			}
		}
	}

	private var buttonLabel: String {
		prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Create empty" : "Create & start"
	}

	private func create() {
		creating = true
		error = nil
		Task {
			do {
				let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
				let result = try await model.createWorkspace(
					repo: selectedRepo, prompt: trimmed.isEmpty ? nil : trimmed)
				if result.ok, let id = result.workspaceId {
					dismiss()
					onCreated(id)
				} else {
					error = result.error ?? "Conductor didn't create a workspace."
				}
			} catch let apiError as APIError {
				error = apiError.message
			} catch {
				self.error = String(describing: error)
			}
			creating = false
		}
	}
}
