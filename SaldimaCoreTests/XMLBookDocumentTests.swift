// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

private func loadFixtureData(_ name: String) throws -> Data {
    let raw = try Data(contentsOf: fixture(name))
    return raw.starts(with: [0x1f, 0x8b]) ? try Gzip.inflate(raw) : raw
}

@Suite("XMLBookDocument")
struct XMLBookDocumentTests {
    @Test("parses the real fixture and preserves structure it does not model")
    func parsesFixture() throws {
        let data = try loadFixtureData("oracle-mini.gnucash")
        let document = try XMLBookDocument.parse(data: data)

        #expect(document.accounts().count == 5)
        #expect(document.transactions().count == 1)
        #expect(document.currency()?.code == "USD")

        let serialized = String(decoding: document.serialize(), as: UTF8.self)
        // The transaction-level gdate slot is not modelled; the original
        // node is never rewritten, so it must survive byte-for-byte.
        #expect(serialized.contains("date-posted"))
        #expect(serialized.contains("gdate"))
        #expect(serialized.contains("xmlns:lot"))
    }

    @Test("creates, updates and deletes an account, preserving unrelated accounts")
    func accountCRUD() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bankGuid = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let guid = try #require(Guid(String(repeating: "1", count: 32)))

        let created = document.createAccount(
            guid: guid,
            name: "Petty Cash",
            type: "CASH",
            parentGuid: bankGuid,
            code: "1010",
            description: "Cash box",
            hidden: false,
            placeholder: true,
            commodityGuid: nil
        )
        #expect(created.name == "Petty Cash")
        #expect(document.account(guid)?.placeholder == true)

        document.updateAccount(
            guid,
            name: "Petty Cash Box",
            type: "CASH",
            parentGuid: bankGuid,
            code: "1010",
            description: "Cash box",
            hidden: true,
            placeholder: true
        )
        let updated = try #require(document.account(guid))
        #expect(updated.name == "Petty Cash Box")
        #expect(updated.hidden == true)
        #expect(updated.placeholder == true)

        document.updateAccount(
            guid,
            name: updated.name,
            type: updated.type,
            parentGuid: updated.parentGuid,
            code: updated.code,
            description: updated.description,
            hidden: false,
            placeholder: true
        )
        #expect(document.account(guid)?.hidden == false)

        let serialized = String(decoding: document.serialize(), as: UTF8.self)
        #expect(serialized.contains("Salary")) // unrelated account untouched
        #expect(serialized.contains("gdate")) // transaction slot untouched

        document.deleteAccount(guid)
        #expect(document.account(guid) == nil)
    }

    @Test("posts and deletes a transaction")
    func transactionCRUD() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bank = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let salary = try #require(document.accounts().first { $0.name == "Salary" }?.guid)
        let txGuid = try #require(Guid(String(repeating: "2", count: 32)))
        let split1 = try #require(Guid(String(repeating: "3", count: 32)))
        let split2 = try #require(Guid(String(repeating: "4", count: 32)))

        let posted = document.postTransaction(
            guid: txGuid,
            date: "2026-02-01",
            description: "Coffee",
            splits: [
                (accountGuid: bank, value: try Money(num: -500, denom: 100), splitGuid: split1),
                (accountGuid: salary, value: try Money(num: 500, denom: 100), splitGuid: split2),
            ]
        )
        #expect(posted.description == "Coffee")
        #expect(document.transactions().count == 2)

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.transaction(txGuid)?.description == "Coffee")

        document.deleteTransaction(txGuid)
        #expect(document.transaction(txGuid) == nil)
        #expect(document.transactions().count == 1)
    }

    @Test("builds a fresh document from a snapshot, for the import boundary")
    func buildsFromSnapshot() throws {
        let root = try #require(Guid(String(repeating: "5", count: 32)))
        let bank = try #require(Guid(String(repeating: "6", count: 32)))
        let salary = try #require(Guid(String(repeating: "7", count: 32)))
        let tx = try #require(Guid(String(repeating: "8", count: 32)))
        let templateRoot = try #require(Guid(String(repeating: "9", count: 32)))

        let snapshot = BookSnapshot(
            bookGuid: try #require(Guid(String(repeating: "a", count: 32))),
            currencyCode: "EUR",
            fraction: 100,
            accounts: [
                SnapshotAccount(guid: root, name: "Root Account", type: "ROOT"),
                SnapshotAccount(guid: bank, name: "Bank", type: "BANK", parentGuid: root),
                SnapshotAccount(guid: salary, name: "Salary", type: "INCOME", parentGuid: root),
            ],
            transactions: [
                SnapshotTransaction(
                    guid: tx,
                    date: "2026-01-15",
                    description: "Opening deposit",
                    currencyCode: "EUR",
                    splits: [
                        SnapshotSplit(accountGuid: bank, value: try Money(num: 250_000, denom: 100)),
                        SnapshotSplit(accountGuid: salary, value: try Money(num: -250_000, denom: 100)),
                    ]
                ),
            ]
        )

        let document = XMLBookDocument.build(
            from: snapshot,
            templateRootGuid: templateRoot,
            ids: SeededIDGenerator(start: 1000)
        )
        #expect(document.accounts().count == 4) // root + bank + salary + template root
        #expect(document.transactions().count == 1)
        #expect(document.currency()?.code == "EUR")

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.accounts().count == 4)
        #expect(reparsed.transactions().first?.description == "Opening deposit")
    }
}
