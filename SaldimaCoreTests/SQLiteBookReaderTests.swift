// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

@Suite("SQLiteBookReader")
struct SQLiteBookReaderTests {
    @Test("reads a SQLite-dialect book into the same shape the XML reader produces")
    func readsSQLiteDialect() throws {
        let snapshot = try SQLiteBookReader.read(at: fixture("oracle-mini.sqlite.gnucash"))
        let xmlSnapshot = try XMLBookReader.read(at: fixture("oracle-mini.gnucash"))

        #expect(snapshot.currencyCode == "USD")
        #expect(
            Set(snapshot.accounts.map { $0.name }) == Set(xmlSnapshot.accounts.map { $0.name })
        )
        #expect(snapshot.transactions.count == xmlSnapshot.transactions.count)
    }

    @Test("feeds straight into XMLBookDocument.build, the import boundary")
    func materializesAsXML() throws {
        let snapshot = try SQLiteBookReader.read(at: fixture("oracle-mini.sqlite.gnucash"))
        let templateRoot = try #require(Guid(String(repeating: "f", count: 32)))
        let document = XMLBookDocument.build(
            from: snapshot,
            templateRootGuid: templateRoot,
            ids: SeededIDGenerator(start: 5000)
        )
        #expect(document.transactions().count == snapshot.transactions.count)
        #expect(document.accounts().contains { $0.name == "Bank" })
    }

    @Test("refuses a file that is not SQLite")
    func refusesNonSQLite() {
        #expect(throws: BookStoreError.notSQLite) {
            _ = try SQLiteBookReader.read(at: fixture("oracle-mini.gnucash"))
        }
    }
}
