// The conversation surface. Claude-iOS rhythm: user turns in tinted bubbles,
// assistant prose full-width with no bubble; agent activity folded into
// live-updating "N steps" disclosures; the working turn ends with the
// three-dot row and an elapsed timer counting from turn_started_at.

import ConductorKit
import SwiftUI

struct TranscriptView: View {
	let workspace: Workspace
	let session: Session
	@Environment(AppModel.self) private var model
	@State private var navIndex: Int?

	private var transcript: TranscriptModel { model.transcript(sessionID: session.id) }

	/// Relay-owned prompts to overlay: the workspace's undelivered first
	/// prompt plus anything parked for this chat — deduped against rows that
	/// already made it into the transcript and against local pendings.
	private var queuedPrompts: [PendingPrompt] {
		var prompts: [PendingPrompt] = []
		if let first = workspace.pendingPrompt { prompts.append(first) }
		prompts.append(contentsOf: workspace.parkedPrompts.filter { $0.sessionId == session.id })
		let inTranscript = Set(
			transcript.entries.filter { $0.role == .user }
				.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
		let inFlight = Set(
			model.sends.pendings(sessionID: session.id)
				.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
		return prompts.filter {
			let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
			return !inTranscript.contains(text) && !inFlight.contains(text)
		}
	}

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 10) {
					ForEach(transcript.items) { item in
						itemView(item)
					}
					ForEach(queuedPrompts, id: \.text) { prompt in
						QueuedPromptBubble(prompt: prompt)
					}
					ForEach(model.sends.pendings(sessionID: session.id)) { pending in
						PendingBubble(pending: pending)
					}
					if model.isWorking(session: session) {
						WorkingRow(since: model.workingSince(session: session))
							.id("working")
					}
					Color.clear.frame(height: 4).id("bottom")
				}
				.padding(.horizontal, 16)
				.padding(.top, 8)
			}
			.defaultScrollAnchor(.bottom)
			.scrollDismissesKeyboard(.interactively)
			.background(Color.appBackground)
			.overlay(alignment: .bottomTrailing) {
				MessageNavigator(
					entries: transcript.userEntries, index: $navIndex,
					jump: { key in
						withAnimation(.easeOut(duration: 0.3)) {
							proxy.scrollTo(key, anchor: .center)
						}
					})
			}
		}
	}

	@ViewBuilder private func itemView(_ item: TranscriptItem) -> some View {
		switch item {
		case .message(let entry):
			switch entry.role {
			case .user:
				UserBubble(entry: entry, sessionID: session.id)
					.id(entry.key)
			case .assistant:
				AssistantProse(text: entry.text)
			case .system:
				// Error notices get Conductor's own treatment (the bordered mono
				// capsule); unknown-frame raw dumps keep the dim centered line so
				// Conductor drift still shows as itself.
				if entry.isError {
					ErrorNotice(entry: entry, duration: noticeDuration(entry))
				} else {
					Text(entry.text)
						.font(.caption)
						.foregroundStyle(.tertiary)
						.frame(maxWidth: .infinity, alignment: .center)
				}
			default:
				EmptyView()
			}
		case .step(let entry):
			StepRow(entry: entry, sessionID: session.id)
		case .steps(let group):
			StepGroupView(group: group, sessionID: session.id)
		case .agentSteps(let run):
			AgentGroupView(run: run, sessionID: session.id)
		case .turnSummary(let summary):
			TurnSummaryRow(summary: summary)
		}
	}

	/// The rough turn length the Mac shows under its interruption capsule:
	/// this error row's time minus the nearest earlier user prompt's. Nil when
	/// either timestamp is unreadable — the capsule renders without it.
	private func noticeDuration(_ entry: TranscriptEntry) -> TimeInterval? {
		guard let end = SQLiteDate.parse(entry.ts),
			let head = transcript.entries.last(where: { $0.rowid < entry.rowid && $0.role == .user }),
			let start = SQLiteDate.parse(head.ts)
		else { return nil }
		let elapsed = end.timeIntervalSince(start)
		return elapsed >= 1 ? elapsed : nil
	}
}

// MARK: - Rows

