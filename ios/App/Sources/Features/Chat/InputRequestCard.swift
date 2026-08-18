// The "waiting on you" card — the agent is stopped on a plan approval or an
// AskUserQuestion, and this card is the phone's respond surface (parity with
// web/src/components/InputRequest.tsx). Ground rules inherited from the relay:
// only single-choice questions are answerable from the phone (multiSelect
// renders read-only with a "answer on the Mac" hint), a plan supports Approve
// only (to keep planning, reply from the composer), one label per question in
// order, and a locked Mac is a refusal — never a parked button-press. The
// relay validates against its live pending read before pressing and confirms
// against the transcript receipt, so a retry after a lost response is safe.

import ConductorKit
import SwiftUI

struct InputRequestCard: View {
	let workspace: Workspace
	let session: Session
	let pending: PendingInput
	@Environment(AppModel.self) private var model
	@State private var picked: [Int: String] = [:]
	@State private var sending = false
	@State private var error: String?
	@State private var answered = false

	private var questions: [PendingQuestion] { pending.questions ?? [] }
	private var allPicked: Bool {
		questions.indices.allSatisfy { picked[$0] != nil }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(
				pending.isPlan ? "Plan ready for review" : "The agent has a question",
				systemImage: pending.isPlan ? "list.bullet.clipboard" : "questionmark.bubble")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Color.accent)

			if pending.isPlan {
				if let plan = pending.plan, !plan.isEmpty {
					DisclosureGroup("Show plan") {
						MarkdownText(plan)
							.padding(.top, 6)
					}
					.font(.footnote)
					.tint(.secondary)
				}
				HStack(spacing: 12) {
					Button {
						submit(kind: "plan", options: nil, approve: true)
					} label: {
						Label("Approve", systemImage: "checkmark")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.disabled(sending)
					Text("To keep planning, reply below.")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			} else {
				ForEach(questions.indices, id: \.self) { index in
					questionView(index: index, question: questions[index])
				}
				if pending.answerable {
					Button {
						submit(kind: "question", options: questions.indices.map { picked[$0] ?? "" }, approve: nil)
					} label: {
						Group {
							if sending {
								ProgressView().controlSize(.small)
							} else {
								Text(questions.count > 1 ? "Send answers" : "Send answer")
							}
						}
						.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.disabled(!allPicked || sending)
				} else {
					Label("This one needs multi-select — answer it in Conductor on the Mac.",
						systemImage: "cursorarrow.click.badge.clock")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			if let error {
				Text(error)
					.font(.caption)
					.foregroundStyle(Color.diffDelete)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
		.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentSoft, lineWidth: 1.5))
		.sensoryFeedback(.success, trigger: answered)
		.opacity(sending ? 0.8 : 1)
	}

	@ViewBuilder private func questionView(index: Int, question: PendingQuestion) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			if let header = question.header, !header.isEmpty {
				Text(header.uppercased())
					.font(.caption2.weight(.bold))
					.foregroundStyle(.tertiary)
			}
			Text(question.question)
				.font(.subheadline)
			ForEach(question.options, id: \.label) { option in
				let selected = picked[index] == option.label
				Button {
					picked[index] = selected ? nil : option.label
				} label: {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Image(systemName: selected ? "largecircle.fill.circle" : "circle")
							.font(.footnote)
							.foregroundStyle(selected ? Color.accent : Color(.tertiaryLabel))
						VStack(alignment: .leading, spacing: 2) {
							Text(option.label)
								.font(.subheadline.weight(selected ? .semibold : .regular))
							if let description = option.description, !description.isEmpty {
								Text(description)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						Spacer(minLength: 0)
					}
					.padding(.vertical, 6)
					.padding(.horizontal, 8)
					.background(selected ? Color.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
				}
				.buttonStyle(.plain)
				.disabled(sending || question.isMultiSelect)
			}
		}
	}

	private func submit(kind: String, options: [String]?, approve: Bool?) {
		sending = true
		error = nil
		Task {
			do {
				let result = try await model.client.answer(
					sessionID: session.id, workspaceID: workspace.id, toolUseId: pending.toolUseId,
					kind: kind, options: options, approve: approve)
				if result.ok {
					// The card clears when the next poll sees pending == nil;
					// kick it so that's now. `already` is success too.
					answered = true
					model.engine.kick(.messages(sessionID: session.id))
				} else {
					error = result.error ?? "Couldn't answer — try again."
					model.engine.kick(.messages(sessionID: session.id))
				}
			} catch let apiError as APIError {
				error = apiError.message
			} catch {
				self.error = String(describing: error)
			}
			sending = false
		}
	}
}

/// The codex-session card: Conductor says the chat is waiting, but the card
/// has no DB row (verified live — codex cards exist only in Conductor's
/// webview), so it's *scraped* off the pane via AX, on demand. The silent
/// fetch never touches the Mac's focus; when the chat isn't the pane on
/// screen, answering is offered as an explicit "bring Conductor forward"
/// choice instead of a surprise focus steal. Multi-question cards answer one
/// question per press — each submit advances the card and the re-scrape shows
/// the next question.
struct ScrapedInputCard: View {
	let workspace: Workspace
	let session: Session
	@Environment(AppModel.self) private var model
	@State private var card: ScrapedCard?
	@State private var loading = false
	@State private var notVisible = false
	@State private var picked: [Int: String] = [:]
	@State private var sending = false
	@State private var error: String?

	private var questions: [[String]] { card?.questions ?? [] }
	private var allPicked: Bool { questions.indices.allSatisfy { picked[$0] != nil } }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(
				session.awaitingPlan || card?.kind == "plan" ? "Plan ready for review" : "The agent has a question",
				systemImage: session.awaitingPlan || card?.kind == "plan"
					? "list.bullet.clipboard" : "questionmark.bubble")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Color.accent)

			content

			if let error {
				Text(error)
					.font(.caption)
					.foregroundStyle(Color.diffDelete)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
		.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentSoft, lineWidth: 1.5))
		.task(id: session.id) {
			await fetch(silent: true)
		}
	}

