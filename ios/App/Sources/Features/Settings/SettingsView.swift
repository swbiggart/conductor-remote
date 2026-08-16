import ConductorKit
import SwiftUI

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var confirmDisconnect = false

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
				} header: {
					Text("Transcript")
				} footer: {
					Text(
						"On: the working turn's steps stream as individual rows, like the Mac app. Off: they stay collapsed into a live-updating \"N steps\" group until the turn ends."
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
