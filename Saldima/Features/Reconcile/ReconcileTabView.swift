// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// The top-level "Reconcile" tab: pick an account to open the existing
/// per-account reconcile screen, which also hosts the statement importer.
/// Previously Reconcile was a button buried inside each account's "Edit
/// account" sheet -- unreachable enough that the owner found it nearly
/// unusable in the field.
struct ReconcileTabView: View {
    let session: BookSession
    @State private var selected: Account?

    private struct Row: Identifiable {
        let account: Account
        let depth: Int
        var id: Guid { account.guid }
    }

    private var rows: [Row] {
        func walk(_ nodes: [Account], depth: Int) -> [Row] {
            nodes.flatMap { node -> [Row] in
                var result: [Row] = []
                if node.accountType != "ROOT" && !node.placeholder {
                    result.append(Row(account: node, depth: depth))
                }
                result += walk(node.children, depth: depth + 1)
                return result
            }
        }
        return walk(session.accounts, depth: 0)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !session.isOpen {
                    ContentUnavailableView(
                        "No book open",
                        systemImage: "book.closed",
                        description: Text("Open a book from the Accounts tab to reconcile an account.")
                    )
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "building.columns",
                        description: Text("Add an account from the Accounts tab first.")
                    )
                } else {
                    List(rows) { row in
                        Button {
                            selected = row.account
                        } label: {
                            Text(String(repeating: "  ", count: row.depth) + row.account.name)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("reconcile.account.\(row.account.guid.rawValue)")
                    }
                }
            }
            .navigationTitle("Reconcile")
            .sheet(item: $selected) { account in
                ReconcileView(session: session, account: account)
            }
        }
    }
}

#Preview {
    ReconcileTabView(session: BookSession())
}