	@ViewBuilder private var content: some View {
		if loading && card == nil {
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text("Reading the card from Conductor…")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		} else if notVisible {
			Text("This chat isn't on screen on the Mac, so the card can't be read silently.")
				.font(.footnote)
				.foregroundStyle(.secondary)
			Button {
				Task { await fetch(silent: false) }
			} label: {
				Label("Show the card (brings Conductor forward)", systemImage: "macwindow.and.cursorarrow")
					.font(.footnote.weight(.medium))
			}
			.buttonStyle(.bordered)
			.disabled(loading)
		} else if card?.kind == "question", !questions.isEmpty {
			ForEach(questions.indices, id: \.self) { index in
				if questions.count > 1 {
					Text("QUESTION \(index + 1)")
						.font(.caption2.weight(.bold))
						.foregroundStyle(.tertiary)
				}
				ForEach(questions[index], id: \.self) { option in
					optionRow(question: index, option: option)
				}
			}
			if questions.count > 1 {
				Text("One submit answers the whole card — pick every question first.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
			Button {
				submit()
			} label: {
				Group {
					if sending {
						ProgressView().controlSize(.small)
					} else {
						Text(questions.count > 1 ? "Send all answers" : "Send answer")
					}
				}
				.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.disabled(!allPicked || sending)
		} else if card?.kind == "plan" {
			Button {
				submit()
			} label: {
				Label("Approve", systemImage: "checkmark")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.disabled(sending)
		} else if card?.kind == "none" {
			Text("The card cleared — it may have been answered on the Mac.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		} else {
			Text("The agent is waiting on input this app can't display — answer it in Conductor on the Mac.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private func optionRow(question: Int, option: String) -> some View {
		let selected = picked[question] == option
		return Button {
			picked[question] = selected ? nil : option
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: selected ? "largecircle.fill.circle" : "circle")
					.font(.footnote)
					.foregroundStyle(selected ? Color.accent : Color(.tertiaryLabel))
				// Display without the AX name's leading option number; the
				// *answer* sends the full string verbatim — that's what the
				// relay matches against the card.
				Text(option.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces))
					.font(.subheadline.weight(selected ? .semibold : .regular))
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.padding(.vertical, 6)
			.padding(.horizontal, 8)
			.background(selected ? Color.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
		}
		.buttonStyle(.plain)
		.disabled(sending)
	}

	private func fetch(silent: Bool) async {
		loading = true
		error = nil
		do {
			let result = try await model.client.card(sessionID: session.id, workspaceID: workspace.id, silentOnly: silent)
			notVisible = result.notVisible == true
			if result.ok { card = result } else if !notVisible { error = result.error }
		} catch let apiError as APIError {
			error = apiError.message
		} catch {
			self.error = String(describing: error)
		}
		loading = false
	}

	private func submit() {
		let isPlan = card?.kind == "plan"
		guard isPlan || allPicked else { return }
		sending = true
		error = nil
		Task {
			do {
				// One option per question, in order — the relay refuses partial
				// answers because a codex submit finalizes the whole card.
				let answers = questions.indices.compactMap { picked[$0] }
				let result = try await model.client.answer(
					sessionID: session.id, workspaceID: workspace.id, toolUseId: nil,
					kind: isPlan ? "plan" : "question", options: isPlan ? nil : answers,
					approve: isPlan ? true : nil, scraped: true)
				if result.ok {
					picked = [:]
					// Card resolved — re-scrape confirms it's gone and the
					// polls pick up the status flip.
					await fetch(silent: true)
					model.engine.kick(.state)
				} else {
					error = result.error ?? "Couldn't answer — try again."
				}
			} catch let apiError as APIError {
				error = apiError.message
			} catch {
				self.error = String(describing: error)
			}
			sending = false
		}
	}
}