/// Conductor's turn-error capsule ("INTERRUPTED BY USER"): bordered, mono,
/// uppercase, with the turn's elapsed time in small type underneath.
struct ErrorNotice: View {
	let entry: TranscriptEntry
	let duration: TimeInterval?

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text(entry.text.uppercased())
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.overlay(
					RoundedRectangle(cornerRadius: 10)
						.stroke(.tertiary, lineWidth: 1)
				)
			if let duration {
				Text(Duration.seconds(duration).formatted(.units(width: .narrow, maximumUnitCount: 2)))
					.font(.caption2.monospacedDigit())
					.foregroundStyle(.tertiary)
					.padding(.leading, 2)
			}
		}
		.padding(.vertical, 2)
	}
}

struct UserBubble: View {
	let entry: TranscriptEntry
	let sessionID: String

	var body: some View {
		VStack(alignment: .trailing, spacing: 3) {
			VStack(alignment: .leading, spacing: 8) {
				MarkdownText(entry.text)
				if let attachments = entry.attachments, !attachments.isEmpty {
					// The Mac's attachment chips: image ones open the file itself
					// through the relay's transcript-gated endpoint.
					HStack(spacing: 6) {
						ForEach(attachments) { attachment in
							if isImagePath(attachment.path) {
								ImageChipView(sessionID: sessionID, path: attachment.path, name: attachment.name)
							} else {
								HStack(spacing: 5) {
									Image(systemName: "doc")
										.font(.caption2)
										.foregroundStyle(.secondary)
									Text(attachment.name)
										.font(.caption.monospaced())
										.lineLimit(1)
								}
								.padding(.horizontal, 8)
								.padding(.vertical, 3)
								.background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
							}
						}
					}
				}
			}
				.padding(.horizontal, 14)
				.padding(.vertical, 9)
				.background(Color.accentSoft, in: UnevenRoundedRectangle(
					topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18))
			HStack(spacing: 5) {
				if entry.queued {
					Text("QUEUED")
						.font(.caption2.weight(.bold))
						.foregroundStyle(.tertiary)
				}
				if let date = SQLiteDate.parse(entry.ts) {
					Text(date, format: timeFormat(date))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .trailing)
		.padding(.leading, 40)
		.opacity(entry.queued ? 0.6 : 1)
	}

	private func timeFormat(_ date: Date) -> Date.FormatStyle {
		Calendar.current.isDateInToday(date)
			? .dateTime.hour().minute()
			: .dateTime.month(.abbreviated).day().hour().minute()
	}
}

struct AssistantProse: View {
	let text: String

	var body: some View {
		MarkdownText(text)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.trailing, 24)
	}
}

/// True for the image extensions the relay's file endpoint will serve.
func isImagePath(_ path: String) -> Bool {
	["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased())
}

func fileBasename(_ path: String) -> String {
	(path as NSString).lastPathComponent
}

struct StepRow: View {
	let entry: TranscriptEntry
	let sessionID: String
	@State private var expanded = false

	/// A file-editing step — its row carries the +N −M chip and expands to the hunk.
	private var isEdit: Bool { entry.adds != nil || entry.dels != nil }
	private var imagePath: String? {
		guard let detail = entry.detail, isImagePath(detail) else { return nil }
		return detail
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Button {
				withAnimation(.spring(duration: 0.25)) { expanded.toggle() }
			} label: {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Image(systemName: entry.role == .thinking ? "brain" : toolSymbol(entry.tool))
						.font(.caption)
						.foregroundStyle(entry.isError ? Color.diffDelete : .secondary)
					Text(label)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					if let imagePath {
						ImageChipView(sessionID: sessionID, path: imagePath, name: fileBasename(imagePath))
					} else if isEdit, let detail = entry.detail {
						Text(fileBasename(detail))
							.font(.caption.monospaced())
							.foregroundStyle(.tertiary)
							.lineLimit(1)
						if let adds = entry.adds, adds > 0 {
							Text("+\(adds)").font(.caption.monospacedDigit()).foregroundStyle(Color.diffAdd)
						}
						if let dels = entry.dels, dels > 0 {
							Text("−\(dels)").font(.caption.monospacedDigit()).foregroundStyle(Color.diffDelete)
						}
					} else if let detail = entry.detail {
						Text(detail)
							.font(.caption.monospaced())
							.foregroundStyle(.tertiary)
							.lineLimit(1)
					}
				}
			}
			.buttonStyle(.plain)
			if expanded {
				expandedBody
			}
		}
	}

