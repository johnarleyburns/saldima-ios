// SPDX-License-Identifier: AGPL-3.0-only
import PhotosUI
import SwiftUI
import UIKit

import SaldimaCore

/// Capture a receipt, post the expense it documents, and keep the two
/// linked -- GnuCash's own "Associate File/Location", not a Saldima-only
/// bolt-on. `BookSession.postReceiptExpense` does the posting; this view
/// is just the camera roll picker and the quick expense form.
struct ReceiptsView: View {
    let session: BookSession
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImageData: Data?

    private var receiptTransactions: [StoredTransaction] {
        session.transactions.filter { $0.docLink != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if receiptTransactions.isEmpty {
                    ContentUnavailableView {
                        Label("No receipts", systemImage: "doc.viewfinder")
                    } description: {
                        Text("Capture a receipt to post the expense it documents.")
                    } actions: {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text("Add receipt")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(receiptTransactions) { transaction in
                            ReceiptRow(session: session, transaction: transaction)
                        }
                    }
                }
            }
            .navigationTitle("Receipts")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Add receipt", systemImage: "plus")
                        }
                        .accessibilityIdentifier("receipts.add")
                    }
                }
            }
            .onChange(of: pickerItem) {
                Task {
                    if let item = pickerItem, let data = try? await item.loadTransferable(type: Data.self) {
                        pickedImageData = data
                    }
                    pickerItem = nil
                }
            }
            .sheet(item: Binding(
                get: { pickedImageData.map { ReceiptImage(data: $0) } },
                set: { pickedImageData = $0?.data }
            )) { picked in
                NewReceiptExpenseSheet(session: session, imageData: picked.data)
            }
        }
    }
}

private struct ReceiptImage: Identifiable {
    let data: Data
    var id: Int { data.hashValue }
}

private struct ReceiptRow: View {
    let session: BookSession
    let transaction: StoredTransaction

    private var thumbnail: Image {
        guard let docLink = transaction.docLink,
              let data = session.receiptImageData(docLink),
              let uiImage = UIImage(data: data)
        else {
            return Image(systemName: "doc.viewfinder")
        }
        return Image(uiImage: uiImage)
    }

    /// The expense leg's (positive, debit) amount, for a quick glance.
    private var amount: Money {
        transaction.splits.first { $0.value.num > 0 }?.value ?? .zero
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(.body)
                Text(String(transaction.date.prefix(10)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.formatted(amount))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}

private struct NewReceiptExpenseSheet: View {
    let session: BookSession
    let imageData: Data

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var description = ""
    @State private var amount = ""
    @State private var expenseAccount: Guid?
    @State private var paymentAccount: Guid?
    @State private var localError: String?

    private var expenseAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        filteredAccountOptions(in: session.accounts, types: ["EXPENSE"])
    }

    private var paymentAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        filteredAccountOptions(in: session.accounts, types: ["ASSET", "BANK", "CASH", "CREDIT", "LIABILITY"])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity)
                    }
                }
                Section {
                    TextField("Description", text: $description)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    Picker("Expense account", selection: $expenseAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(expenseAccountOptions, id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    }
                    Picker("Paid from", selection: $paymentAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(paymentAccountOptions, id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    }
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func post() {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localError = "Enter a description."
            return
        }
        guard let expenseAccount, let paymentAccount else {
            localError = "Choose both accounts."
            return
        }
        guard let value = try? Money.parseHalfUp(amount, fraction: 100), value != .zero, value.num > 0 else {
            localError = "Enter an amount like 42.00."
            return
        }
        Task {
            if await session.postReceiptExpense(
                date: date,
                description: trimmed,
                amount: value,
                expenseAccount: expenseAccount,
                paymentAccount: paymentAccount,
                imageData: imageData
            ) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

private func filteredAccountOptions(
    in nodes: [Account],
    types: Set<String>,
    depth: Int = 0
) -> [(guid: Guid, name: String, depth: Int)] {
    var rows: [(Guid, String, Int)] = []
    for node in nodes {
        if types.contains(node.accountType) && !node.placeholder {
            rows.append((node.guid, node.name, depth))
        }
        rows += filteredAccountOptions(in: node.children, types: types, depth: depth + 1)
    }
    return rows
}

#Preview {
    ReceiptsView(session: BookSession())
}
