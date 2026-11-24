// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SaldimaCore

struct SettingsView: View {
    let session: BookSession
    @AppStorage(ThemeKeys.accent) private var accentRaw = AccentChoice.indigo.rawValue
    @AppStorage(ThemeKeys.appearance) private var appearanceRaw = AppearanceChoice.system.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    HStack(spacing: 14) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                accentRaw = choice.rawValue
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if choice.rawValue == accentRaw {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.name)
                            .accessibilityAddTraits(
                                choice.rawValue == accentRaw ? .isSelected : []
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.name).tag(choice.rawValue)
                        }
                    }
                }
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