	/// "Read image" for an image step (the chip carries the name), else the tool text.
	private var label: String {
		if entry.role == .thinking { return "Thinking" }
		if imagePath != nil && entry.text == entry.tool { return "\(entry.text) image" }
		return entry.text
	}

	@ViewBuilder private var expandedBody: some View {
		if entry.role == .thinking {
			Text(entry.text)
				.font(.footnote.italic())
				.foregroundStyle(.secondary)
				.padding(.leading, 10)
				.overlay(alignment: .leading) {
					Rectangle().fill(Color.surfaceRaised).frame(width: 2)
				}
		} else if entry.isError {
			Text(entry.text)
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
				.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.diffDelete.opacity(0.5)))
		} else if let hunk = entry.hunk {
			HunkView(hunk: hunk)
		} else if let detail = entry.detail {
			Text(detail)
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
				.padding(.leading, 18)
				.textSelection(.enabled)
		}
	}
}

/// The Mac's mini diff: mono lines coloured by their `-`/`+`/context prefix.
struct HunkView: View {
	let hunk: String

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			VStack(alignment: .leading, spacing: 1) {
				ForEach(Array(hunk.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) {
					_, line in
					Text(line.isEmpty ? " " : String(line))
						.font(.caption.monospaced())
						.foregroundStyle(lineColor(line))
				}
			}
			.padding(8)
		}
		.background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.surfaceRaised))
	}

	private func lineColor(_ line: Substring) -> Color {
		if line.hasPrefix("+") { return Color.diffAdd }
		if line.hasPrefix("-") { return Color.diffDelete }
		return Color(.tertiaryLabel)
	}
}

/// The end-of-turn receipt (the Mac's "6m, 59s · file +N −M" row).
struct TurnSummaryRow: View {
	let summary: TurnSummary

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 6) {
				if let seconds = summary.seconds {
					Text(Duration.seconds(seconds).formatted(.units(width: .narrow, maximumUnitCount: 2)))
						.font(.caption2.monospacedDigit())
						.foregroundStyle(.tertiary)
				}
				ForEach(summary.files) { file in
					HStack(spacing: 5) {
						Text(file.name)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.lineLimit(1)
						if file.adds > 0 {
							Text("+\(file.adds)").font(.caption2.monospacedDigit()).foregroundStyle(Color.diffAdd)
						}
						if file.dels > 0 {
							Text("−\(file.dels)").font(.caption2.monospacedDigit()).foregroundStyle(Color.diffDelete)
						}
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(Color.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
				}
			}
		}
		.padding(.vertical, 1)
	}
}

/// A chip naming a transcript-referenced image; tapping loads it through the
/// relay's transcript-gated file endpoint and shows it full screen.
struct ImageChipView: View {
	let sessionID: String
	let path: String
	let name: String
	@Environment(AppModel.self) private var model
	@State private var image: UIImage?
	@State private var showing = false
	@State private var loading = false
	@State private var failed = false

