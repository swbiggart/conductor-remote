// One workspace's conversation: chat tab pills (only when >1), transcript,
// composer. The nav title is the workspace; tapping it opens the status picker.

import ConductorKit
import SwiftUI

struct SessionScreen: View {
	let workspaceID: String
	@Environment(AppModel.self) private var model
	@State private var pickedSessionID: String?
	@State private var showDiff = false
	@State private var showStatus = false
	@State private var creatingChat = false

	private var workspace: Workspace? { model.workspace(workspaceID) }
	private var sessions: [Session] { model.sessions(workspaceID: workspaceID) }

	/// Manual pick (reset per workspace by .id on this screen) → the tab this
	/// phone last viewed here → Conductor's active_session_id → first tab.
	/// Last-viewed outranks Conductor's because active_session_id tracks the
	/// *Mac* — often a different chat, sometimes a hidden one with no tab at
	/// all — and a gone tab falls through to the next rung rather than blank.
	private var activeSession: Session? {
		if let picked = pickedSessionID, let session = sessions.first(where: { $0.id == picked }) {
			return session
		}
		if let last = model.lastViewedChat(workspaceID: workspaceID),
			let session = sessions.first(where: { $0.id == last }) {
			return session
		}
		if let activeID = workspace?.activeSessionId, let session = sessions.first(where: { $0.id == activeID }) {
			return session
		}
		return sessions.first
	}

	var body: some View {
		VStack(spacing: 0) {
			if sessions.count > 1 || creatingChat {
				chatTabs
			}
			if let session = activeSession, let workspace {
				TranscriptView(workspace: workspace, session: session)
				ComposerView(workspace: workspace, session: session)
			} else if workspace?.state == "setting_up" {
				Spacer()
				VStack(spacing: 12) {
					ProgressView()
					Text("Setting up the worktree…")
						.font(.subheadline)
						.foregroundStyle(.secondary)
					if let pending = workspace?.pendingPrompt {
						PendingPromptCard(prompt: pending, workspaceID: workspaceID)
					}
				}
				Spacer()
			} else {
				Spacer()
				ProgressView()
				Spacer()
			}
		}
		.background(Color.appBackground)
		.navigationTitle(workspace.map(Format.workspaceLabel) ?? "")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				titleButton
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					showDiff = true
				} label: {
					Image(systemName: "plus.forwardslash.minus")
				}
				.accessibilityLabel("Changes")
			}
		}
		.fullScreenCover(isPresented: $showDiff) {
			if let workspace {
				DiffScreen(workspace: workspace)
			}
		}
		.sheet(isPresented: $showStatus) {
			if let workspace {
				StatusPickerSheet(workspace: workspace)
					.presentationDetents([.height(400)])
			}
		}
		// Two triggers for the same handoff on purpose: `.task(id:)` restarts
		// intermittently failed to fire on the nil→named transition (the
		// blank-transcript bug), and the model's own autoFocusSession is the
		// real safety net — this onChange is cheap redundancy on the view side.
		.onChange(of: activeSession?.id) {
			model.setFocus(workspaceID: workspaceID, sessionID: activeSession?.id)
			if let id = activeSession?.id {
				model.rememberViewedChat(workspaceID: workspaceID, sessionID: id)
			}
		}
		.task(id: activeSession?.id) {
			model.setFocus(workspaceID: workspaceID, sessionID: activeSession?.id)
			// Whatever ends up on screen is what re-opening this workspace restores.
			if let id = activeSession?.id {
				model.rememberViewedChat(workspaceID: workspaceID, sessionID: id)
			}
			#if DEBUG
			// Dev hook: CONDUCTOR_SEND fires one real send through the full
			// pipeline once the target session is on screen — simulator-only,
			// for end-to-end verification without driving the keyboard. The
			// consume() comes *after* the target filter, so a tick on the wrong
			// session can't spend the hook — and once per process, so opening a
			// second workspace can't re-send the prompt into its chat (the old
			// per-screen guard did exactly that).
			if let session = activeSession,
				ProcessInfo.processInfo.environment["CONDUCTOR_SEND"] != nil,
				ProcessInfo.processInfo.environment["CONDUCTOR_SESSION"].map({ $0 == session.id }) != false,
				let text = LaunchHooks.consume("CONDUCTOR_SEND") {
				await model.sends.send(sessionID: session.id, workspaceID: workspaceID, text: text)
			}
			#endif
		}
		.onChange(of: activeSession?.updatedAt) {
			markReadIfVisible()
		}
		.onAppear {
			markReadIfVisible()
			#if DEBUG
			// consume(): once per process, not per appearance — an unguarded env
			// read here re-opened the sheet on every workspace selection.
			switch LaunchHooks.consume("CONDUCTOR_SHOW") {
			case "diff": showDiff = true
			case "status": showStatus = true
			default: break
			}
			if let sid = LaunchHooks.consume("CONDUCTOR_SESSION") {
				pickedSessionID = sid
			}
			#endif
		}
	}

	/// Mark only the chat actually on screen — a sibling tab's badge isn't
	/// ours to clear.
	private func markReadIfVisible() {
		guard let session = activeSession else { return }
		model.markRead(session: session)
	}

	private var titleButton: some View {
		Button {
			showStatus = true
		} label: {
			VStack(spacing: 1) {
				HStack(spacing: 5) {
					Text(workspace.map(Format.workspaceLabel) ?? "")
						.font(.headline)
						.lineLimit(1)
					Image(systemName: StatusStyle.symbol(workspace.flatMap(Format.status)))
						.font(.caption)
						.foregroundStyle(Color.status(workspace.flatMap(Format.status)))
				}
				if let workspace {
					Text([workspace.repoName, workspace.branch, Format.shortModel(workspace.model)]
						.compactMap(\.self).joined(separator: " · "))
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
		}
		.buttonStyle(.plain)
	}

	private var chatTabs: some View {
		// ScrollViewReader: the selected pill must be *visible* — a selection
		// sitting off the right edge reads as "no tab selected".
		ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(sessions) { session in
						let active = session.id == activeSession?.id
						Button {
							pickedSessionID = session.id
						} label: {
							HStack(spacing: 5) {
								if model.isWorking(session: session) {
									Circle().fill(Color.working).frame(width: 6, height: 6)
								} else if model.isUnread(session: session) {
									Circle().fill(Color.accent).frame(width: 6, height: 6)
								}
								Text(session.title?.isEmpty == false ? session.title! : "Untitled")
									.font(.subheadline.weight(active ? .semibold : .regular))
									.lineLimit(1)
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.background(active ? Color.surfaceRaised : .clear, in: Capsule())
						}
						.buttonStyle(.plain)
						.id(session.id)
					}
					Button {
						newChat()
					} label: {
						Image(systemName: "plus")
							.font(.subheadline.weight(.semibold))
							.padding(.horizontal, 10)
							.padding(.vertical, 6)
					}
					.buttonStyle(.plain)
					.disabled(creatingChat)
					.accessibilityLabel("New chat, same files")
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 6)
			}
			.sensoryFeedback(.selection, trigger: pickedSessionID)
			.onChange(of: activeSession?.id, initial: true) {
				guard let id = activeSession?.id else { return }
				withAnimation(.easeOut(duration: 0.2)) {
					proxy.scrollTo(id, anchor: .center)
				}
			}
		}
	}

	private func newChat() {
		creatingChat = true
		Task {
			if let result = try? await model.newChat(workspaceID: workspaceID), let id = result.sessionId {
				pickedSessionID = id
			}
			creatingChat = false
		}
	}
}
