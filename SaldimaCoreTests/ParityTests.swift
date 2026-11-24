// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func temporaryBook() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("saldima-\(UUID().uuidString).gnucash")
}

private func flatten(_ nodes: [Account], parent: String? = nil) -> [(String, Account)] {
    nodes.flatMap { node -> [(String, Account)] in
        let path = parent.map { "\($0)/\(node.name)" } ?? node.name
        return [(path, node)] + flatten(node.children, parent: path)
    }
}

private func find(_ name: String, in nodes: [Account]) -> Account? {
    for node in nodes {
        if node.name == name { return node }
        if let match = find(name, in: node.children) { return match }
    }
    return nil
}

private func makeBook(_ template: BookTemplate = BookTemplates.personal) throws -> URL {
    let url = temporaryBook()
    try BookWriter.create(at: url, template: template, ids: SeededIDGenerator())
    return url
}

@Suite("Book writer")
struct BookWriterTests {
    @Test("every template creates a book that reopens with the same tree")
    func createsTemplates() async throws {
        for template in BookTemplates.all {
            let url = try makeBook(template)
            defer { try? FileManager.default.removeItem(at: url) }

            let store = try BookStore(url: url)
            let roots = try await store.accounts()
            #expect(roots.map(\.name).sorted() == template.roots.map(\.name).sorted())

            let actual = flatten(roots)
            let expected = BookTemplates.flatten(template)
            #expect(actual.map(\.0).sorted() == expected.map(\.path).sorted())

            for row in expected {
                let match = actual.first { $0.0 == row.path }?.1
                #expect(match?.accountType == row.type.rawValue, "type for \(row.path)")
                #expect(match?.placeholder == row.placeholder, "placeholder for \(row.path)")
                #expect(match?.hidden == false, "hidden for \(row.path)")
            }
            await store.close()
        }
    }

    @Test("refuses to overwrite unless asked")
    func overwriteGuard() throws {
        let url = try makeBook()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BookWriterError.alreadyExists) {
            try BookWriter.create(at: url, template: BookTemplates.personal, ids: SeededIDGenerator())
        }
        try BookWriter.create(
            at: url,
            template: BookTemplates.insuranceAgency,
            ids: SeededIDGenerator(start: 99),
            overwrite: true
        )
    }

    @Test("writes an oracle copy when asked")
    func oracleCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["SALDIMA_ORACLE_BOOK_PATH"],
              !path.isEmpty
        else { return }
        let url = URL(fileURLWithPath: path)
        try BookWriter.create(
            at: url,
            template: BookTemplates.insuranceAgency,
            ids: SeededIDGenerator(start: 4242),
            overwrite: true
        )
    }

    @Test("creates the USD commodity at cents precision")
    func currency() async throws {
        let url = try makeBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let checking = find("Checking", in: try await store.accounts())
        let currency = try await store.bookCurrency()
        #expect(currency?.code == "USD")
        #expect(currency?.fraction == 100)
        #expect(checking != nil)
        await store.close()
    }
}

@Suite("Account editing")
struct AccountEditingTests {
    @Test("create, update, move, hide and delete a leaf account")
    func lifecycle() async throws {
        let url = try makeBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 500)

        let assets = find("Assets", in: try await store.accounts())
        let expenses = find("Expenses", in: try await store.accounts())
        #expect(assets != nil)
        #expect(expenses != nil)

        let guid = try await store.createAccount(
            AccountDraft(
                name: "  Travel  ",
                type: .expense,
                parentGuid: assets?.guid,
                code: "6100"
            ),
            ids: ids
        )
        var created = try await store.account(guid)
        #expect(created?.name == "Travel")
        #expect(created?.accountType == "EXPENSE")
        #expect(created?.code == "6100")
        #expect(created?.parentGuid == assets?.guid)

        try await store.updateAccount(
            guid,
            with: AccountDraft(
                name: "Travel & Meals",
                type: .expense,
                parentGuid: expenses?.guid,
                code: "6200",
                description: "Client meals",
                hidden: true,
                placeholder: true
            )
        )
        created = try await store.account(guid)
        #expect(created?.name == "Travel & Meals")
        #expect(created?.parentGuid == expenses?.guid)
        #expect(created?.description == "Client meals")
        #expect(created?.hidden == true)
        #expect(created?.placeholder == true)
        #expect(find("Travel & Meals", in: try await store.accounts())?.guid == guid)

        try await store.deleteAccount(guid)
        #expect(try await store.account(guid) == nil)
        await store.close()

