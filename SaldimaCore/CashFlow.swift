// SPDX-License-Identifier: AGPL-3.0-only

/// One category's net cash movement within a cash flow statement.
public struct CashFlowLine: Sendable, Hashable, Identifiable {
    public let category: String
    /// Positive for an inflow line, negative for an outflow line.
    public let amount: Money
    public var id: String { category }

    public init(category: String, amount: Money) {
        self.category = category
        self.amount = amount
    }
}

/// Cash movement over a period, broken into inflows and outflows by the
/// other account each transaction touched -- the same "category" register
/// exports already use for a simple two-split transaction. Scoped
/// deliberately simple: this is a period cash-movement report, not a full
/// indirect-method statement with operating/investing/financing
/// classification.
public struct CashFlowStatement: Sendable, Hashable {
    public let inflows: [CashFlowLine]
    public let outflows: [CashFlowLine]
    public let netCashFlow: Money

    public init(inflows: [CashFlowLine], outflows: [CashFlowLine], netCashFlow: Money) {
        self.inflows = inflows
        self.outflows = outflows
        self.netCashFlow = netCashFlow
    }
}

/// Builds a cash flow statement for `from...to` (either bound `nil` means
/// unbounded on that side). `cashAccountGuids` identifies which accounts
/// count as "cash" (typically every `BANK`/`CASH` account). A transaction
/// only contributes if it touches both a cash and a non-cash account --
/// a transfer between two cash accounts is excluded, since it doesn't
/// change the entity's total cash position.
public func cashFlowStatement(
    transactions: [StoredTransaction],
    cashAccountGuids: Set<Guid>,
    accountNames: [Guid: String],
    from: String?,
    to: String?
) -> CashFlowStatement {
    var categoryTotals: [String: Money] = [:]
    var categoryOrder: [String] = []

    for transaction in transactions {
        let day = String(transaction.date.prefix(10))
        if let from, day < from { continue }
        if let to, day > to { continue }

        let cashSplits = transaction.splits.filter { cashAccountGuids.contains($0.accountGuid) }
        let nonCashSplits = transaction.splits.filter { !cashAccountGuids.contains($0.accountGuid) }
        guard !cashSplits.isEmpty, !nonCashSplits.isEmpty else { continue }

        let cashTotal = cashSplits.reduce(Money.zero) { sum, split in
            (try? Money.add(sum, split.value)) ?? sum
        }
        let category: String
        if nonCashSplits.count == 1, let only = nonCashSplits.first {
            category = accountNames[only.accountGuid] ?? "Other"
        } else {
            category = "Split transaction"
        }
        if categoryTotals[category] == nil { categoryOrder.append(category) }
        let running = categoryTotals[category] ?? .zero
        categoryTotals[category] = (try? Money.add(running, cashTotal)) ?? running
    }

    var inflows: [CashFlowLine] = []
    var outflows: [CashFlowLine] = []
    var net = Money.zero
    for category in categoryOrder {
        guard let amount = categoryTotals[category] else { continue }
        net = (try? Money.add(net, amount)) ?? net
        if amount.num > 0 {
            inflows.append(CashFlowLine(category: category, amount: amount))
        } else if amount.num < 0 {
            outflows.append(CashFlowLine(category: category, amount: amount))
        }
    }
    inflows.sort { $0.category < $1.category }
    outflows.sort { $0.category < $1.category }
    return CashFlowStatement(inflows: inflows, outflows: outflows, netCashFlow: net)
}
