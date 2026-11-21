// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore

private func fixturePath(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

private func flatten(_ accounts: [Account]) -> [String] {
    accounts.flatMap { [$0.name] + flatten($0.children) }
}

@Suite("BookStore reads a fixture book")
struct BookStoreTests {
    @Test("lists the account tree in name order")
    func accountTree() async throws {
        let store = try BookStore(url: fixturePath("synthetic-mini.gnucash"))
        let roots = try await store.accounts()
        await store.close()

        #expect(roots.map(\.name) == ["Assets", "Expenses", "Income"])
        #expect(flatten(roots).sorted() == [
            "Assets", "Bank", "Checking", "Expenses", "Income", "Rent", "Salary",
        ])

        let assets = try #require(roots.first { $0.name == "Assets" })
        let bank = try #require(assets.children.first { $0.name == "Bank" })
        #expect(bank.children.map(\.name) == ["Checking"])
        #expect(bank.accountType == "BANK")
        #expect(bank.parentGuid?.rawValue == "11111111111111111111111111111111")
    }

    @Test("marks hidden and placeholder accounts without dropping them")
    func flags() async throws {
        let store = try BookStore(url: fixturePath("synthetic-mini.gnucash"))
        let roots = try await store.accounts()
        await store.close()
        #expect(roots.allSatisfy { !$0.hidden && !$0.placeholder })
    }

    @Test("refuses a file that is not SQLite")
    func notSQLite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-book-\(UUID().uuidString).gnucash")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BookStoreError.notSQLite) {
            _ = try BookStore(url: url)
        }
    }

    @Test("refuses a SQLite file without the GnuCash account schema")
    func missingSchema() throws {
        #expect(throws: BookStoreError.missingSchema) {
            _ = try BookStore(url: fixturePath("no-accounts.sqlite"))
        }
    }

    @Test("refuses a missing file")
    func missingFile() throws {
        #expect(throws: BookStoreError.cannotOpen) {
            _ = try BookStore(url: fixturePath("does-not-exist.gnucash"))
        }
    }
}
