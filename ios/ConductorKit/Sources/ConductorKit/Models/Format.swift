// Product formatting rules ported from web/src/lib/format.ts — these encode
// Conductor's own precedence and belong with the models, not the views.

import Foundation

public enum Format {
	/// Workspace display title, following Conductor's own precedence:
	/// manual name → PR title → humanized branch → worktree codename → id.
	public static func workspaceLabel(_ w: Workspace) -> String {
		if let name = w.workspaceName, !name.isEmpty { return name }
		if let title = w.prTitle, !title.isEmpty { return title }
		if let branch = w.branch, !branch.isEmpty { return humanizeBranch(branch) }
		if let dir = w.directoryName, !dir.isEmpty { return dir }
		return String(w.id.prefix(8))
	}

	/// "user/fix-the-thing" → "Fix the thing": strip the owner prefix,
	/// de-kebab, sentence-case.
	public static func humanizeBranch(_ branch: String) -> String {
		let tail = branch.split(separator: "/").last.map(String.init) ?? branch
		let words = tail.replacingOccurrences(of: "-", with: " ")
			.replacingOccurrences(of: "_", with: " ")
			.trimmingCharacters(in: .whitespaces)
		guard let first = words.first else { return branch }
		return first.uppercased() + words.dropFirst()
	}

	/// "claude-opus-5-20250514" → "opus-5": strip the claude- prefix, a
	/// trailing date stamp, and "-latest".
	public static func shortModel(_ model: String?) -> String? {
		guard var m = model, !m.isEmpty else { return nil }
		if m.hasPrefix("claude-") { m = String(m.dropFirst("claude-".count)) }
		if m.hasSuffix("-latest") { m = String(m.dropLast("-latest".count)) }
		if let range = m.range(of: #"-\d{8}$"#, options: .regularExpression) {
			m = String(m[..<range.lowerBound])
		}
		return m
	}

	/// The status a workspace sorts and colours under: manual wins, then derived.
	public static func status(_ w: Workspace) -> String? {
		w.manualStatus ?? w.derivedStatus
	}

	/// Board group order, mirroring STATUS_ORDER in format.ts — active work
	/// first (setting-up is a brand-new workspace, seconds from in-progress),
	/// finished work last. Unknown statuses sort after the known ones, in
	/// first-seen order.
	public static let statusOrder = ["setting-up", "in-progress", "in-review", "backlog", "done", "canceled"]

	public static func statusRank(_ status: String?) -> Int {
		guard let status, let index = statusOrder.firstIndex(of: status) else { return statusOrder.count }
		return index
	}
}