        let reopened = try BookStore(url: url)
        #expect(find("Travel & Meals", in: try await reopened.accounts()) == nil)
        await reopened.close()
    }

    @Test("rejects invalid names, unknown parents and moves into a subtree")
    func rejections() async throws {
        let url = try makeBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 700)
        let roots = try await store.accounts()
        let assets = try #require(find("Assets", in: roots))
        let bank = try #require(find("Bank", in: roots))

        await #expect(throws: AccountEditError.invalidName) {
            try await store.createAccount(AccountDraft(name: "   ", type: .asset), ids: ids)
        }
        let longName = String(repeating: "x", count: 201)
        await #expect(throws: AccountEditError.invalidName) {
            try await store.createAccount(AccountDraft(name: longName, type: .asset), ids: ids)
        }
        let unknown = Guid(String(repeating: "a", count: 32))!
        await #expect(throws: AccountEditError.unknownAccount(unknown)) {
            try await store.createAccount(
                AccountDraft(name: "Orphan", type: .asset, parentGuid: unknown),
                ids: ids
            )
        }
        await #expect(throws: AccountEditError.moveIntoSubtree) {
            try await store.updateAccount(
                assets.guid,
                with: AccountDraft(name: "Assets", type: .asset, parentGuid: bank.guid)
            )
        }
        // The structural root is not a row, like GnuCash's Accounts window.
        #expect(find("Root Account", in: roots) == nil)
        await store.close()
    }

    @Test("refuses to delete an account that has children or splits")
    func deleteGuards() async throws {
        let url = try makeBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let assets = try #require(find("Assets", in: roots))
        await #expect(throws: AccountEditError.accountHasChildren) {
            try await store.deleteAccount(assets.guid)
        }
        await #expect(throws: AccountEditError.unknownAccount(Guid(String(repeating: "b", count: 32))!)) {
            try await store.deleteAccount(Guid(String(repeating: "b", count: 32))!)
        }
        await store.close()
    }
}

@Suite("Ledger verification parity")
struct LedgerVerifyTests {
    private let bank = Guid(String(repeating: "1", count: 32))!
    private let sales = Guid(String(repeating: "2", count: 32))!

    private func ledger(bankValue: Int64, salesValue: Int64) -> Ledger {
        let accounts = [
            LedgerAccount(id: bank, name: "Bank", type: .bank),
            LedgerAccount(id: sales, name: "Sales", type: .income),
        ]
        let transaction = LedgerTransaction(
            id: Guid(String(repeating: "9", count: 32))!,
            date: "2025-03-01",
            description: "imported",
            splits: [
                LedgerSplit(accountId: bank, value: try! Money(num: bankValue, denom: 100)),
                LedgerSplit(accountId: sales, value: try! Money(num: salesValue, denom: 100)),
            ]
        )
        return Ledger(accounts: accounts, transactions: [transaction])
    }

    @Test("a balanced imported ledger has no findings")
    func balanced() throws {
        let findings = try LedgerEngine.verify(ledger(bankValue: 100, salesValue: -100), asOf: "2025-12-31")
        #expect(findings.isEmpty)
    }

    @Test("an unbalanced imported ledger reports both invariants")
    func unbalanced() throws {
        let findings = try LedgerEngine.verify(ledger(bankValue: 100, salesValue: -90), asOf: "2025-12-31")
        #expect(findings.map(\.code) == [.unbalancedTrialBalance, .assetsNotEqualLiabilitiesPlusEquity])
        #expect(findings.first?.message == "trial balance debits do not equal credits")
    }
}

@Suite("Account rollups")
struct AccountRollupTests {
    @Test("parents total their own and descendant balances")
    func rollups() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollup-\(UUID().uuidString).gnucash")
        defer { try? FileManager.default.removeItem(at: url) }
        try BookWriter.create(at: url, template: BookTemplates.personal, ids: SeededIDGenerator())
        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let checking = find("Checking", in: roots)
        let bank = find("Bank", in: roots)
        let assets = find("Assets", in: roots)
        #expect(checking != nil)
        let balances: [Guid: Money] = [
            try #require(checking?.guid): try Money(num: 1_000, denom: 1),
        ]
        let totals = try AccountRollup.totals(roots, balances: balances)
        #expect(totals[try #require(checking?.guid)] == (try Money(num: 1_000, denom: 1)))
        #expect(totals[try #require(bank?.guid)] == (try Money(num: 1_000, denom: 1)))
        #expect(totals[try #require(assets?.guid)] == (try Money(num: 1_000, denom: 1)))
        await store.close()
    }
}
