// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SaldimaCore

struct SettingsView: View {
    let session: BookSession

    var body: some View {
        NavigationStack {
            List {
                Section("Book") {
                    LabeledContent("Open book", value: session.bookName)
                    Menu("Create a book from a template") {
                        ForEach(BookTemplates.all) { template in
                            Button(template.name) {
                                Task {
                                    await session.createBook(
                                        named: template.name,
                                        template: template,
                                        currency: .usd
                                    )
                                }
                            }
                        }
                    }
                }
                Section("About") {
                    NavigationLink("About Saldima") {
                        AboutView()
                    }
                }
                Section("Support") {
                    SupporterCard()
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
    SettingsView(session: BookSession())
}
