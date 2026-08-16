// Conductor Remote's palette, ported from web/src/index.css as semantic
// colors. Dark-first: the app renders the same identity in light mode by
// keeping the accent family and letting system materials adapt around it.

import ConductorKit
import SwiftUI

extension Color {
	init(hex: UInt32) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255)
	}

	// Surfaces
	static let appBackground = Color(hex: 0x0A0B0E)
	static let surface = Color(hex: 0x14161B)
	static let surfaceRaised = Color(hex: 0x1B1E26)

	// Identity
	static let accent = Color(hex: 0x8B7DFF)
	static let accentSoft = Color(hex: 0x2A2650)

	/// The agent is mid-turn — Conductor's amber.
	static let working = Color(hex: 0xF5A623)

	// PR states (drive the status ring at rest)
	static let prMerged = Color(hex: 0xAC47FF)
	static let prDraft = Color(hex: 0xA4A3A2)
	static let prConflicts = Color(hex: 0xFD9A00)
	static let prMergeable = Color(hex: 0x49DE80)

	// Diff
	static let diffAdd = Color(hex: 0x3ECF8E)
	static let diffDelete = Color(hex: 0xFF6B6B)

	static func pr(_ status: PrStatus?) -> Color {
		switch status {
		case .merged: .prMerged
		case .draft: .prDraft
		case .conflicts: .prConflicts
		case .mergeable: .prMergeable
		case nil: .accent
		}
	}

	/// Workspace status → its canonical color (Linear-style five states).
	static func status(_ status: String?) -> Color {
		switch status {
		case "done": .prMergeable
		case "in-review": .prMerged
		case "in-progress": .working
		case "setting-up": .accent
		case "backlog": .secondary
		case "canceled": Color(hex: 0x6B7280)
		default: .secondary
		}
	}
}

enum StatusStyle {
	/// SF Symbol per manual status, echoing Linear's iconography.
	static func symbol(_ status: String?) -> String {
		switch status {
		case "done": "checkmark.circle.fill"
		case "in-review": "eye.circle.fill"
		case "in-progress": "circle.lefthalf.filled"
		case "setting-up": "gearshape.circle"
		case "backlog": "circle.dashed"
		case "canceled": "xmark.circle"
		default: "circle"
		}
	}

	static func label(_ status: String?) -> String {
		switch status {
		case "done": "Done"
		case "in-review": "In review"
		case "in-progress": "In progress"
		case "setting-up": "Setting up"
		case "backlog": "Backlog"
		case "canceled": "Canceled"
		default: status ?? "No status"
		}
	}
}
