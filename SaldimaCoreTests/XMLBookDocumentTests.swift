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

    @Test("memoizes decoded transactions so a repeat balances() call re-decodes nothing")
    func balancesMemoizesTransactionDecode() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))

        _ = document.balances()
        let decodesAfterFirstCall = document.transactionDecodeCountForTesting
        #expect(decodesAfterFirstCall > 0)

        _ = document.balances()
        #expect(document.transactionDecodeCountForTesting == decodesAfterFirstCall)

        _ = document.transactions()
        #expect(document.transactionDecodeCountForTesting == decodesAfterFirstCall)
    }

    @Test("balances() reflects a transaction posted after an earlier call -- the cache invalidates on mutation")
    func balancesInvalidatesCacheOnPost() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bank = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let salary = try #require(document.accounts().first { $0.name == "Salary" }?.guid)

        let before = document.balances()
        let decodesBeforePost = document.transactionDecodeCountForTesting

        let txGuid = try #require(Guid(String(repeating: "7", count: 32)))
        let split1 = try #require(Guid(String(repeating: "8", count: 32)))
        let split2 = try #require(Guid(String(repeating: "9", count: 32)))
        document.postTransaction(
            guid: txGuid,
            date: "2026-04-01",
            description: "Freelance gig",
            splits: [
                (accountGuid: bank, value: try Money(num: 1500, denom: 100), splitGuid: split1),
                (accountGuid: salary, value: try Money(num: -1500, denom: 100), splitGuid: split2),
            ]
        )

        let after = document.balances()
        #expect(document.transactionDecodeCountForTesting > decodesBeforePost)
        #expect(after[bank] == (try Money.add(before[bank] ?? .zero, Money(num: 1500, denom: 100))))
        #expect(after[salary] == (try Money.add(before[salary] ?? .zero, Money(num: -1500, denom: 100))))
    }

    @Test("balances() reflects a voided transaction after an earlier call -- void also invalidates the cache")
    func balancesInvalidatesCacheOnVoid() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let existingTxGuid = try #require(document.transactions().first?.guid)

        _ = document.balances()
        let decodesBeforeVoid = document.transactionDecodeCountForTesting

        document.voidTransaction(existingTxGuid, reason: "test", voidTime: "2026-04-01 00:00:00 +0000")

        let after = document.balances()
        #expect(document.transactionDecodeCountForTesting > decodesBeforeVoid)
        #expect(after.values.allSatisfy { $0 == .zero })
    }

    @Test("creates a customer, an invoice with lines, and posts it as a real transaction")
    func invoicingCRUD() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bank = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let salary = try #require(document.accounts().first { $0.name == "Salary" }?.guid)
        let customerGuid = try #require(Guid(String(repeating: "c", count: 32)))

        let customer = document.createCustomer(
            guid: customerGuid,
            name: "Acme Holdings",
            customerNumber: "C-0001",
            addressName: "Acme Holdings",
            addressLine1: "1 Market St",
            addressLine2: "Suite 400",
            phone: "555-0100",
            email: "billing@acme.test",
            notes: "Net 30",
            currencyCode: "USD"
        )
        #expect(customer.name == "Acme Holdings")
        #expect(document.customers().count == 1)
        #expect(document.customer(customerGuid)?.customerNumber == "C-0001")

        document.updateCustomer(
            customerGuid,
            name: "Acme Holdings LLC",
            customerNumber: "C-0001",
            addressName: "Acme Holdings LLC",
            addressLine1: "1 Market St",
            addressLine2: "Suite 400",
            phone: "555-0100",
            email: "billing@acme.test",
            notes: "Net 30",
            active: true
        )
        #expect(document.customer(customerGuid)?.name == "Acme Holdings LLC")

        let invoiceGuid = try #require(Guid(String(repeating: "d", count: 32)))
        let invoice = document.createInvoice(
            guid: invoiceGuid,
            invoiceNumber: "INV-1001",
            customerGuid: customerGuid,
            dateOpened: "2026-03-01",
            notes: "March premium",
            currencyCode: "USD"
        )
        #expect(invoice.isPosted == false)
        #expect(document.invoices().count == 1)

        let lineGuid = try #require(Guid(String(repeating: "e", count: 32)))
        let entry = document.addInvoiceEntry(
            guid: lineGuid,
            invoiceGuid: invoiceGuid,
            date: "2026-03-01",
            description: "Monthly premium",
            quantity: try Money(num: 1, denom: 1),
            unitPrice: try Money(num: 25000, denom: 100),
            incomeAccountGuid: salary
        )
        #expect(try Money.subtract(entry.amount, Money(num: 25000, denom: 100)) == .zero)
        #expect(document.invoiceEntries(forInvoice: invoiceGuid).count == 1)

        let txGuid = try #require(Guid(String(repeating: "f", count: 32)))
        document.postTransaction(
            guid: txGuid,
            date: "2026-03-01",
            description: "Invoice INV-1001",
            splits: [
                (accountGuid: bank, value: try Money(num: 25000, denom: 100), splitGuid: try #require(Guid(String(repeating: "1", count: 32)))),
                (accountGuid: salary, value: try Money(num: -25000, denom: 100), splitGuid: try #require(Guid(String(repeating: "2", count: 32)))),
            ]
        )
        document.markInvoicePosted(
            invoiceGuid,
            postedDate: "2026-03-01",
            transactionGuid: txGuid,
            receivableAccountGuid: bank
        )
        let posted = try #require(document.invoice(invoiceGuid))
        #expect(posted.isPosted)
        #expect(posted.datePosted == "2026-03-01")
        #expect(posted.postedTransactionGuid == txGuid)
        #expect(posted.receivableAccountGuid == bank)

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.customers().count == 1)
        #expect(reparsed.invoices().count == 1)
        #expect(reparsed.invoiceEntries(forInvoice: invoiceGuid).count == 1)
        let reparsedInvoice = try #require(reparsed.invoice(invoiceGuid))
        #expect(reparsedInvoice.isPosted)
        #expect(reparsedInvoice.customerGuid == customerGuid)

        document.deleteCustomer(customerGuid)
        #expect(document.customer(customerGuid) == nil)
    }

    @Test("refuses to delete a customer that still has invoices")
    func customerInUseGuard() throws {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let customerGuid = try #require(Guid(String(repeating: "c", count: 32)))
        document.createCustomer(
            guid: customerGuid,
            name: "Acme",
            customerNumber: "",
            addressName: "",
            addressLine1: "",
            addressLine2: "",
            phone: "",
            email: "",
            notes: "",
            currencyCode: "USD"
        )
        let invoiceGuid = try #require(Guid(String(repeating: "d", count: 32)))
        document.createInvoice(
            guid: invoiceGuid,
            invoiceNumber: "INV-1",
            customerGuid: customerGuid,
            dateOpened: "2026-03-01",
            notes: "",
            currencyCode: "USD"
        )
        #expect(document.customerInUse(customerGuid))

        document.deleteInvoice(invoiceGuid)
        #expect(document.invoice(invoiceGuid) == nil)
        #expect(document.customerInUse(customerGuid) == false)
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