	var body: some View {
		Button {
			Task { await open() }
		} label: {
			HStack(spacing: 5) {
				if loading {
					ProgressView().controlSize(.mini)
				} else {
					Image(systemName: failed ? "exclamationmark.triangle" : "photo")
						.font(.caption2)
						.foregroundStyle(failed ? Color.diffDelete : Color.diffAdd)
				}
				Text(name)
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
		}
		.buttonStyle(.plain)
		.sheet(isPresented: $showing) {
			if let image {
				ZStack {
					Color.black.ignoresSafeArea()
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
				}
				.presentationDragIndicator(.visible)
			}
		}
	}

	private func open() async {
		if image == nil {
			loading = true
			defer { loading = false }
			guard let data = try? await model.client.fileData(sessionID: sessionID, path: path),
				let loaded = UIImage(data: data)
			else {
				failed = true
				return
			}
			image = loaded
		}
		showing = true
	}
}

func toolSymbol(_ tool: String?) -> String {
	switch tool {
	case "Bash": "terminal"
	case "Read": "doc.text"
	case "Edit", "Write": "pencil"
	case "Grep", "Glob": "magnifyingglass"
	case "WebFetch", "WebSearch": "globe"
	case "Agent", "Task": "person.2"
	default: "chevron.right.circle"
	}
}

/// A sub-agent's run, nested under its Task like the Mac app: bot header with
/// the task description and live step count; open, the sub-agent's prompt then
/// its own steps.
struct AgentGroupView: View {
	let run: AgentRun
	let sessionID: String
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.spring(duration: 0.25)) { expanded.toggle() }
			} label: {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Image(systemName: "person.2")
						.font(.caption)
						.foregroundStyle(.secondary)
					Text("Agent")
						.font(.footnote.weight(.medium))
						.foregroundStyle(.secondary)
					Text(run.task.text)
						.font(.footnote)
						.foregroundStyle(.primary.opacity(0.8))
						.lineLimit(1)
					Text("\(run.children.count) steps")
						.font(.caption)
						.foregroundStyle(.tertiary)
					if run.failedCount > 0 {
						Text("\(run.failedCount) failed")
							.font(.caption.weight(.medium))
							.foregroundStyle(Color.diffDelete)
					}
					Image(systemName: "chevron.right")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.tertiary)
						.rotationEffect(.degrees(expanded ? 90 : 0))
				}
			}
			.buttonStyle(.plain)
			.animation(.default, value: run.children.count)

			if expanded {
				VStack(alignment: .leading, spacing: 5) {
					if let prompt = run.task.detail {
						Text(prompt)
							.font(.caption.monospaced())
							.foregroundStyle(.tertiary)
							.padding(.bottom, 2)
					}
					ForEach(run.children) { entry in
						StepRow(entry: entry, sessionID: sessionID)
					}
				}
				.padding(.leading, 14)
			}
		}
		.padding(.vertical, 2)
	}
}

/// The fold: a run of agent activity behind one disclosure whose header keeps
/// updating while the agent works — a closed group still reads as live.
struct StepGroupView: View {
	let group: StepGroup
	let sessionID: String
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "chevron.right")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.tertiary)
						.rotationEffect(.degrees(expanded ? 90 : 0))
					Text(group.lastLabel)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.contentTransition(.opacity)
					Text("\(group.count) steps")
						.font(.caption.monospacedDigit())
						.foregroundStyle(.tertiary)
						.contentTransition(.numericText())
					if group.failedCount > 0 {
						Text("\(group.failedCount) failed")
							.font(.caption.weight(.medium))
							.foregroundStyle(Color.diffDelete)
					}
				}
			}
			.buttonStyle(.plain)
			.animation(.default, value: group.count)

			if expanded {
				VStack(alignment: .leading, spacing: 5) {
					ForEach(group.entries) { entry in
						StepRow(entry: entry, sessionID: sessionID)
					}
				}
				.padding(.leading, 14)
			}
		}
		.padding(.vertical, 2)
	}
}

/// Three-dot bounce + elapsed timer. `Text(timerInterval:)` renders the
/// count-up with zero timers of our own; a nil start (pre-May-2026 sessions
/// have no turn_started_at) shows dots alone.
struct WorkingRow: View {
	let since: Date?

	var body: some View {
		HStack(spacing: 10) {
			TypingDots()
			if let since {
				Text(timerInterval: since...Date.distantFuture, countsDown: false)
					.font(.caption.monospacedDigit())
					.foregroundStyle(Color.working)
			}
		}
		.padding(.vertical, 4)
	}
}

struct TypingDots: View {
	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
			let t = context.date.timeIntervalSinceReferenceDate
			HStack(spacing: 4) {
				ForEach(0..<3, id: \.self) { i in
					let phase = sin((t * 2 - Double(i) * 0.35) * .pi)
					Circle()
						.fill(Color.working)
						.frame(width: 7, height: 7)
						.offset(y: CGFloat(-max(0, phase)) * 3)
						.opacity(0.5 + 0.5 * max(0, phase))
				}
			}
		}
	}
}

// MARK: - Overlay bubbles

