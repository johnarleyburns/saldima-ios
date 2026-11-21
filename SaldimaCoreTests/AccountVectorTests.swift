// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore

private struct AccountRow: Decodable, Equatable {
    let guid: String
    let name: String
    let type: String
    let parent: String?
    let hidden: Bool
    let placeholder: Bool
}

private struct AccountVectors: Decodable {
    let schemaVersion: Int
    let book: String
    let accounts: [AccountRow]
}

private func loadAccountVectors() throws -> AccountVectors {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let url = root.appendingPathComponent("Fixtures/vectors/accounts.json")
    return try JSONDecoder().decode(AccountVectors.self, from: Data(contentsOf: url))
}

@Suite("Golden vectors: account tree")
struct AccountVectorTests {
    @Test("the SQLite actor matches the web-defined tree")
    func matchesWebVector() async throws {
        let vectors = try loadAccountVectors()
        #expect(vectors.schemaVersion == 1)
        #expect(vectors.book == "synthetic-mini")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = try BookStore(url: root.appendingPathComponent("Fixtures/books/synthetic-mini.gnucash"))
        let tree = try await store.accounts()
        await store.close()

        var rows: [AccountRow] = []
        func visit(_ account: Account) {
            rows.append(
                AccountRow(
                    guid: account.guid.rawValue,
                    name: account.name,
                    type: account.accountType,
                    parent: account.parentGuid?.rawValue,
                    hidden: account.hidden,
                    placeholder: account.placeholder
                )
            )
            account.children.forEach(visit)
        }
        tree.forEach(visit)

        #expect(rows.sorted { $0.guid < $1.guid } == vectors.accounts.sorted { $0.guid < $1.guid })
        #expect(rows.count == 7)
    }
}
