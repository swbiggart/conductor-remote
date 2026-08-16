import ConductorKit
import SwiftUI

@main
struct ConductorRemoteApp: App {
	@State private var model = AppModel()
	@Environment(\.scenePhase) private var scenePhase

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(model)
				.preferredColorScheme(.dark)
				.tint(.accent)
		}
		.onChange(of: scenePhase) { _, phase in
			// Background = stop polling a screen nobody sees and flip in-flight
			// sends to "unconfirmed" (the transcript resolves them on reopen).
			model.setActive(phase == .active)
		}
	}
}

struct RootView: View {
	@Environment(AppModel.self) private var model
	@AppStorage("ui.textScale") private var textScale = TextScale.system

	var body: some View {
		content
			// Settings ▸ Appearance ▸ Text size: one Dynamic Type override for
			// the whole app; `system` leaves the device's own setting in charge.
			.dynamicTypeSize(textScale.dynamicTypeSize.map { $0...$0 } ?? DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
			.task {
				// Dev hook: `SIMCTL_CHILD_CONDUCTOR_PAIR="http://…#token=…" simctl launch …`
				// pairs a fresh simulator without driving the text field by hand.
				#if DEBUG
				if let raw = ProcessInfo.processInfo.environment["CONDUCTOR_PAIR"],
					let credentials = PairingParser.parse(raw),
					credentials != model.credentials {
					await model.connect(credentials)
				}
				#endif
			}
	}

	@ViewBuilder private var content: some View {
		Group {
			if model.isPaired {
				MainSplitView()
			} else {
				PairingView()
			}
		}
		// A turn verifiably finished somewhere while the app is open.
		.sensoryFeedback(.success, trigger: model.turnEndCount)
	}
}

/// Workspace list → session detail. Collapses to a stack on iPhone; free
/// two-pane on iPad. No tab bar — this app has one axis.
struct MainSplitView: View {
	@Environment(AppModel.self) private var model
	@State private var selectedWorkspaceID: String?

	var body: some View {
		NavigationSplitView {
			WorkspaceListView(selection: $selectedWorkspaceID)
		} detail: {
			if let id = selectedWorkspaceID, let workspace = model.workspace(id) {
				SessionScreen(workspaceID: workspace.id)
					.id(workspace.id)
			} else {
				ContentUnavailableView(
					"Select a workspace",
					systemImage: "square.grid.2x2",
					description: Text("Your agents appear in the sidebar."))
			}
		}
		.task(id: selectedWorkspaceID) {
			// The one place navigation becomes poll scopes; the session screen
			// refines it with the active chat id.
			if selectedWorkspaceID == nil {
				model.setFocus()
			}
		}
		.onAppear {
			#if DEBUG
			// Dev hook: deep-link straight to a workspace for simulator runs.
			// consume(): once per process, or re-appearing would re-select it.
			if let id = LaunchHooks.consume("CONDUCTOR_OPEN") {
				selectedWorkspaceID = id
			}
			// Dev hook: "seconds:workspaceID" — navigate to a *second* workspace
			// after a delay, reproducing hands-free the in-process navigation a
			// tap performs (a fresh process's first screen behaves differently).
			if let spec = LaunchHooks.consume("CONDUCTOR_OPEN_THEN") {
				let parts = spec.split(separator: ":", maxSplits: 1)
				if parts.count == 2, let delay = Double(parts[0]) {
					let target = String(parts[1])
					Task {
						try? await Task.sleep(for: .seconds(delay))
						selectedWorkspaceID = target
					}
				}
			}
			#endif
		}
	}
}
