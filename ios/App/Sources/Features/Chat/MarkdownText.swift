// Markdown for transcript prose. AttributedString's markdown parser handles
// inline styling well but flattens block structure, so fenced code blocks are
// split out first and rendered as mono cards — the two things agent output
// actually uses (prose + code) both come out right.

import SwiftUI

struct MarkdownText: View {
	let text: String

	init(_ text: String) {
		self.text = text
	}

	var body: some View {
		let segments = Self.split(text)
		VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
				switch segment {
				case .prose(let prose):
					Text(Self.inline(prose))
						.font(.body)
						.textSelection(.enabled)
				case .code(let code, _):
					ScrollView(.horizontal, showsIndicators: false) {
						Text(code)
							.font(.callout.monospaced())
							.textSelection(.enabled)
							.padding(10)
					}
					.background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
				}
			}
		}
	}

	enum Segment {
		case prose(String)
		case code(String, language: String?)
	}

	static func split(_ text: String) -> [Segment] {
		var segments: [Segment] = []
		var prose: [String] = []
		var code: [String] = []
		var language: String?
		var inFence = false

		for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") {
				if inFence {
					segments.append(.code(code.joined(separator: "\n"), language: language))
					code = []
					inFence = false
				} else {
					let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
					if !joined.isEmpty { segments.append(.prose(joined)) }
					prose = []
					language = trimmed.count > 3 ? String(trimmed.dropFirst(3)) : nil
					inFence = true
				}
			} else if inFence {
				code.append(String(line))
			} else {
				prose.append(String(line))
			}
		}
		// An unterminated fence still renders as code rather than vanishing.
		if inFence {
			segments.append(.code(code.joined(separator: "\n"), language: language))
		}
		let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		if !joined.isEmpty { segments.append(.prose(joined)) }
		return segments
	}

	static func inline(_ prose: String) -> AttributedString {
		(try? AttributedString(
			markdown: prose,
			options: AttributedString.MarkdownParsingOptions(
				interpretedSyntax: .inlineOnlyPreservingWhitespace)))
			?? AttributedString(prose)
	}
}
