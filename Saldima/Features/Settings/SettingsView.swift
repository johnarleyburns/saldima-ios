// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SaldimaCore

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    NavigationLink("About Saldima") {
                        AboutView()
                    }
                }
                Section("Source") {
                    Link("Source code", destination: SourceOffer.repository)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct AboutView: View {
    private var commit: String {
        Bundle.main.object(forInfoDictionaryKey: "SaldimaSourceCommit") as? String ?? ""
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Saldima", value: "Compatible with GnuCash")
            }
            Section("Free software") {
                Text("Saldima is licensed AGPL-3.0-only. The source for this build is public.")
                Link("Source at this build", destination: SourceOffer.url(commit: commit))
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    SettingsView()
}
