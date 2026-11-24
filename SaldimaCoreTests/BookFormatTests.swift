// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

@Suite("Book file formats")
struct BookFormatTests {
    @Test("detects SQLite and gzip-compressed XML by their bytes")
    func detection() throws {
        #expect(try BookFile.detect(at: fixture("oracle-mini.sqlite.gnucash")) == .sqlite)
        #expect(try BookFile.detect(at: fixture("oracle-mini.gnucash")) == .xml)
    }

    @Test("refuses an unknown file")
    func unknown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unknown-\(UUID().uuidString).gnucash")
        try Data("not a book".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BookFormatError.unknown) {
            _ = try BookFile.detect(at: url)
        }
    }

    @Test("reads the GnuCash XML backend")
    func readsXML() throws {
        let snapshot = try XMLBookReader.read(at: fixture("oracle-mini.gnucash"))

        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.fraction == 100)
        #expect(snapshot.accounts.count == 5)

        let byName = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.name, $0) })
        #expect(byName["Root Account"]?.type == "ROOT")
        #expect(byName["Assets"]?.type == "ASSET")
        #expect(byName["Bank"]?.type == "BANK")
        #expect(byName["Income"]?.type == "INCOME")
        #expect(byName["Salary"]?.type == "INCOME")
        #expect(byName["Assets"]?.parentGuid == byName["Root Account"]?.guid)
        #expect(byName["Bank"]?.parentGuid == byName["Assets"]?.guid)
        #expect(byName["Salary"]?.parentGuid == byName["Income"]?.guid)
        #expect(byName["Bank"]?.commodityCode == "USD")

        #expect(snapshot.transactions.count == 1)
        let transaction = try #require(snapshot.transactions.first)
        #expect(transaction.description == "Opening deposit")
        #expect(transaction.date == "2025-01-15")
        #expect(transaction.currencyCode == "USD")
        #expect(transaction.splits.count == 2)

        let bank = try #require(byName["Bank"]?.guid)
        let salary = try #require(byName["Salary"]?.guid)
        let bankSplit = try #require(transaction.splits.first { $0.accountGuid == bank })
        let salarySplit = try #require(transaction.splits.first { $0.accountGuid == salary })
        #expect(bankSplit.value == (try Money(num: 250_000, denom: 100)))
        #expect(salarySplit.value == (try Money(num: -250_000, denom: 100)))
        let total = try transaction.splits.reduce(Money.zero) { try Money.add($0, $1.value) }
        #expect(total == Money.zero)
    }

    @Test("XML and SQLite fixtures describe the same chart")
    func crossFormatAccounts() async throws {
        let snapshot = try XMLBookReader.read(at: fixture("oracle-mini.gnucash"))
        let store = try BookStore(url: fixture("oracle-mini.sqlite.gnucash"))
        let stored = try await store.accounts()
        await store.close()

        var flat: [(String, String, Guid?)] = []
        func walk(_ nodes: [Account], depth: Int = 0) {
            for node in nodes {
                flat.append((node.name, node.accountType, node.parentGuid))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(stored)

        let xmlRows = snapshot.accounts
            .filter { $0.type != "ROOT" }
            .map { ($0.name, $0.type) }
            .sorted { $0.0 < $1.0 }
        let sqliteRows = flat.map { ($0.0, $0.1) }.sorted { $0.0 < $1.0 }
        #expect(xmlRows.map(\.0) == sqliteRows.map(\.0))
        #expect(xmlRows.map(\.1) == sqliteRows.map(\.1))
    }
}
