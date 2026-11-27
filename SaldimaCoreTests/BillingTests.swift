// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

/// A private temp book per test: these tests mutate (create accounts,
/// vendors, bills, post transactions), so they must never open a shared
/// fixture -- that would corrupt a committed file and race with parallel
/// tests.
private func billingBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("billing-\(UUID().uuidString).gnucash")
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

@Suite("BookStore vendors and bills")
struct BillingTests {
    @Test("creates a vendor, drafts a bill with lines, and posts it")
    func createDraftAndPost() async throws {
        let url = try billingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 6000)
        let roots = try await store.accounts()
        let bank = try #require(account(named: "Checking", in: roots))
        let rent = try #require(account(named: "Rent", in: roots))

        let vendorGuid = try await store.createVendor(
            VendorDraft(name: "Acme Supplies", email: "ap@acme.test"),
            ids: ids
        )
        let vendors = try await store.vendors()
        #expect(vendors.map(\.name) == ["Acme Supplies"])

        let billGuid = try await store.createBillDraft(
            vendorGuid: vendorGuid,
            billNumber: "BILL-1001",
            dateOpened: "2026-03-01",
            ids: ids
        )
        try await store.addBillLine(
            billGuid,
            date: "2026-03-01",
            description: "Office rent",
            quantity: try Money(num: 1, denom: 1),
            unitPrice: try Money(num: 80000, denom: 100),
            expenseAccountGuid: rent.guid,
            ids: ids
        )
        let draft = try #require(await store.bill(billGuid))
        #expect(draft.isPosted == false)
        #expect(draft.lines.count == 1)
        #expect(try Money.subtract(draft.total, Money(num: 80000, denom: 100)) == .zero)

        // A bill must never show up as an invoice, and vice versa, even
        // though they share the same underlying GncInvoice element.
        #expect(try await store.invoices().isEmpty)

        let txGuid = try await store.postBill(
            billGuid,
            payableAccountGuid: bank.guid,
            postedDate: "2026-03-01",
            ids: ids
        )
        let posted = try #require(await store.bill(billGuid))
        #expect(posted.isPosted)

        let transactions = try await store.transactions()
        let transaction = try #require(transactions.first { $0.guid == txGuid })
        #expect(transaction.splits.count == 2)
        let total = try transaction.splits.reduce(Money.zero) { try Money.add($0, $1.value) }
        #expect(total == .zero)

        await store.close()
    }

    @Test("refuses to post a draft with no lines, or to edit/delete a posted bill")
    func guards() async throws {
        let url = try billingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 7000)
        let roots = try await store.accounts()
        let bank = try #require(account(named: "Checking", in: roots))
        let rent = try #require(account(named: "Rent", in: roots))

        let vendorGuid = try await store.createVendor(VendorDraft(name: "Acme"), ids: ids)
        let emptyBillGuid = try await store.createBillDraft(
            vendorGuid: vendorGuid,
            billNumber: "BILL-1",
            dateOpened: "2026-03-01",
            ids: ids
        )
        await #expect(throws: BillEditError.noLines) {
            _ = try await store.postBill(
                emptyBillGuid,
                payableAccountGuid: bank.guid,
                postedDate: "2026-03-01",
                ids: ids
            )
        }

        let billGuid = try await store.createBillDraft(
            vendorGuid: vendorGuid,
            billNumber: "BILL-2",
            dateOpened: "2026-03-01",
            ids: ids
        )
        try await store.addBillLine(
            billGuid,
            date: "2026-03-01",
            description: "Rent",
            quantity: try Money(num: 1, denom: 1),
            unitPrice: try Money(num: 10000, denom: 100),
            expenseAccountGuid: rent.guid,
            ids: ids
        )
        _ = try await store.postBill(
            billGuid,
            payableAccountGuid: bank.guid,
            postedDate: "2026-03-01",
            ids: ids
        )

        await #expect(throws: BillEditError.alreadyPosted(billGuid)) {
            try await store.addBillLine(
                billGuid,
                date: "2026-03-02",
                description: "Extra",
                quantity: try Money(num: 1, denom: 1),
                unitPrice: try Money(num: 100, denom: 100),
                expenseAccountGuid: rent.guid,
                ids: ids
            )
        }
        await #expect(throws: BillEditError.alreadyPosted(billGuid)) {
            try await store.deleteBillDraft(billGuid)
        }

        await store.close()
    }

    @Test("refuses to delete a vendor with bills, but allows it once they're gone")
    func vendorInUse() async throws {
        let url = try billingBook()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try BookStore(url: url)
        let ids = SeededIDGenerator(start: 8000)
        let vendorGuid = try await store.createVendor(VendorDraft(name: "Acme"), ids: ids)
        let billGuid = try await store.createBillDraft(
            vendorGuid: vendorGuid,
            billNumber: "BILL-1",
            dateOpened: "2026-03-01",
            ids: ids
        )

        await #expect(throws: VendorEditError.vendorInUse) {
            try await store.deleteVendor(vendorGuid)
        }

        try await store.deleteBillDraft(billGuid)
        try await store.deleteVendor(vendorGuid)
        #expect(try await store.vendor(vendorGuid) == nil)

        await store.close()
    }
}
