// Transcript markdown, rendered from ConductorKit's parsed block tree
// (swift-markdown underneath — full GFM). Every block type keeps the app's
// own design language: code cards on surfaceRaised, muted list gutters with
// hanging indents, left-ruled quotes, horizontally scrollable tables. Inline
// styling arrives as AttributedString intent runs, which Text renders natively.

import ConductorKit
import SwiftUI

struct MarkdownText: View {
	let blocks: [MarkdownBlock]

	init(_ text: String) {
		self.blocks = MarkdownBlocks.parse(text)
	}

	var body: some View {
		MarkdownBlocksView(blocks: blocks)
	}
}

struct MarkdownBlocksView: View {
	let blocks: [MarkdownBlock]

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
				blockView(block)
			}
		}
	}

	@ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
		switch block {
		case .paragraph(let text):
			Text(text)
				.font(.body)
				.textSelection(.enabled)
		case .heading(let level, let text):
			Text(text)
				.font(headingFont(level))
				.padding(.top, level <= 2 ? 4 : 2)
		case .code(let code, _):
			ScrollView(.horizontal, showsIndicators: false) {
				Text(code)
					.font(.callout.monospaced())
					.textSelection(.enabled)
					.padding(10)
			}
			.background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
		case .list(let ordered, let start, let items):
			listView(ordered: ordered, start: start, items: items)
		case .quote(let inner):
			MarkdownBlocksView(blocks: inner)
				.foregroundStyle(.secondary)
				.padding(.leading, 10)
				.overlay(alignment: .leading) {
					RoundedRectangle(cornerRadius: 1)
						.fill(Color.surfaceRaised)
						.frame(width: 3)
				}
		case .table(let header, let rows):
			tableView(header: header, rows: rows)
		case .divider:
			Divider().overlay(Color.surfaceRaised)
		}
	}

	private func headingFont(_ level: Int) -> Font {
		switch level {
		case 1: .title3.weight(.bold)
		case 2: .headline
		default: .subheadline.weight(.semibold)
		}
	}

	private func listView(ordered: Bool, start: Int, items: [MarkdownListItem]) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			ForEach(Array(items.enumerated()), id: \.offset) { index, item in
				HStack(alignment: .firstTextBaseline, spacing: 7) {
					// Muted marker in a trailing-aligned gutter ("9." and
					// "10." line up); wraps keep the hanging indent because
					// the content is its own column.
					marker(ordered: ordered, number: start + index, checkbox: item.checkbox)
					MarkdownBlocksView(blocks: item.blocks)
				}
			}
		}
	}

	@ViewBuilder private func marker(ordered: Bool, number: Int, checkbox: Bool?) -> some View {
		if let checkbox {
			Image(systemName: checkbox ? "checkmark.square.fill" : "square")
				.font(.subheadline)
				.foregroundStyle(checkbox ? Color.accent : Color(.tertiaryLabel))
				.frame(minWidth: 22, alignment: .trailing)
		} else {
			Text(ordered ? "\(number)." : "•")
				.font(.body.monospacedDigit())
				.foregroundStyle(.secondary)
				.frame(minWidth: 22, alignment: .trailing)
		}
	}

	private func tableView(header: [AttributedString], rows: [[AttributedString]]) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
				GridRow {
					ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
						Text(cell).font(.footnote.weight(.semibold))
					}
				}
				Divider().overlay(Color.surfaceRaised)
				ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
					GridRow {
						ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
							Text(cell)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				}
			}
			.padding(10)
		}
		.background(Color.surface, in: RoundedRectangle(cornerRadius: 10))
	}
}
