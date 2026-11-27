// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Register export (QIF/CSV)")
struct RegisterExportTests {
    @Test("builds one row per split in the target account, categorising a simple transfer by the other account")
    func rows() throws {
        let bank = Guid(String(repeating: "1", count: 32))!
        let salary = Guid(String(repeating: "2", count: 32))!
        let rent = Guid(String(repeating: "3", count: 32))!
        let tax = Guid(String(repeating: "4", count: 32))!
        let names = [bank: "Checking", salary: "Salary", rent: "Rent", tax: "Tax"]

        let simple = StoredTransaction(
            guid: Guid(String(repeating: "a", count: 32))!,
            date: "2026-02-01",
            description: "Paycheck",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: 250_000, denom: 100), memo: "direct deposit"),
                StoredSplit(accountGuid: salary, value: try Money(num: -250_000, denom: 100)),
            ]
        )
        let split = StoredTransaction(
            guid: Guid(String(repeating: "b", count: 32))!,
            date: "2026-02-02",
            description: "Rent + tax",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: -11_000, denom: 100)),
                StoredSplit(accountGuid: rent, value: try Money(num: 10_000, denom: 100)),
                StoredSplit(accountGuid: tax, value: try Money(num: 1_000, denom: 100)),
            ]
        )
        let elsewhere = StoredTransaction(
            guid: Guid(String(repeating: "c", count: 32))!,
            date: "2026-02-03",
            description: "Not mine",
            splits: [
                StoredSplit(accountGuid: salary, value: try Money(num: 100, denom: 100)),
                StoredSplit(accountGuid: rent, value: try Money(num: -100, denom: 100)),
            ]
        )

        let rows = registerExportRows(
            transactions: [elsewhere, split, simple],
            accountNames: names,
            accountGuid: bank
        )

        #expect(rows.count == 2)
        #expect(rows[0].date == "2026-02-01")
        #expect(rows[0].payee == "Paycheck")
        #expect(rows[0].memo == "direct deposit")
        #expect(rows[0].category == "Salary")
        #expect(rows[0].amount == (try Money(num: 250_000, denom: 100)))

        #expect(rows[1].date == "2026-02-02")
        #expect(rows[1].category == "Split Transaction")
    }

    @Test("serializes QIF and CSV in the same format the web track reads and writes")
    func serialization() throws {
        let bank = Guid(String(repeating: "1", count: 32))!
        let rows = [
            RegisterExportRow(
                date: "2026-02-01",
                amount: try Money(num: -500, denom: 100),
                payee: "Coffee shop",
                memo: "beans",
                category: "Dining"
            ),
            RegisterExportRow(
                date: "2026-02-02",
                amount: try Money(num: 1_000, denom: 100),
                payee: "Refund, with a comma",
                memo: "",
                category: ""
            ),
        ]
        _ = bank

        let qif = try serializeQif(rows)
        #expect(
            qif == """
            !Type:Bank
            D2026-02-01
            T-5.00
            PCoffee shop
            Mbeans
            LDining
            ^
            D2026-02-02
            T10.00
            PRefund, with a comma
            ^

            """
        )

        let csv = try serializeCsv(rows)
        #expect(
            csv == """
            Date,Description,Memo,Amount,Category
            2026-02-01,Coffee shop,beans,-5.00,Dining
            2026-02-02,"Refund, with a comma",,10.00,

            """
        )
    }

    @Test("sanitizes an account name into a safe, non-empty filename stem")
    func filename() {
        #expect(registerExportFilename(accountName: "Checking", extension: "qif") == "Checking.qif")
        #expect(registerExportFilename(accountName: "Accounts Payable", extension: "csv") == "Accounts-Payable.csv")
        #expect(registerExportFilename(accountName: "  ", extension: "qif") == "account.qif")
        #expect(registerExportFilename(accountName: "A/R (USD)", extension: "csv") == "A-R-USD.csv")
    }
}
