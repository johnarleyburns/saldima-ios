// SPDX-License-Identifier: AGPL-3.0-only
import Testing

@testable import SaldimaCore

private func g(_ digit: String) -> Guid {
    Guid(String(repeating: digit, count: 32))!
}

private let bank = g("1")
private let card = g("2")
private let opening = g("3")
private let sales = g("4")
private let rent = g("5")

private func m(_ num: Int64, _ denom: Int64 = 1) -> Money {
    try! Money(num: num, denom: denom)
}

private let accounts = [
    LedgerAccount(id: bank, name: "Bank", type: .bank),
    LedgerAccount(id: card, name: "Card", type: .credit),
    LedgerAccount(id: opening, name: "Opening Balances", type: .equity),
    LedgerAccount(id: sales, name: "Sales", type: .income),
    LedgerAccount(id: rent, name: "Rent", type: .expense),
]

private func transaction(
    _ id: String,
    _ date: String,
    _ splits: [(Guid, Int64)]
) -> LedgerTransaction {
    LedgerTransaction(
        id: g(id),
        date: date,
        description: "test",
        splits: splits.map { LedgerSplit(accountId: $0.0, value: try! Money(num: $0.1, denom: 100)) }
    )
}

private func openingLedger() throws -> Ledger {
    var ledger = try LedgerEngine.create(accounts: accounts)
    ledger = try LedgerEngine.post(
        ledger,
        transaction("a", "2025-01-01", [(bank, 100_000), (card, -20_000), (opening, -80_000)])
    )
    return ledger
}

@Suite("Ledger verification scenarios")
struct LedgerTests {
    @Test("opening balances balance the trial balance and balance sheet")
    func openingBalances() throws {
        let ledger = try openingLedger()
        #expect(try LedgerEngine.accountBalance(ledger, bank) == m(1_000))
        let trial = try LedgerEngine.trialBalance(ledger)
        #expect(trial.balanced)
        #expect(trial.totalDebits == m(1_000))
        #expect(trial.totalCredits == m(1_000))

        let sheet = try LedgerEngine.balanceSheet(ledger, asOf: "2025-12-31")
        #expect(sheet.assets == m(1_000))
        #expect(sheet.liabilities == m(200))
        #expect(sheet.equity == m(800))
        #expect(sheet.retainedEarnings == .zero)
        #expect(sheet.balanced)
    }

    @Test("sale and expense flow through retained earnings and P&L")
    func saleAndExpense() throws {
        var ledger = try openingLedger()
        ledger = try LedgerEngine.post(
            ledger,
            transaction("b", "2025-02-01", [(bank, 20_000), (sales, -20_000)])
        )
        ledger = try LedgerEngine.post(
            ledger,
            transaction("c", "2025-02-02", [(rent, 5_000), (bank, -5_000)])
        )
        let trial = try LedgerEngine.trialBalance(ledger)
        #expect(trial.balanced)
        #expect(trial.totalDebits == m(1_200))

        let sheet = try LedgerEngine.balanceSheet(ledger, asOf: "2025-12-31")
        #expect(sheet.assets == m(1_150))
        #expect(sheet.retainedEarnings == m(150))
        #expect(sheet.balanced)

        let pnl = try LedgerEngine.incomeStatement(ledger, from: "2025-01-01", to: "2025-12-31")
        #expect(pnl.revenue == m(200))
        #expect(pnl.expenses == m(50))
        #expect(pnl.netIncome == m(150))
    }

    @Test("posting normalises half-up and rejects invalid journals")
    func postingRules() throws {
        let base = try LedgerEngine.create(accounts: accounts)
        #expect(throws: LedgerError.unbalanced) {
            _ = try LedgerEngine.post(
                base,
                LedgerTransaction(id: g("f"), date: "2025-01-01", description: "bad", splits: [
                    LedgerSplit(accountId: bank, value: try! Money(num: 100, denom: 100)),
                    LedgerSplit(accountId: opening, value: try! Money(num: -99, denom: 100)),
                ])
            )
        }
        let ledger = try LedgerEngine.post(
            base,
            LedgerTransaction(id: g("e"), date: "2025-01-01", description: "half-up", fraction: 100, splits: [
                LedgerSplit(accountId: bank, value: try! Money(num: 2665, denom: 1000)),
                LedgerSplit(accountId: opening, value: try! Money(num: -2665, denom: 1000)),
            ])
        )
        #expect(ledger.transactions[0].splits[0].value == m(267, 100))
        #expect(try Money.parseHalfUp("2.665", fraction: 100) == m(267, 100))
    }
}
