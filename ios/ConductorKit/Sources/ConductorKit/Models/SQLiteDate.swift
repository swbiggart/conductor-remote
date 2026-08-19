// Conductor's SQLite timestamps are "yyyy-MM-dd HH:mm:ss" — UTC, with no T and
// no Z. The PWA feeds them to Date.parse, which reads them as *local* time and
// silently skews every displayed age by the UTC offset; this parser exists so
// the native app doesn't inherit that bug. Parse pinned to UTC, always.
//
// Not every timestamp should become a Date: read marks compare `updated_at`
// strings lexically against values from the same column (see ReadMarks) — the
// format sorts correctly as text, and staying in the column's own alphabet is
// what makes the comparison immune to clock skew and parser drift.

import Foundation

public enum SQLiteDate {
	/// DateFormatter is expensive to build and documented thread-safe since
	/// iOS 7 / macOS 10.9 for formatting and parsing, so one shared instance.
	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss"
		f.timeZone = TimeZone(identifier: "UTC")
		f.locale = Locale(identifier: "en_US_POSIX")
		return f
	}()

	nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

	public static func parse(_ raw: String?) -> Date? {
		guard let raw, !raw.isEmpty else { return nil }
		// Conductor mixes formats per column (verified live): `created_at` is
		// SQLite "yyyy-MM-dd HH:mm:ss" UTC, while `updated_at` is ISO 8601
		// with milliseconds ("2026-08-16T00:48:19.600Z"). Handle both; the
		// lexical read-mark comparisons stay per-column so they don't care.
		if raw.contains("T") {
			return iso.date(from: raw) ?? isoPlain.date(from: raw)
		}
		if let date = formatter.date(from: raw) { return date }
		// SQLite-format values may (rarely) carry fractional seconds — retry
		// with the fraction stripped rather than failing the whole row.
		if let dot = raw.firstIndex(of: ".") {
			return formatter.date(from: String(raw[..<dot]))
		}
		return nil
	}
}
