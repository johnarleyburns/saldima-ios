// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func temporaryBook() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("saldima-xml-\(UUID().uuidString).gnucash")
}

private func find(_ name: String, in nodes: [Account]) -> Account? {
    for node in nodes {
        if node.name == name { return node }
        if let match = find(name, in: node.children) { return match }
    }
    return nil
}

@Suite("XML book writer")
struct XMLBookWriterTests {
    @Test("exports gzip XML that reopens with the same tree and postings")
    func roundTrip() async throws {
        let url = temporaryBook()
        defer { try? FileManager.default.removeItem(at: url) }
        try BookWriter.create(at: url, template: BookTemplates.personal, ids: SeededIDGenerator())

        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let checking = try #require(find("Checking", in: roots))
        let salary = try #require(find("Salary", in: roots))
        let hiddenGuid = try await store.createAccount(
            AccountDraft(name: "Coffee & Tea", type: .expense, hidden: true),
            ids: SeededIDGenerator(start: 300)
        )
        try await store.post(
            date: "2026-11-24",
            description: "Opening & deposit",
            splits: [
                StoredSplit(accountGuid: checking.guid, value: try Money(num: 1_000, denom: 100)),
                StoredSplit(accountGuid: salary.guid, value: try Money(num: -1_000, denom: 100)),
            ],
            ids: SeededIDGenerator(start: 400)
        )

        let snapshot = try await store.exportSnapshot()
        let data = try XMLBookWriter.data(snapshot, ids: SeededIDGenerator(start: 500))
        #expect(data.starts(with: [0x1f, 0x8b]))

        let exportURL = temporaryBook()
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try data.write(to: exportURL)
        let read = try XMLBookReader.read(at: exportURL)

        #expect(read.currencyCode == "USD")
        #expect(read.fraction == 100)
        let root = try #require(read.accounts.first { $0.type == "ROOT" })
        #expect(read.accounts.contains { $0.name == "Root Account" })
        let assets = try #require(read.accounts.first { $0.name == "Assets" })
        #expect(assets.parentGuid == root.guid)
        #expect(read.accounts.first { $0.name == "Checking" }?.commodityCode == "USD")
        #expect(read.accounts.first { $0.name == "Investments" }?.placeholder == true)
        #expect(read.accounts.first { $0.guid == hiddenGuid }?.hidden == true)
        #expect(read.accounts.first { $0.name == "Coffee & Tea" }?.name == "Coffee & Tea")

        #expect(read.transactions.count == 1)
        let transaction = try #require(read.transactions.first)
        #expect(transaction.description == "Opening & deposit")
        #expect(transaction.date == "2026-11-24")
        #expect(transaction.currencyCode == "USD")
        #expect(transaction.splits.count == 2)
        #expect(transaction.splits.map(\.accountGuid) == [checking.guid, salary.guid])
        #expect(transaction.splits[0].value == (try Money(num: 1_000, denom: 100)))
        #expect(transaction.splits[1].value == (try Money(num: -1_000, denom: 100)))
        await store.close()
    }

    @Test("writes an oracle copy when asked")
    func oracleCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["SALDIMA_XML_EXPORT_PATH"],
              !path.isEmpty
        else { return }
        let url = temporaryBook()
        defer { try? FileManager.default.removeItem(at: url) }
        try BookWriter.create(at: url, template: BookTemplates.insuranceAgency, ids: SeededIDGenerator())
        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let trust = try #require(find("Premium Trust", in: roots))
        let commissions = try #require(find("Commissions", in: roots))
        try await store.post(
            date: "2026-11-24",
            description: "Oracle commission",
            splits: [
                StoredSplit(accountGuid: trust.guid, value: try Money(num: 1_250, denom: 100)),
                StoredSplit(accountGuid: commissions.guid, value: try Money(num: -1_250, denom: 100)),
            ],
            ids: SeededIDGenerator(start: 900)
        )
        let snapshot = try await store.exportSnapshot()
        try XMLBookWriter.write(
            at: URL(fileURLWithPath: path),
            snapshot: snapshot,
            ids: SeededIDGenerator(start: 950),
            overwrite: true
        )
        await store.close()
    }
}
