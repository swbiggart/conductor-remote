// Linear-style five-state picker. Deliberately non-optimistic: the relay
// drives Conductor's real sidebar menu and only answers once the DB agrees
// (~15 s) — the selected row shows a spinner until then, and failure keeps
// the sheet with the reason.

import ConductorKit
import SwiftUI

struct StatusPickerSheet: View {
	let workspace: Workspace
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var applying: WorkspaceStatus?
	@State private var error: String?
	@State private var succeeded = false

	private var current: String? { Format.status(workspace) }

	var body: some View {
		NavigationStack {
			List {
				ForEach(WorkspaceStatus.allCases.filter { $0 != .settingUp }, id: \.rawValue) { status in
					Button {
						apply(status)
					} label: {
						HStack {
							Image(systemName: StatusStyle.symbol(status.rawValue))
								.foregroundStyle(Color.status(status.rawValue))
								.frame(width: 24)
							Text(StatusStyle.label(status.rawValue))
							Spacer()
							if applying == status {
								ProgressView().controlSize(.small)
							} else if current == status.rawValue {
								Image(systemName: "checkmark")
									.foregroundStyle(Color.accent)
							}
						}
					}
					.disabled(applying != nil)
				}
				if let error {
					Text(error)
						.font(.footnote)
						.foregroundStyle(Color.diffDelete)
				}
			}
			.navigationTitle("Status")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		.sensoryFeedback(.success, trigger: succeeded)
		.interactiveDismissDisabled(applying != nil)
		.onAppear {
			#if DEBUG
			// Dev hook: fire a real status change as if its row were tapped.
			// consume(): once per process — this is a real write, and unguarded it
			// re-fired on every later hand-opened sheet in the same process.
			if applying == nil,
				let raw = LaunchHooks.consume("CONDUCTOR_SET_STATUS"),
				let status = WorkspaceStatus(rawValue: raw) {
				apply(status)
			}
			#endif
		}
	}

	private func apply(_ status: WorkspaceStatus) {
		guard status.rawValue != current else {
			dismiss()
			return
		}
		applying = status
		error = nil
		Task {
			do {
				let result = try await model.setStatus(workspaceID: workspace.id, status: status)
				if result.ok {
					succeeded = true
					dismiss()
				} else {
					error = result.error ?? "Conductor didn't record the change."
				}
			} catch let apiError as APIError {
				error = apiError.message
			} catch {
				self.error = String(describing: error)
			}
			applying = nil
		}
	}
}
