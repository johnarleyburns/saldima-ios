// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Cash flow statement")
struct CashFlowTests {
    @Test("categorises cash movement by the other account, excludes cash-to-cash transfers, and nets to the right total")
    func statement() throws {
        let bank = Guid(String(repeating: "1", count: 32))!
        let savings = Guid(String(repeating: "2", count: 32))!
        let salary = Guid(String(repeating: "3", count: 32))!
        let rent = Guid(String(repeating: "4", count: 32))!
        let names = [bank: "Checking", savings: "Savings", salary: "Salary", rent: "Rent"]
        let cashAccounts: Set<Guid> = [bank, savings]

        let paycheck = StoredTransaction(
            guid: Guid(String(repeating: "a", count: 32))!,
            date: "2026-02-01",
            description: "Paycheck",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: 250_000, denom: 100)),
                StoredSplit(accountGuid: salary, value: try Money(num: -250_000, denom: 100)),
            ]
        )
        let rentPayment = StoredTransaction(
            guid: Guid(String(repeating: "b", count: 32))!,
            date: "2026-02-05",
            description: "Rent",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: -120_000, denom: 100)),
                StoredSplit(accountGuid: rent, value: try Money(num: 120_000, denom: 100)),
            ]
        )
        let transferToSavings = StoredTransaction(
            guid: Guid(String(repeating: "c", count: 32))!,
            date: "2026-02-10",
            description: "Move to savings",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: -50_000, denom: 100)),
                StoredSplit(accountGuid: savings, value: try Money(num: 50_000, denom: 100)),
            ]
        )
        let outOfRange = StoredTransaction(
            guid: Guid(String(repeating: "d", count: 32))!,
            date: "2026-03-15",
            description: "Next month",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: 10_000, denom: 100)),
                StoredSplit(accountGuid: salary, value: try Money(num: -10_000, denom: 100)),
            ]
        )

        let statement = cashFlowStatement(
            transactions: [paycheck, rentPayment, transferToSavings, outOfRange],
            cashAccountGuids: cashAccounts,
            accountNames: names,
            from: "2026-02-01",
            to: "2026-02-28"
        )

        // Money.add cross-multiplies denominators then reduces, so compare
        // against an equally-normalized expectation rather than the raw
        // (num: 250_000, denom: 100) form.
        #expect(
            statement.inflows == [CashFlowLine(category: "Salary", amount: try Money(num: 250_000, denom: 100).normalized())]
        )
        #expect(
            statement.outflows == [CashFlowLine(category: "Rent", amount: try Money(num: -120_000, denom: 100).normalized())]
        )
        #expect(statement.netCashFlow == (try Money(num: 130_000, denom: 100).normalized()))
    }

    @Test("groups a transaction with more than one non-cash split as \"Split transaction\"")
    func splitTransaction() throws {
        let bank = Guid(String(repeating: "1", count: 32))!
        let rent = Guid(String(repeating: "2", count: 32))!
        let tax = Guid(String(repeating: "3", count: 32))!
        let names = [bank: "Checking", rent: "Rent", tax: "Tax"]

        let transaction = StoredTransaction(
            guid: Guid(String(repeating: "a", count: 32))!,
            date: "2026-02-05",
            description: "Rent + tax",
            splits: [
                StoredSplit(accountGuid: bank, value: try Money(num: -110_00, denom: 100)),
                StoredSplit(accountGuid: rent, value: try Money(num: 100_00, denom: 100)),
                StoredSplit(accountGuid: tax, value: try Money(num: 10_00, denom: 100)),
            ]
        )

        let statement = cashFlowStatement(
            transactions: [transaction],
            cashAccountGuids: [bank],
            accountNames: names,
            from: nil,
            to: nil
        )

        #expect(statement.outflows.count == 1)
        #expect(statement.outflows.first?.category == "Split transaction")
    }
}
