// SPDX-License-Identifier: AGPL-3.0-only

/// Desktop GnuCash's "Find Transactions", simplified to one free-text
/// query: matches a transaction's description, any split's memo, or any
/// split's account name (case-insensitive substring) -- the same fields
/// the web track's `/app/journal?q=` search matches. A blank query
/// matches everything.
public func matchesJournalSearch(
    _ transaction: StoredTransaction,
    query: String,
    accountNames: [Guid: String]
) -> Bool {
    guard !query.isEmpty else { return true }
    let needle = query.lowercased()
    if transaction.description.lowercased().contains(needle) {
        return true
    }
    for split in transaction.splits {
        if split.memo.lowercased().contains(needle) {
            return true
        }
        if let name = accountNames[split.accountGuid], name.lowercased().contains(needle) {
            return true
        }
    }
    return false
}
