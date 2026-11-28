// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// Desktop GnuCash's Reconcile window: check off every split that appears
/// on a bank or credit card statement, then finish once the cleared total
/// matches the statement's ending balance. Distinct from bank
/// integration/auto-feeds (this app does none of that) -- this only
/// records what the owner checked off by hand.
struct ReconcileView: View {
    let session: BookSession
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @State private var statementDate = Date()
    @State private var statementBalanceText = ""
    @State private var error: String?
    @State private var importingStatement = false

    private struct Row: Identifiable {
        let transactionGuid: Guid
        let splitGuid: Guid
        let date: String
        let description: String
        let value: Money
        let checked: Bool
        var id: Guid { splitGuid }
    }

    private var rows: [Row] {
        session.transactions
            .flatMap { transaction in
                transaction.splits.compactMap { split -> Row? in
                    guard split.accountGuid == account.guid,
                          split.reconcileState != "y",
                          let splitGuid = split.guid
                    else {
                        return nil
                    }
                    return Row(
                        transactionGuid: transaction.guid,
                        splitGuid: splitGuid,
                        date: transaction.date,
                        description: transaction.description,
                        value: split.value,
                        checked: split.reconcileState == "c"
                    )
                }
            }
            .sorted { $0.date < $1.date }
    }

    private var clearedTotal: Money {
        rows.filter(\.checked).reduce(Money.zero) { sum, row in
            (try? Money.add(sum, row.value)) ?? sum
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Statement date", selection: $statementDate, displayedComponents: .date)
                    TextField("Statement ending balance", text: $statementBalanceText)
                        .accessibilityIdentifier("reconcile.statementBalance")
                } footer: {
                    Text(
                        "Check off every transaction that appears on your statement. The cleared total must match the statement's ending balance before you can finish."
                    )
                }
                Section {
                    HStack {
                        Text("Cleared total so far")
                        Spacer()
                        Text(session.formatted(clearedTotal))
                            .foregroundStyle(.secondary)
                    }
                }
                if rows.isEmpty {
                    Section {
                        Text("Nothing left to reconcile.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(rows) { row in
                            Button {
                                Task {
                                    await session.setSplitReconcileState(
                                        transactionGuid: row.transactionGuid,
                                        splitGuid: row.splitGuid,
                                        state: row.checked ? "n" : "c",
                                        reconcileDate: nil
                                    )
                                }
                            } label: {
                                HStack {
                                    Image(systemName: row.checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(row.checked ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.description)
                                        Text(row.date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(session.formatted(row.value))
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reconcile \(account.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Import statement\u{2026}") { importingStatement = true }
                        .accessibilityIdentifier("reconcile.importStatement")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish reconciling") { finish() }
                        .buttonStyle(.glassProminent)
                        .disabled(rows.isEmpty)
                }
            }
            .sheet(isPresented: $importingStatement) {
                ImportStatementView(session: session, account: account)
            }
        }
    }

    private func finish() {
        guard let target = try? Money.parse(statementBalanceText, fraction: 100) else {
            error = "Enter amounts like 1234.56 or -1234.56."
            return
        }
        guard (try? Money.subtract(clearedTotal, target)) == .zero else {
            error =
                "Not balanced yet: cleared total is \(session.formatted(clearedTotal)), statement balance is \(session.formatted(target))."
            return
        }
        error = nil
        let toReconcile = rows.filter(\.checked)
        Task {
            for row in toReconcile {
                await session.setSplitReconcileState(
                    transactionGuid: row.transactionGuid,
                    splitGuid: row.splitGuid,
                    state: "y",
                    reconcileDate: statementDate
                )
            }
            dismiss()
        }
    }
}

#Preview {
    ReconcileView(
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
