// The "jump between your prompts" pill: ▲ 3/12 ▼ floating above the composer,
// with a long-press sheet listing every prompt. Hidden below two marks.

import ConductorKit
import SwiftUI

struct MessageNavigator: View {
	let entries: [TranscriptEntry]
	@Binding var index: Int?
	let jump: (String) -> Void
	@State private var showList = false

	var body: some View {
		if entries.count >= 2 {
			HStack(spacing: 2) {
				Button {
					step(-1)
				} label: {
					Image(systemName: "chevron.up")
						.frame(width: 36, height: 36)
				}
				Button {
					showList = true
				} label: {
					Text("\((index ?? entries.count - 1) + 1)/\(entries.count)")
						.font(.footnote.monospacedDigit().weight(.medium))
						.frame(minWidth: 44)
				}
				Button {
					step(1)
				} label: {
					Image(systemName: "chevron.down")
						.frame(width: 36, height: 36)
				}
			}
			.buttonStyle(.plain)
			.glassEffect()
			.padding(.trailing, 12)
			.padding(.bottom, 8)
			.sensoryFeedback(.selection, trigger: index)
			.sheet(isPresented: $showList) {
				promptList
			}
		}
	}

	private func step(_ delta: Int) {
		let next = max(0, min(entries.count - 1, (index ?? entries.count - 1) + delta))
		index = next
		jump(entries[next].key)
	}

	private var promptList: some View {
		NavigationStack {
			List(Array(entries.enumerated()), id: \.element.key) { i, entry in
				Button {
					showList = false
					index = i
					jump(entry.key)
				} label: {
					HStack(alignment: .top, spacing: 10) {
						Text("\(i + 1)")
							.font(.caption.monospacedDigit())
							.foregroundStyle(.tertiary)
						Text(entry.text)
							.font(.subheadline)
							.lineLimit(2)
						Spacer()
						if let date = SQLiteDate.parse(entry.ts) {
							// One coarse unit ("51 min. ago"), never the self-ticking
							// two-unit style — seconds are noise at this altitude and
							// the ticking redrew the sheet every second.
							Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
				}
			}
			.navigationTitle("Your prompts")
			.navigationBarTitleDisplayMode(.inline)
		}
		.presentationDetents([.medium, .large])
	}
}
