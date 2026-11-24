// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct HelpView: View {
    private let topics: [(String, String)] = [
        ("Getting started", "Create a book from a template, choose the currency and add your first bank account. The file lives on this device."),
        ("Accounts", "The chart of accounts is a tree. Fold branches with the chevrons; placeholder accounts group children and cannot receive postings."),
        ("Register and journal", "Post a balanced entry from Register. Every split keeps an exact fraction and account balances update immediately."),
        ("Reports", "Trial balance, balance sheet and profit and loss read the same posted splits, with half-even display."),
        ("GnuCash compatibility", "SQLite and gzip XML books use the desktop schema. Posting rounds half-up; display rounds half-even."),
        ("Supporter", "The one-time Supporter purchase is optional and never unlocks a feature."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(topics, id: \.0) { topic in
                    DisclosureGroup(topic.0) {
                        Text(topic.1).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Original text for this app, following the same chapter order as the GnuCash manual.")
            }
        }
        .navigationTitle("Help")
    }
}

#Preview {
    NavigationStack { HelpView() }
}
