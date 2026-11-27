// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Journal search")
struct JournalSearchTests {
    @Test("matches by description, split memo or account name, case-insensitively, and a blank query matches everything")
    func matches() throws {
        let bank = Guid(String(repeating: "1", count: 32))!
        let rent = Guid(String(repeating: "2", count: 32))!
        let names = [bank: "Checking", rent: "Rent"]

        let transaction = StoredTransaction(
            guid: Guid(String(repeating: "a", count: 32))!,
            date: "2026-02-01",
            description: "Grocery run",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: -4_000, denom: 100), memo: "weekly shop"),
                StoredSplit(accountGuid: rent, value: try Money(num: 4_000, denom: 100)),
            ]
        )

        #expect(matchesJournalSearch(transaction, query: "", accountNames: names))
        #expect(matchesJournalSearch(transaction, query: "GROCERY", accountNames: names))
        #expect(matchesJournalSearch(transaction, query: "weekly", accountNames: names))
        #expect(matchesJournalSearch(transaction, query: "checking", accountNames: names))
        #expect(matchesJournalSearch(transaction, query: "rent", accountNames: names))
        #expect(!matchesJournalSearch(transaction, query: "no such transaction", accountNames: names))
    }
}
