// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SaldimaCore

struct SettingsView: View {
    let session: BookSession
    @AppStorage(ThemeKeys.accent) private var accentRaw = AccentChoice.indigo.rawValue
    @AppStorage(ThemeKeys.appearance) private var appearanceRaw = AppearanceChoice.system.rawValue
    @State private var exportDocument: XMLExportDocument?
    @State private var exporting = false
    @State private var exportFilename = "Saldima-xml.gnucash"

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
                    Button {
                        Task {
                            guard let result = await session.exportXML() else { return }
                            exportDocument = XMLExportDocument(data: result.data)
                            exportFilename = result.filename
                            exporting = true
                        }
                    } label: {
                        Label("Export as GnuCash XML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!session.isOpen)
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
                Section("Help") {
                    NavigationLink("Help topics") { HelpView() }
                }
                Section("Support") {
                    SupporterCard()
                }
                Section("Source") {
                    Link("Source code", destination: SourceOffer.repository)
                }
            }
            .navigationTitle("Settings")
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: XMLExportDocument.contentType,
                defaultFilename: exportFilename
            ) { _ in
                exportDocument = nil
            }
            .alert(
                "Saldima",
                isPresented: Binding(
                    get: { session.lastError != nil },
                    set: { if !$0 { session.clearError() } }
                )
            ) {
                Button("OK", role: .cancel) { session.clearError() }
            } message: {
                Text(session.lastError ?? "")
            }
        }
    }
}

/// Carries a finished gzip XML export to the system document picker.
struct XMLExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [contentType] }
    static var contentType: UTType {
        UTType(filenameExtension: "gnucash") ?? .data
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
