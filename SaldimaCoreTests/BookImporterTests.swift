// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

private func temporaryBookURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("imported-\(UUID().uuidString).gnucash")
}

@Suite("Book importer")
struct BookImporterTests {
    @Test("materializes an XML book as a live, editable SQLite working copy")
    func importsXML() async throws {
        let snapshot = try XMLBookReader.read(at: fixture("oracle-mini.gnucash"))
        let url = temporaryBookURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator())

        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let transactions = try await store.transactions()

        func flatten(_ accounts: [Account]) -> [Account] {
            accounts + accounts.flatMap { flatten($0.children) }
        }
        let all = flatten(roots)
        #expect(Set(all.map(\.name)) == ["Assets", "Bank", "Income", "Salary"])
        let bank = try #require(all.first { $0.name == "Bank" })
        #expect(bank.accountType == "BANK")

        #expect(transactions.count == 1)
        let posted = try #require(transactions.first)
        #expect(posted.description == "Opening deposit")
        #expect(posted.splits.count == 2)
        let total = try posted.splits.reduce(Money.zero) { try Money.add($0, $1.value) }
        #expect(total == Money.zero)

        // The imported copy is a real working book: it keeps accepting new
        // postings exactly like one created on-device.
        let newAccountGuid = try await store.createAccount(
            AccountDraft(name: "Petty Cash", type: .cash, parentGuid: bank.parentGuid),
            ids: SeededIDGenerator(start: 1000)
        )
        #expect(try await store.account(newAccountGuid) != nil)
        await store.close()
    }

    @Test("refuses to materialize an empty snapshot")
    func refusesEmpty() throws {
        let snapshot = BookSnapshot(
            bookGuid: Guid(String(repeating: "a", count: 32))!,
            accounts: [],
            transactions: []
        )
        let url = temporaryBookURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BookImporterError.emptySnapshot) {
            try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator())
        }
    }

    @Test("refuses to overwrite an existing file unless asked")
    func refusesOverwrite() throws {
        let snapshot = try XMLBookReader.read(at: fixture("oracle-mini.gnucash"))
        let url = temporaryBookURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator())

        #expect(throws: BookImporterError.alreadyExists) {
            try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator())
        }
        try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator(), overwrite: true)
    }
}

@Suite("Gronewald synthetic ledger fixture")
struct GronewaldFixtureTests {
    @Test("imports the real ~3,300-transaction synthetic ledger and reopens it")
    func importsGronewaldFixture() async throws {
        let snapshot = try XMLBookReader.read(at: fixture("gronewald-gl-2023-01.gnucash"))
        #expect(snapshot.transactions.count == 3305)

        let url = temporaryBookURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try BookImporter.materialize(snapshot, at: url, ids: SeededIDGenerator())

        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let transactions = try await store.transactions()
        await store.close()

        func flatten(_ accounts: [Account]) -> [Account] {
            accounts + accounts.flatMap { flatten($0.children) }
        }
        #expect(flatten(roots).filter { $0.accountType != "ROOT" }.count == 22)
        #expect(transactions.count == 3305)

        var total = Money.zero
        for transaction in transactions {
            for split in transaction.splits {
                total = try Money.add(total, split.value)
            }
        }
        #expect(total == Money.zero)
    }
}
