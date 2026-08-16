// The composer: glass bar, growing field, and the agent capsules whose taps
// only *stage* changes. Staged = accent-filled capsule + a dot on the send
// button; the patch rides the next send and is applied before the prompt.
// Sends never lock the field — the optimistic bubble is the feedback.

import ConductorKit
import SwiftUI

struct ComposerView: View {
	let workspace: Workspace
	let session: Session
	@Environment(AppModel.self) private var model
	@State private var text = ""
	@State private var sendCount = 0

	private var staged: AgentPatch { model.agentDrafts.draft(sessionID: session.id) }
	private var canSend: Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.online
	}

	var body: some View {
		VStack(spacing: 6) {
			AgentBar(workspace: workspace, session: session)
			HStack(alignment: .bottom, spacing: 10) {
				TextField("Send a prompt…", text: $text, axis: .vertical)
					.lineLimit(1...8)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
					.onChange(of: text) {
						model.drafts.setDraft(text, workspaceID: workspace.id)
					}
				Button {
					send()
				} label: {
					Image(systemName: "arrow.up")
						.font(.body.weight(.bold))
						.frame(width: 34, height: 34)
						.background(canSend ? Color.accent : Color.surfaceRaised, in: Circle())
						.foregroundStyle(canSend ? .black : .secondary)
						.overlay(alignment: .topTrailing) {
							if !staged.isEmpty {
								Circle()
									.fill(Color.accent)
									.frame(width: 9, height: 9)
									.overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 1.5))
									.offset(x: 2, y: -2)
							}
						}
				}
				.disabled(!canSend)
				.sensoryFeedback(.impact(weight: .light), trigger: sendCount)
			}
			if !model.online {
				Text("Offline — drafts are saved, sending resumes when the relay is back")
					.font(.caption2)
					.foregroundStyle(Color.diffDelete)
			} else if !staged.isEmpty {
				Text("Settings apply with the next message")
					.font(.caption2)
					.foregroundStyle(Color.accent)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
		.task(id: workspace.id) {
			text = model.drafts.draft(workspaceID: workspace.id)
		}
	}

	private func send() {
		let outgoing = text
		text = ""
		sendCount += 1
		Task {
			await model.sends.send(sessionID: session.id, workspaceID: workspace.id, text: outgoing)
		}
	}
}

/// Model · effort · Plan · Fast capsules. Two distinct "active" looks: a
/// *staged* value fills accent (this send will change it); a value that is
/// already Conductor's own state tints surface. Flipping a staged value back
/// to the live one unstages it.
struct AgentBar: View {
	let workspace: Workspace
	let session: Session
	@Environment(AppModel.self) private var model
	@State private var models: [String] = []
	@State private var modelsStale = false
	@State private var loadingModels = false

	private var staged: AgentPatch { model.agentDrafts.draft(sessionID: session.id) }

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				modelPicker
				effortCapsule
				planCapsule
				fastCapsule
			}
			.padding(.horizontal, 2)
		}
		.sensoryFeedback(.selection, trigger: staged)
	}

	// MARK: Capsule styling

	private enum CapsuleState {
		case idle, on, staged
	}

	private func capsule(_ label: String, systemImage: String? = nil, state: CapsuleState) -> some View {
		HStack(spacing: 4) {
			if let systemImage {
				Image(systemName: systemImage).font(.caption2)
			}
			Text(label).font(.caption.weight(.medium))
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 5)
		.background(background(state), in: Capsule())
		.foregroundStyle(foreground(state))
	}

	private func background(_ state: CapsuleState) -> Color {
		switch state {
		case .idle: .surface
		case .on: .surfaceRaised
		case .staged: .accent
		}
	}

	private func foreground(_ state: CapsuleState) -> Color {
		switch state {
		case .idle: Color(.secondaryLabel)
		case .on: Color(.label)
		case .staged: .black
		}
	}

	// MARK: Model

	// No `primaryAction` on this Menu — with one, a tap runs the action and
	// only a long-press opens the picker, which is exactly the inconsistency
	// it shipped with. Tap opens the menu, the menu paints from the cached
	// list instantly, and the refresh (which steals focus on the Mac) runs
	// behind it only when the menu is actually opened.
	private var modelPicker: some View {
		Menu {
			menuRows
				.onAppear { refreshModels() }
		} label: {
			capsule(
				staged.model ?? Format.shortModel(session.model) ?? "model",
				systemImage: "cpu",
				state: staged.model != nil ? .staged : .on)
		}
	}

	@ViewBuilder private var menuRows: some View {
		if models.isEmpty {
			Text(loadingModels ? "Reading Conductor's menu…" : "No models yet")
		}
		ForEach(models, id: \.self) { name in
			Button {
				stageModel(name)
			} label: {
				if staged.model == name {
					Label(name, systemImage: "checkmark")
				} else {
					Text(name)
				}
			}
		}
		if modelsStale && !models.isEmpty {
			Divider()
			Text("Couldn't refresh — showing the last list.")
		}
	}

	private func stageModel(_ name: String) {
		model.agentDrafts.stage(sessionID: session.id) {
			$0.model = $0.model == name ? nil : name
		}
	}

	/// Seed from cache synchronously, then revalidate at most once per open.
	private func refreshModels() {
		let agentType = session.agentType ?? "claude"
		if models.isEmpty, let cached = model.modelCache.cached(agentType: agentType) {
			models = cached.models
		}
		guard !loadingModels, !model.modelCache.isFresh(agentType: agentType) || models.isEmpty else { return }
		loadingModels = true
		Task {
			let result = await model.models(session: session, workspaceID: workspace.id)
			if !result.models.isEmpty { models = result.models }
			modelsStale = result.stale
			loadingModels = false
		}
	}

	// MARK: Effort (tap cycles, like Conductor's own button)

	private static let efforts = ["low", "medium", "high", "xhigh", "max", "ultracode"]

	private var effortCapsule: some View {
		let live = session.claudeEffortLevel
		let shown = staged.effort ?? live ?? "effort"
		return Button {
			let current = staged.effort ?? live ?? "medium"
			let index = Self.efforts.firstIndex(of: current) ?? 1
			let next = Self.efforts[(index + 1) % Self.efforts.count]
			model.agentDrafts.stage(sessionID: session.id) {
				$0.effort = next == live ? nil : next
			}
		} label: {
			capsule(shown, systemImage: "gauge.with.needle", state: staged.effort != nil ? .staged : (live != nil ? .on : .idle))
		}
		.buttonStyle(.plain)
	}

	// MARK: Plan / Fast toggles

	private var planCapsule: some View {
		let live = session.permissionMode == "plan"
		let shown = staged.plan ?? live
		return Button {
			model.agentDrafts.stage(sessionID: session.id) {
				let next = !($0.plan ?? live)
				$0.plan = next == live ? nil : next
			}
		} label: {
			capsule("Plan", systemImage: "list.bullet.clipboard", state: staged.plan != nil ? .staged : (shown ? .on : .idle))
		}
		.buttonStyle(.plain)
	}

	private var fastCapsule: some View {
		let live = (session.fastMode ?? 0) != 0
		let shown = staged.fast ?? live
		return Button {
			model.agentDrafts.stage(sessionID: session.id) {
				let next = !($0.fast ?? live)
				$0.fast = next == live ? nil : next
			}
		} label: {
			capsule("Fast", systemImage: "bolt.fill", state: staged.fast != nil ? .staged : (shown ? .on : .idle))
		}
		.buttonStyle(.plain)
	}
}
