// One compact sheet for group/sort/repo — Linear's filter control, not three
// header buttons.

import ConductorKit
import SwiftUI

struct FilterSheet: View {
	@Binding var groupBy: String
	@Binding var sortBy: String
	@Binding var repoFilter: String
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss

	private var repos: [String] {
		Array(Set(model.workspaces.compactMap(\.repoName))).sorted()
	}

	var body: some View {
		NavigationStack {
			Form {
				Picker("Group by", selection: $groupBy) {
					Text("Status").tag("status")
					Text("Repo").tag("repo")
					Text("None").tag("none")
				}
				.pickerStyle(.segmented)

				Picker("Sort by", selection: $sortBy) {
					Text("Updated").tag("updated")
					Text("Created").tag("created")
					Text("Name").tag("name")
				}
				.pickerStyle(.segmented)

				Section("Repository") {
					Picker("Repository", selection: $repoFilter) {
						Text("All repos").tag("")
						ForEach(repos, id: \.self) { repo in
							Text(repo).tag(repo)
						}
					}
					.pickerStyle(.inline)
					.labelsHidden()
				}
			}
			.navigationTitle("View")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
	}
}
