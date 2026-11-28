// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import SaldimaCore

/// QIF/OFX/CSV/PDF statement import: pick a file, review a parsed preview
/// (a default-account picker, a per-category account picker, a
/// possible-duplicate flag with a per-row include/exclude toggle), then
/// post one balanced transaction per included row via the ported
/// `planImport`. Ported semantics from the web track's
/// `packages/importers`; the PDF line-parsing heuristic
/// (`SaldimaCore/ImportPdf.swift`) has no web equivalent to port, since
/// web's own importer never needed to read a PDF.
struct ImportStatementView: View {
    let session: BookSession
    let account: Account

    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var fileName = ""
    @State private var parsed: ImportResult?
    @State private var parseError: String?
    @State private var defaultAccountGuid: Guid?
    @State private var categoryAccountGuids: [String: Guid] = [:]
    @State private var excludedIndices: Set<Int> = []
    @State private var isCommitting = false
    @State private var commitError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let parsed {
                    previewSections(for: parsed)
                } else {
                    pickerSection
                }
            }
            .navigationTitle("Import statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let parsed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { commit(parsed) }
                            .buttonStyle(.glassProminent)
                            .disabled(isCommitting || !canCommit(parsed))
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: importableContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePicked(result)
            }
        }
    }

    private var importableContentTypes: [UTType] {
        [
            .pdf,
            .commaSeparatedText,
            .plainText,
            UTType(filenameExtension: "qif") ?? .plainText,
            UTType(filenameExtension: "ofx") ?? .plainText,
            UTType(filenameExtension: "qfx") ?? .plainText,
            .data,
        ]
    }

    @ViewBuilder
    private var pickerSection: some View {
        Section {
            Button("Choose statement file\u{2026}") { showFilePicker = true }
                .accessibilityIdentifier("importStatement.choose")
        } footer: {
            Text("QIF, OFX/QFX, CSV, or a text-based PDF statement from your bank or credit card.")
        }
        if let parseError {
            Section {
                Text(parseError).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func previewSections(for result: ImportResult) -> some View {
        Section {
            LabeledContent("File", value: fileName)
            LabeledContent("Format", value: result.source.rawValue.uppercased())
            LabeledContent("Rows found", value: "\(result.rows.count)")
        }
        if !result.warnings.isEmpty {
            Section("Warnings") {
                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section {
            Picker("Default account", selection: $defaultAccountGuid) {
                Text("Choose an account").tag(Guid?.none)
                ForEach(session.accountOptions(), id: \.guid) { option in
                    Text(String(repeating: "  ", count: option.depth) + option.name)
                        .tag(Guid?.some(option.guid))
                }
            }
            .accessibilityIdentifier("importStatement.defaultAccount")
        } footer: {
            Text(
                "Used for any row whose category isn't mapped below, and to balance any CSV split row whose categories don't already add up to the row's total."
            )
        }
        let categoryKeys = categories(in: result)
        if !categoryKeys.isEmpty {
            Section("Categories") {
                ForEach(categoryKeys, id: \.self) { category in
                    Picker(selection: categoryBinding(category)) {
                        Text("Use default account").tag(Guid?.none)
                        ForEach(session.accountOptions(), id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    } label: {
                        Text(category)
                    }
                }
            }
        }
        Section("Transactions") {
            ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                rowView(index: index, row: row)
            }
        }
        if let commitError {
            Section {
                Text(commitError).foregroundStyle(.red)
            }
        }
    }

    private func rowView(index: Int, row: ImportRow) -> some View {
        let included = !excludedIndices.contains(index)
        let duplicate = isLikelyDuplicate(row, existing: existingEntries)
        return Button {
            if included {
                excludedIndices.insert(index)
            } else {
                excludedIndices.remove(index)
            }
        } label: {
            HStack {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(included ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle(row))
                    HStack(spacing: 6) {
                        Text(row.date)
                        if !row.category.isEmpty {
                            Text("\u{2022} \(row.category)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if duplicate {
                        Text("Possible duplicate")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(session.formatted(row.amount))
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("importStatement.row.\(index)")
    }

    private func rowTitle(_ row: ImportRow) -> String {
        if !row.payee.isEmpty { return row.payee }
        if !row.memo.isEmpty { return row.memo }
        return "(no description)"
    }

    /// Existing posted splits on the target account, for `isLikelyDuplicate`.
    private var existingEntries: [ExistingEntry] {
        session.transactions.flatMap { transaction in
            transaction.splits
                .filter { $0.accountGuid == account.guid }
                .map { ExistingEntry(date: String(transaction.date.prefix(10)), amount: $0.value) }
        }
    }

    /// Every distinct `categoryKey` across both row-level and CSV-split
    /// categories, in the same normalised form `planImport` maps through.
    private func categories(in result: ImportResult) -> [String] {
        var seen: Set<String> = []
        var keys: [String] = []
        for row in result.rows {
            for raw in [row.category] + row.splits.map(\.category) {
                let key = categoryKey(raw)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                keys.append(key)
            }
        }
        return keys.sorted()
    }

    private func categoryBinding(_ category: String) -> Binding<Guid?> {
        Binding(
            get: { categoryAccountGuids[category] },
            set: { newValue in
                if let newValue {
                    categoryAccountGuids[category] = newValue
                } else {
                    categoryAccountGuids.removeValue(forKey: category)
                }
            }
        )
    }

    private func canCommit(_ result: ImportResult) -> Bool {
        guard defaultAccountGuid != nil else { return false }
        return result.rows.indices.contains { !excludedIndices.contains($0) }
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        parseError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            let imported: ImportResult
            if url.pathExtension.lowercased() == "pdf" {
                imported = try parsePdf(data)
            } else {
                imported = try parseImportFile(fileName: name, text: decodeText(data))
            }
            fileName = name
            defaultAccountGuid = nil
            categoryAccountGuids = [:]
            let existing = existingEntries
            excludedIndices = Set(
                imported.rows.indices.filter { isLikelyDuplicate(imported.rows[$0], existing: existing) }
            )
            parsed = imported
        } catch let error as ImportFormatError {
            parseError = error.message
        } catch {
            parseError = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    /// The current calendar year, for `parsePdfStatementText`'s fallback
    /// when a statement prints no year anywhere -- read once at import
    /// time rather than injected, matching how `BookSession.refresh()`
    /// already reads "today" for scheduled-transaction processing: the
    /// pure PDF heuristic itself takes the year as a parameter and never
    /// calls a clock, which is the seam that keeps it unit-testable.
    private func parsePdf(_ data: Data) throws -> ImportResult {
        let text = extractPdfText(from: data) ?? ""
        let fallbackYear = Calendar.current.component(.year, from: Date())
        return try parsePdfStatementText(text, fallbackYear: fallbackYear)
    }

    private func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private func commit(_ result: ImportResult) {
        guard let defaultAccountGuid else { return }
        let includedRows = result.rows.indices
            .filter { !excludedIndices.contains($0) }
            .map { result.rows[$0] }
        let mapping = ImportMapping(
            targetAccountGuid: account.guid,
            defaultAccountGuid: defaultAccountGuid,
            categoryAccounts: categoryAccountGuids
        )
        do {
            let planned = try planImport(includedRows, mapping: mapping)
            commitError = nil
            isCommitting = true
            Task {
                for transaction in planned {
                    await session.post(
                        dateString: transaction.date,
                        description: transaction.description,
                        splits: transaction.splits.map { ($0.accountGuid, $0.value) }
                    )
                }
                isCommitting = false
                dismiss()
            }
        } catch {
            commitError = "Couldn't plan these transactions: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ImportStatementView(
        session: BookSession(),
        account: Account(
            guid: Guid(String(repeating: "1", count: 32))!,
            name: "Checking",
            accountType: "BANK",
            parentGuid: nil,
            hidden: false,
            placeholder: false
        )
    )
}
