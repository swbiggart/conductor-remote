import ConductorKit
import SwiftUI

/// Settings ▸ Appearance ▸ Text size. Two different meanings by surface, on
/// purpose: the **transcript** follows it as a Dynamic Type pin (system
/// default, one larger, two smaller), while the **workspace list** keeps
/// system-size text and answers the smaller settings with *density* — tighter
/// padding, smaller avatar — because shrinking a list you scan at a glance
/// helps less than fitting more of it on screen.
enum TextScale: String, CaseIterable {
	case large, system, small, extraSmall

	var label: String {
		switch self {
		case .large: "Large"
		case .system: "System"
		case .small: "Small"
		case .extraSmall: "Extra small"
		}
	}

	/// The transcript's Dynamic Type pin; nil = follow the device.
	var dynamicTypeSize: DynamicTypeSize? {
		switch self {
		case .large: .xLarge
		case .system: nil
		case .small: .medium
		case .extraSmall: .small
		}
	}

	/// How much the workspace list tightens at this setting.
	var listDensity: ListDensity {
		switch self {
		case .large, .system: .regular
		case .small: .compact
		case .extraSmall: .tight
		}
	}
}

enum ListDensity {
	case regular, compact, tight

	var avatarSize: CGFloat {
		switch self {
		case .regular: 36
		case .compact: 32
		case .tight: 28
		}
	}

	var rowVerticalPadding: CGFloat {
		switch self {
		case .regular: 4
		case .compact: 2
		case .tight: 0
		}
	}

	var rowSpacing: CGFloat {
		switch self {
		case .regular: 10
		case .compact: 8
		case .tight: 8
		}
	}
}

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var confirmDisconnect = false
	@AppStorage("ui.textScale") private var textScale = TextScale.system

	var body: some View {
		NavigationStack {
			Form {
				Section("Connection") {
					LabeledContent("Relay", value: model.credentials?.baseURL.host() ?? "—")
					if let version = model.relayVersion {
						LabeledContent("Relay version", value: version)
					}
					if let update = model.update, update.available {
						LabeledContent("Update") {
							Text("v\(update.latest ?? "?") \(update.mode == "auto" ? "installing…" : "available")")
								.foregroundStyle(Color.working)
						}
					}
					LabeledContent("Status") {
						Text(model.online ? "Connected" : "Offline")
							.foregroundStyle(model.online ? Color.prMergeable : Color.diffDelete)
					}
					if let actuator = model.actuator, !actuator.precise {
						Text(actuator.caveat)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}

				Section {
					Toggle(
						"Show steps while working",
						isOn: Binding(get: { model.liveSteps }, set: { model.setLiveSteps($0) }))
					Picker("Text size", selection: $textScale) {
						ForEach(TextScale.allCases, id: \.self) { scale in
							Text(scale.label).tag(scale)
						}
					}
				} header: {
					Text("Appearance")
				} footer: {
					Text(
						"Steps on: the working turn's steps stream as individual rows, like the Mac app; off keeps them collapsed into a live-updating \"N steps\" group until the turn ends. Text size scales every screen."
					)
				}

				Section("Notifications") {
					// Phase 5 (APNs) lands here. Stated honestly until then.
					Text(
						"Push notifications need the APNs build (paid Apple Developer account). Until then, keep the app open to watch a turn — or keep the web app installed alongside for pushes."
					)
					.font(.footnote)
					.foregroundStyle(.secondary)
				}

				Section {
					NavigationLink("Relay logs") {
						LogsView()
					}
				}

				Section {
					Button("Disconnect", role: .destructive) {
						confirmDisconnect = true
					}
				} footer: {
					Text("Removes this phone's token. Drafts and read marks are kept.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
			.confirmationDialog("Disconnect from the relay?", isPresented: $confirmDisconnect) {
				Button("Disconnect", role: .destructive) {
					Task {
						await model.disconnect()
					}
				}
			}
		}
	}
}

struct LogsView: View {
	@Environment(AppModel.self) private var model
	@State private var file: String?
	@State private var problemsOnly = false

	private var entries: [LogEntry] {
		let all = model.logsData?.entries ?? []
		return problemsOnly ? all.filter { $0.level != .info } : all
	}

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					if model.logsData?.managed == false && file != nil {
						Text("These files belong to the LaunchAgent — a different process from the relay you're talking to.")
							.font(.caption2)
							.foregroundStyle(Color.working)
							.padding(.bottom, 4)
					}
					ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							if let t = entry.t {
								Text(Date(timeIntervalSince1970: t / 1000), format: .dateTime.hour().minute().second())
									.foregroundStyle(.tertiary)
							}
							Text(entry.text)
								.foregroundStyle(color(entry.level))
						}
						.font(.caption2.monospaced())
					}
					Color.clear.frame(height: 1).id("tail")
				}
				.padding(12)
			}
			.defaultScrollAnchor(.bottom)
			.onChange(of: entries.count) {
				proxy.scrollTo("tail")
			}
		}
		.background(Color.appBackground)
		.navigationTitle("Relay logs")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Picker("Source", selection: $file) {
						Text("Live").tag(String?.none)
						ForEach(model.logsData?.files ?? [], id: \.name) { info in
							Text(info.name).tag(String?.some(info.name))
						}
					}
					Toggle("Problems only", isOn: $problemsOnly)
					Button("Copy visible") {
						UIPasteboard.general.string = entries.map(\.text).joined(separator: "\n")
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
		.task(id: file) {
			model.setLogsVisible(true, file: file)
		}
		.onDisappear {
			model.setLogsVisible(false)
		}
	}

	private func color(_ level: LogLevel) -> Color {
		switch level {
		case .info: Color(.secondaryLabel)
		case .warn: .working
		case .error: .diffDelete
		}
	}
}
