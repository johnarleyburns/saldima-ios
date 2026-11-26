// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

struct RegisterView: View {
    let session: BookSession
    @State private var composing = false

    var body: some View {
        NavigationStack {
            Group {
                if session.transactions.isEmpty {
                    ContentUnavailableView {
                        Label("No transactions", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Post a journal entry to start the register.")
                    } actions: {
                        Button("New transaction") { composing = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(session.transactions) { transaction in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(transaction.description)
                                        .font(.headline)
                                    Spacer()
                                    Text(String(transaction.date.prefix(10)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(transaction.splits, id: \.self) { split in
                                    HStack {
                                        Text(name(of: split.accountGuid))
                                            .font(.subheadline)
                                        Spacer()
                                        Text(session.formatted(split.value))
                                            .font(.subheadline.monospacedDigit())
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Register")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            composing = true
                        } label: {
                            Label("New transaction", systemImage: "plus")
                        }
                        .accessibilityIdentifier("register.add")
                    }
                }
            }
            .sheet(isPresented: $composing) {
                NewTransactionSheet(session: session)
            }
        }
    }

    private func name(of guid: Guid) -> String {
        session.accountOptions().first { $0.guid == guid }?.name ?? "Account"
    }
}

/// Two splits cover a simple payment; up to four more are optional for an
/// entry with a tax or fee line (expense + input tax + payable, say).
private let splitRowCount = 6

private struct NewTransactionSheet: View {
    let session: BookSession

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var description = ""
    @State private var splitAccounts: [Guid?] = Array(repeating: nil, count: splitRowCount)
    @State private var splitAmounts: [String] = Array(repeating: "", count: splitRowCount)
    @State private var localError: String?

    private var options: [(guid: Guid, name: String, depth: Int)] {
        session.accountOptions()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Description", text: $description)
                        .accessibilityIdentifier("transaction.description")
                }
                Section {
                    Text("Each split takes a signed amount; the splits used must sum to zero.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(0..<splitRowCount, id: \.self) { index in
                        Picker(index < 2 ? "Account" : "Account (optional)", selection: $splitAccounts[index]) {
                            Text("Choose").tag(Guid?.none)
                            ForEach(options, id: \.guid) { option in
                                Text(option.name).tag(Guid?.some(option.guid))
                            }
                        }
                        TextField("Amount", text: $splitAmounts[index])
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("transaction.split.\(index).amount")
                    }
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New transaction")
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
        var splits: [(account: Guid, amount: Money)] = []
        for index in 0..<splitRowCount {
            let account = splitAccounts[index]
            let text = splitAmounts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if account == nil && text.isEmpty { continue }
            guard let account, let value = try? Money.parseHalfUp(text, fraction: 100), value != .zero else {
                localError = "Fill in every split used: an account and a non-zero amount."
                return
            }
            splits.append((account: account, amount: value))
        }
        guard splits.count >= 2 else {
            localError = "Use at least two splits."
            return
        }
        Task {
            if await session.post(date: date, description: trimmed, splits: splits) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    RegisterView(session: BookSession())
}
