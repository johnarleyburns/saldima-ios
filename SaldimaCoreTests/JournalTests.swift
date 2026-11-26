// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
@testable import SaldimaTestKit

private func journalBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-\(UUID().uuidString).gnucash")
    try BookWriter.create(at: url, template: BookTemplates.personal, ids: SeededIDGenerator())
    return url
}

private func account(named name: String, in nodes: [Account]) -> Account? {
    for node in nodes {
        if node.name == name { return node }
        if let match = account(named: name, in: node.children) { return match }
    }
    return nil
}

@Suite("Journal posting")
struct JournalTests {
    @Test("posts a balanced entry, updates balances and reopens")
    func postsAndPersists() async throws {
        let url = try journalBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 900)
        let roots = try await store.accounts()
        let checking = try #require(account(named: "Checking", in: roots))
        let salary = try #require(account(named: "Salary", in: roots))

        let tx = try await store.post(
            date: "2025-02-01",
            description: "Salary",
            splits: [
                StoredSplit(accountGuid: checking.guid, value: try Money(num: 250_000, denom: 100)),
                StoredSplit(accountGuid: salary.guid, value: try Money(num: -250_000, denom: 100)),
            ],
            ids: ids
        )
        #expect(try await store.transactions().count == 1)
        let balances = try await store.balances()
        #expect(balances[checking.guid] == (try Money(num: 2_500, denom: 1)))
        #expect(balances[salary.guid] == (try Money(num: -2_500, denom: 1)))
        await store.close()

        let reopened = try BookStore(url: url)
        let transactions = try await reopened.transactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.guid == tx)
        #expect(transactions.first?.description == "Salary")
        #expect(transactions.first?.date.hasPrefix("2025-02-01") == true)
        await reopened.close()
    }

    @Test("rejects unbalanced, unknown and invalid journals")
    func rejections() async throws {
        let url = try journalBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 901)
        let roots = try await store.accounts()
        let checking = try #require(account(named: "Checking", in: roots))
        let salary = try #require(account(named: "Salary", in: roots))
        let unknown = Guid(String(repeating: "c", count: 32))!

        await #expect(throws: JournalError.unbalanced) {
            try await store.post(
                date: "2025-02-01",
                description: "Bad",
                splits: [
                    StoredSplit(accountGuid: checking.guid, value: try Money(num: 100, denom: 100)),
                    StoredSplit(accountGuid: salary.guid, value: try Money(num: -90, denom: 100)),
                ],
                ids: ids
            )
        }
        await #expect(throws: JournalError.unknownAccount(unknown)) {
            try await store.post(
                date: "2025-02-01",
                description: "Unknown",
                splits: [
                    StoredSplit(accountGuid: checking.guid, value: try Money(num: 100, denom: 100)),
                    StoredSplit(accountGuid: unknown, value: try Money(num: -100, denom: 100)),
                ],
                ids: ids
            )
        }
        await #expect(throws: JournalError.invalidDate) {
            try await store.post(
                date: "02/01/2025",
                description: "Bad date",
                splits: [
                    StoredSplit(accountGuid: checking.guid, value: try Money(num: 100, denom: 100)),
                    StoredSplit(accountGuid: salary.guid, value: try Money(num: -100, denom: 100)),
                ],
                ids: ids
            )
        }
        await store.close()
    }
}

extension JournalTests {
    @Test("attaches, reads and removes a receipt (GnuCash's doc-link) on a posted transaction")
    func receiptAttachment() async throws {
        let url = try journalBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator()
        let roots = try await store.accounts()
        let bank = try #require(account(named: "Checking", in: roots))
        let rent = try #require(account(named: "Rent", in: roots))

        let txGuid = try await store.post(
            date: "2026-03-01",
            description: "Office supplies",
            splits: [
                StoredSplit(accountGuid: bank.guid, value: try Money(num: -4200, denom: 100)),
                StoredSplit(accountGuid: rent.guid, value: try Money(num: 4200, denom: 100)),
            ],
            receiptPath: "receipts/one.jpg",
            ids: ids
        )
        var transactions = try await store.transactions()
        #expect(transactions.first { $0.guid == txGuid }?.docLink == "receipts/one.jpg")

        try await store.attachReceipt("receipts/two.jpg", to: txGuid)
        transactions = try await store.transactions()
        #expect(transactions.first { $0.guid == txGuid }?.docLink == "receipts/two.jpg")

        try await store.attachReceipt(nil, to: txGuid)
        transactions = try await store.transactions()
        #expect(transactions.first { $0.guid == txGuid }?.docLink == nil)

        await store.close()
    }
}
