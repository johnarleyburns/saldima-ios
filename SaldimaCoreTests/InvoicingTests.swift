// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

/// A private temp book per test: these tests mutate (create accounts,
/// customers, invoices, post transactions), so they must never open a
/// shared fixture -- that would corrupt a committed file and race with
/// parallel tests.
private func invoicingBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("invoicing-\(UUID().uuidString).gnucash")
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

@Suite("BookStore customers and invoices")
struct InvoicingTests {
    @Test("creates a customer, drafts an invoice with lines, and posts it")
    func createDraftAndPost() async throws {
        let url = try invoicingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 3000)
        let roots = try await store.accounts()
        let bank = try #require(account(named: "Checking", in: roots))
        let salary = try #require(account(named: "Salary", in: roots))

        let customerGuid = try await store.createCustomer(
            CustomerDraft(name: "Acme Holdings", email: "billing@acme.test"),
            ids: ids
        )
        let customers = try await store.customers()
        #expect(customers.map(\.name) == ["Acme Holdings"])

        let invoiceGuid = try await store.createInvoiceDraft(
            customerGuid: customerGuid,
            invoiceNumber: "INV-1001",
            dateOpened: "2026-03-01",
            ids: ids
        )
        try await store.addInvoiceLine(
            invoiceGuid,
            date: "2026-03-01",
            description: "Monthly premium",
            quantity: try Money(num: 1, denom: 1),
            unitPrice: try Money(num: 25000, denom: 100),
            incomeAccountGuid: salary.guid,
            ids: ids
        )
        let draft = try #require(await store.invoice(invoiceGuid))
        #expect(draft.isPosted == false)
        #expect(draft.lines.count == 1)
        #expect(try Money.subtract(draft.total, Money(num: 25000, denom: 100)) == .zero)

        let txGuid = try await store.postInvoice(
            invoiceGuid,
            receivableAccountGuid: bank.guid,
            postedDate: "2026-03-01",
            ids: ids
        )
        let posted = try #require(await store.invoice(invoiceGuid))
        #expect(posted.isPosted)

        let transactions = try await store.transactions()
        let transaction = try #require(transactions.first { $0.guid == txGuid })
        #expect(transaction.splits.count == 2)
        let total = try transaction.splits.reduce(Money.zero) { try Money.add($0, $1.value) }
        #expect(total == .zero)

        await store.close()
    }

    @Test("refuses to post a draft with no lines, or to edit/delete a posted invoice")
    func guards() async throws {
        let url = try invoicingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 4000)
        let roots = try await store.accounts()
        let bank = try #require(account(named: "Checking", in: roots))
        let salary = try #require(account(named: "Salary", in: roots))

        let customerGuid = try await store.createCustomer(CustomerDraft(name: "Acme"), ids: ids)
        let emptyInvoiceGuid = try await store.createInvoiceDraft(
            customerGuid: customerGuid,
            invoiceNumber: "INV-1",
            dateOpened: "2026-03-01",
            ids: ids
        )
        await #expect(throws: InvoiceEditError.noLines) {
            _ = try await store.postInvoice(
                emptyInvoiceGuid,
                receivableAccountGuid: bank.guid,
                postedDate: "2026-03-01",
                ids: ids
            )
        }

        let invoiceGuid = try await store.createInvoiceDraft(
            customerGuid: customerGuid,
            invoiceNumber: "INV-2",
            dateOpened: "2026-03-01",
            ids: ids
        )
        try await store.addInvoiceLine(
            invoiceGuid,
            date: "2026-03-01",
            description: "Premium",
            quantity: try Money(num: 1, denom: 1),
            unitPrice: try Money(num: 10000, denom: 100),
            incomeAccountGuid: salary.guid,
            ids: ids
        )
        _ = try await store.postInvoice(
            invoiceGuid,
            receivableAccountGuid: bank.guid,
            postedDate: "2026-03-01",
            ids: ids
        )

        await #expect(throws: InvoiceEditError.alreadyPosted(invoiceGuid)) {
            try await store.addInvoiceLine(
                invoiceGuid,
                date: "2026-03-02",
                description: "Extra",
                quantity: try Money(num: 1, denom: 1),
                unitPrice: try Money(num: 100, denom: 100),
                incomeAccountGuid: salary.guid,
                ids: ids
            )
        }
        await #expect(throws: InvoiceEditError.alreadyPosted(invoiceGuid)) {
            try await store.deleteInvoiceDraft(invoiceGuid)
        }

        await store.close()
    }

    @Test("refuses to delete a customer with invoices, but allows it once they're gone")
    func customerInUse() async throws {
        let url = try invoicingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 5000)
        let customerGuid = try await store.createCustomer(CustomerDraft(name: "Acme"), ids: ids)
        let invoiceGuid = try await store.createInvoiceDraft(
            customerGuid: customerGuid,
            invoiceNumber: "INV-1",
            dateOpened: "2026-03-01",
            ids: ids
        )

        await #expect(throws: CustomerEditError.customerInUse) {
            try await store.deleteCustomer(customerGuid)
        }

        try await store.deleteInvoiceDraft(invoiceGuid)
        try await store.deleteCustomer(customerGuid)
        #expect(try await store.customer(customerGuid) == nil)

        await store.close()
    }
}
