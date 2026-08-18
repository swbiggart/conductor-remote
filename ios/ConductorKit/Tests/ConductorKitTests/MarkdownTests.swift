import Foundation
import Testing

@testable import ConductorKit

@Suite struct MarkdownBlocksTests {
	@Test func headingsListsAndCode() {
		let blocks = MarkdownBlocks.parse(
			"""
			## Plan
			1. First step
			2. Second with `code`
			```swift
			let x = 1
			```
			"""
		)
		guard case .heading(let level, let title) = blocks[0],
			case .list(let ordered, let start, let items) = blocks[1],
			case .code(let code, let language) = blocks[2]
		else {
			Issue.record("unexpected shapes: \(blocks)")
			return
		}
		#expect(level == 2 && String(title.characters) == "Plan")
		#expect(ordered && start == 1 && items.count == 2)
		#expect(code == "let x = 1" && language == "swift")
	}

	@Test func orderedListKeepsStartNumber() {
		let blocks = MarkdownBlocks.parse("4. fourth\n5. fifth")
		guard case .list(true, let start, let items) = blocks.first else {
			Issue.record("expected an ordered list")
			return
		}
		#expect(start == 4 && items.count == 2)
	}

	@Test func nestedListSurvives() {
		let blocks = MarkdownBlocks.parse("- outer\n  - inner one\n  - inner two")
		guard case .list(false, _, let items) = blocks.first,
			case .list(false, _, let inner) = items[0].blocks.last
		else {
			Issue.record("expected nested list, got \(blocks)")
			return
		}
		#expect(inner.count == 2)
	}

	@Test func taskListCheckboxes() {
		let blocks = MarkdownBlocks.parse("- [x] done thing\n- [ ] todo thing")
		guard case .list(_, _, let items) = blocks.first else {
			Issue.record("expected a list")
			return
		}
		#expect(items.map(\.checkbox) == [true, false])
	}

	@Test func tableParses() {
		let blocks = MarkdownBlocks.parse("| a | b |\n|---|---|\n| 1 | 2 |")
		guard case .table(let header, let rows) = blocks.first else {
			Issue.record("expected a table, got \(blocks)")
			return
		}
		#expect(header.map { String($0.characters) } == ["a", "b"])
		#expect(rows.first?.map { String($0.characters) } == ["1", "2"])
	}

	@Test func singleNewlineIsALineBreak() {
		// remark-breaks parity: agents hard-wrap prose.
		let blocks = MarkdownBlocks.parse("line one\nline two")
		guard case .paragraph(let text) = blocks.first else {
			Issue.record("expected a paragraph")
			return
		}
		#expect(String(text.characters) == "line one\nline two")
	}

	@Test func rawHTMLIsDropped() {
		let blocks = MarkdownBlocks.parse("<div>never</div>\n\nreal *prose* here")
		#expect(blocks.count == 1)
		guard case .paragraph(let text) = blocks.first else {
			Issue.record("expected only the paragraph")
			return
		}
		#expect(String(text.characters).contains("prose"))
		// And the emphasis carried through as an intent run.
		#expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
	}

	@Test func quoteAndDivider() {
		let blocks = MarkdownBlocks.parse("> quoted words\n\n---")
		guard case .quote(let inner) = blocks.first, case .divider = blocks.last else {
			Issue.record("expected quote + divider, got \(blocks)")
			return
		}
		#expect(inner.count == 1)
	}

	@Test func nestedBoldInItalicKeepsBoth() {
		let blocks = MarkdownBlocks.parse("*outer **both** outer*")
		guard case .paragraph(let text) = blocks.first else {
			Issue.record("expected paragraph")
			return
		}
		let both = text.runs.first {
			$0.inlinePresentationIntent?.isSuperset(of: [.emphasized, .stronglyEmphasized]) == true
		}
		#expect(both != nil)
	}
}