/// Optimistic send: 85 % opacity while sending; failure keeps the text with
/// inline Retry/Dismiss. No success state — the real row is the receipt.
struct PendingBubble: View {
	let pending: SendPipeline.Pending
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(alignment: .trailing, spacing: 4) {
			MarkdownText(pending.text)
				.padding(.horizontal, 14)
				.padding(.vertical, 9)
				.background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 18))
				.overlay {
					if case .failed = pending.status {
						RoundedRectangle(cornerRadius: 18).strokeBorder(Color.diffDelete, lineWidth: 1.5)
					}
				}
			statusLine
		}
		.frame(maxWidth: .infinity, alignment: .trailing)
		.padding(.leading, 40)
		.opacity(opacity)
		.sensoryFeedback(.warning, trigger: isFailed)
	}

	private var isFailed: Bool {
		if case .failed = pending.status { return true }
		return false
	}

	private var opacity: Double {
		switch pending.status {
		case .sending, .unconfirmed: 0.85
		case .failed: 1
		}
	}

	@ViewBuilder private var statusLine: some View {
		switch pending.status {
		case .sending:
			HStack(spacing: 5) {
				ProgressView().controlSize(.mini)
				Text("Sending…").font(.caption2).foregroundStyle(.tertiary)
			}
		case .unconfirmed:
			Text("Sending — will confirm when reopened")
				.font(.caption2)
				.foregroundStyle(.tertiary)
		case .failed(let message):
			HStack(spacing: 10) {
				Label(message, systemImage: "exclamationmark.triangle.fill")
					.font(.caption2)
					.foregroundStyle(Color.diffDelete)
					.lineLimit(2)
				Button("Retry") {
					Task {
						await model.sends.send(
							sessionID: pending.sessionID, workspaceID: pending.workspaceID,
							text: pending.text, retrying: pending.id)
					}
				}
				.font(.caption.weight(.semibold))
				Button("Dismiss") {
					model.sends.dismiss(pending.id)
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
	}
}

/// A relay-owned prompt (first prompt waiting on setup, or parked behind the
/// lock screen): displayed, never re-sent by us — Retry is an ordinary send
/// whose success makes the relay drop its copy.
struct QueuedPromptBubble: View {
	let prompt: PendingPrompt
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(alignment: .trailing, spacing: 4) {
			MarkdownText(prompt.text)
				.padding(.horizontal, 14)
				.padding(.vertical, 9)
				.background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 18))
				.overlay {
					if prompt.failed {
						RoundedRectangle(cornerRadius: 18).strokeBorder(Color.diffDelete, lineWidth: 1.5)
					}
				}
			if prompt.failed {
				HStack(spacing: 10) {
					Label(prompt.error ?? "Couldn't send", systemImage: "exclamationmark.triangle.fill")
						.font(.caption2)
						.foregroundStyle(Color.diffDelete)
						.lineLimit(2)
					if let sessionID = prompt.sessionId {
						Button("Retry") {
							Task {
								await model.sends.send(
									sessionID: sessionID, workspaceID: prompt.workspaceId, text: prompt.text)
								try? await model.dismissParkedPrompts(sessionID: sessionID)
							}
						}
						.font(.caption.weight(.semibold))
					}
					Button("Dismiss") {
						Task {
							if let sessionID = prompt.sessionId {
								try? await model.dismissParkedPrompts(sessionID: sessionID)
							} else {
								try? await model.dismissFirstPrompt(workspaceID: prompt.workspaceId)
							}
						}
					}
					.font(.caption)
					.foregroundStyle(.secondary)
				}
			} else {
				HStack(spacing: 5) {
					Image(systemName: prompt.sessionId == nil ? "hourglass" : "moon.zzz.fill")
						.font(.caption2)
					Text(prompt.reason ?? "Sends when the workspace is ready")
						.font(.caption2)
				}
				.foregroundStyle(.tertiary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .trailing)
		.padding(.leading, 40)
		.opacity(prompt.failed ? 1 : 0.6)
	}
}

/// The first-prompt card shown while a workspace is still setting up.
struct PendingPromptCard: View {
	let prompt: PendingPrompt
	let workspaceID: String

	var body: some View {
		VStack(spacing: 6) {
			Text(prompt.text)
				.font(.subheadline)
				.lineLimit(4)
				.padding(12)
				.background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
			Text(prompt.failed ? (prompt.error ?? "Couldn't send") : "Sends when the workspace is ready")
				.font(.caption)
				.foregroundStyle(prompt.failed ? Color.diffDelete : Color(.tertiaryLabel))
		}
		.padding(.horizontal, 32)
	}
}
