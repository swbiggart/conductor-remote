// Full-GFM transcript markdown, split into responsibilities: swift-markdown
// parses (cmark-correct — nested lists, lazy continuations, tables, task
// lists), this file maps the tree to a pure value model, and the app renders
// each block with its own SwiftUI views. Inline styling is carried as
// AttributedString inlinePresentationIntent runs, which SwiftUI Text renders
// natively — no HTML, no webviews.
//
// Two deliberate rules ported from the PWA:
// - Raw HTML is never rendered (HTMLBlock/InlineHTML are dropped).
// - A single newline is a line break (remark-breaks parity): agents write
//   hard-wrapped prose and cmark's soft-break-as-space reads as run-on text.

import Foundation
import Markdown

public indirect enum MarkdownBlock: Sendable, Equatable {
	case paragraph(AttributedString)
	case heading(level: Int, text: AttributedString)
	case code(String, language: String?)
	case list(ordered: Bool, start: Int, items: [MarkdownListItem])
	case quote([MarkdownBlock])
	case table(header: [AttributedString], rows: [[AttributedString]])
	case divider
}

public struct MarkdownListItem: Sendable, Equatable {
	/// Task-list state: nil = plain item, else checked/unchecked.
	public let checkbox: Bool?
	public let blocks: [MarkdownBlock]

	public init(checkbox: Bool?, blocks: [MarkdownBlock]) {
		self.checkbox = checkbox
		self.blocks = blocks
	}
}

public enum MarkdownBlocks {
	public static func parse(_ text: String) -> [MarkdownBlock] {
		blocks(of: Document(parsing: text))
	}

	private static func blocks(of markup: Markup) -> [MarkdownBlock] {
		markup.children.compactMap(block(from:))
	}

	private static func block(from markup: Markup) -> MarkdownBlock? {
		switch markup {
		case let paragraph as Paragraph:
			return .paragraph(inline(paragraph))
		case let heading as Heading:
			return .heading(level: heading.level, text: inline(heading))
		case let code as CodeBlock:
			let trimmed = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
			let language = code.language?.isEmpty == false ? code.language : nil
			return .code(trimmed, language: language)
		case let list as UnorderedList:
			return .list(ordered: false, start: 1, items: items(of: list))
		case let list as OrderedList:
			return .list(ordered: true, start: Int(list.startIndex), items: items(of: list))
		case let quote as BlockQuote:
			return .quote(blocks(of: quote))
		case let table as Markdown.Table:
			return tableBlock(table)
		case is ThematicBreak:
			return .divider
		default:
			// HTMLBlock (never rendered — PWA rule), directives, anything new.
			return nil
		}
	}

	private static func items(of list: Markup) -> [MarkdownListItem] {
		list.children.compactMap { child in
			guard let item = child as? ListItem else { return nil }
			let checkbox: Bool? =
				switch item.checkbox {
				case .checked: true
				case .unchecked: false
				case nil: nil
				}
			return MarkdownListItem(checkbox: checkbox, blocks: blocks(of: item))
		}
	}

	private static func tableBlock(_ table: Markdown.Table) -> MarkdownBlock {
		let header = Array(table.head.cells.map { inline($0) })
		let rows = Array(table.body.rows.map { row in Array(row.cells.map { inline($0) }) })
		return .table(header: header, rows: rows)
	}

	// MARK: Inlines → AttributedString

	static func inline(_ container: Markup) -> AttributedString {
		var result = AttributedString()
		for child in container.children {
			result += fragment(child)
		}
		return result
	}

	private static func fragment(_ markup: Markup) -> AttributedString {
		switch markup {
		case let text as Markdown.Text:
			return AttributedString(text.string)
		case is SoftBreak, is LineBreak:
			// remark-breaks parity: a single newline is a real line break.
			return AttributedString("\n")
		case let code as InlineCode:
			var s = AttributedString(code.code)
			s.inlinePresentationIntent = .code
			return s
		case let emphasis as Emphasis:
			return adding(.emphasized, to: inline(emphasis))
		case let strong as Strong:
			return adding(.stronglyEmphasized, to: inline(strong))
		case let strike as Strikethrough:
			return adding(.strikethrough, to: inline(strike))
		case let link as Markdown.Link:
			var s = inline(link)
			if let destination = link.destination, let url = URL(string: destination) {
				s.link = url
			}
			return s
		case let image as Markdown.Image:
			// Alt text only — the transcript never loads remote images.
			return AttributedString(image.plainText)
		case is InlineHTML:
			return AttributedString()
		default:
			return AttributedString((markup as? InlineMarkup)?.plainText ?? "")
		}
	}

	/// Merge an intent into every run (nested styles OR together, so bold
	/// inside italic keeps both).
	private static func adding(_ intent: InlinePresentationIntent, to source: AttributedString) -> AttributedString {
		var s = source
		for run in s.runs {
			var merged = run.inlinePresentationIntent ?? []
			merged.insert(intent)
			s[run.range].inlinePresentationIntent = merged
		}
		return s
	}
}
