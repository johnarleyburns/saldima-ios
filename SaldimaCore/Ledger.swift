// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum AccountType: String, Sendable, CaseIterable, Codable {
    case asset = "ASSET"
    case bank = "BANK"
    case cash = "CASH"
    case credit = "CREDIT"
    case liability = "LIABILITY"
    case income = "INCOME"
    case expense = "EXPENSE"
    case equity = "EQUITY"
    case receivable = "RECEIVABLE"
    case payable = "PAYABLE"
}

public struct LedgerAccount: Hashable, Sendable, Identifiable {
    public let id: Guid
    public let name: String
    public let type: AccountType
    public let parentId: Guid?

    public init(id: Guid, name: String, type: AccountType, parentId: Guid? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.parentId = parentId
    }
}

public struct LedgerSplit: Sendable, Hashable {
    public let accountId: Guid
    public let value: Money

    public init(accountId: Guid, value: Money) {
        self.accountId = accountId
        self.value = value
    }
}

public struct LedgerTransaction: Sendable, Hashable {
    public let id: Guid
    public let date: String
    public let description: String
    public let fraction: Int64
    public let splits: [LedgerSplit]

    public init(
        id: Guid,
        date: String,
        description: String,
        fraction: Int64 = 100,
        splits: [LedgerSplit]
    ) {
        self.id = id
        self.date = date
        self.description = description
        self.fraction = fraction
        self.splits = splits
    }
}

public struct Ledger: Sendable, Hashable {
    public let accounts: [LedgerAccount]
    public let transactions: [LedgerTransaction]

    public init(accounts: [LedgerAccount], transactions: [LedgerTransaction] = []) {
        self.accounts = accounts
        self.transactions = transactions
    }
}

public enum LedgerError: Error, Equatable, Sendable {
    case duplicateAccount(Guid)
    case duplicateTransaction(Guid)
    case unknownAccount(Guid)
    case invalidDate(String)
    case tooFewSplits
    case unbalanced
}

public struct TrialBalanceRow: Sendable, Hashable {
    public let accountId: Guid
    public let name: String
    public let type: AccountType
    public let debit: Money
    public let credit: Money
}

public struct TrialBalance: Sendable, Hashable {
    public let rows: [TrialBalanceRow]
    public let totalDebits: Money
    public let totalCredits: Money
    public var balanced: Bool { totalDebits == totalCredits }
}

public struct BalanceSheet: Sendable, Hashable {
    public let assets: Money
    public let liabilities: Money
    public let equity: Money
    public let retainedEarnings: Money
    public let totalLiabilitiesAndEquity: Money
    public var balanced: Bool { assets == totalLiabilitiesAndEquity }
}

public enum LedgerInvariantCode: String, Sendable, Hashable {
    case unbalancedTrialBalance = "UNBALANCED_TRIAL_BALANCE"
    case assetsNotEqualLiabilitiesPlusEquity = "ASSETS_NE_LIABILITIES_PLUS_EQUITY"
}

public struct LedgerInvariantFailure: Sendable, Hashable {
    public let code: LedgerInvariantCode
    public let message: String

    public init(code: LedgerInvariantCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct IncomeStatement: Sendable, Hashable {
    public let revenue: Money
    public let expenses: Money
    public let netIncome: Money
}

public enum LedgerEngine {
    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    public static func create(accounts: [LedgerAccount]) throws -> Ledger {
        var ids = Set<Guid>()
        for account in accounts {
            guard ids.insert(account.id).inserted else {
                throw LedgerError.duplicateAccount(account.id)
            }
        }
        return Ledger(accounts: accounts)
    }

    public static func post(_ ledger: Ledger, _ transaction: LedgerTransaction) throws -> Ledger {
        guard datePattern.firstMatch(
            in: transaction.date,
            range: NSRange(transaction.date.startIndex..., in: transaction.date)
        ) != nil else {
            throw LedgerError.invalidDate(transaction.date)
        }
        if ledger.transactions.contains(where: { $0.id == transaction.id }) {
            throw LedgerError.duplicateTransaction(transaction.id)
        }
        guard transaction.splits.count >= 2 else { throw LedgerError.tooFewSplits }
        let accounts = Set(ledger.accounts.map(\.id))
        var total = Money.zero
        var normalized: [LedgerSplit] = []
        for split in transaction.splits {
            guard accounts.contains(split.accountId) else {
                throw LedgerError.unknownAccount(split.accountId)
            }
            let value = try split.value.roundedHalfUp(toFraction: transaction.fraction)
            normalized.append(LedgerSplit(accountId: split.accountId, value: value))
            total = try Money.add(total, value)
        }
        guard total == Money.zero else { throw LedgerError.unbalanced }
        var transactions = ledger.transactions
        transactions.append(
            LedgerTransaction(
                id: transaction.id,
                date: transaction.date,
                description: transaction.description,
                fraction: transaction.fraction,
                splits: normalized
            )
        )
        return Ledger(accounts: ledger.accounts, transactions: transactions)
    }

    public static func accountBalance(_ ledger: Ledger, _ accountId: Guid, asOf: String? = nil) throws -> Money {
        var total = Money.zero
        for transaction in ledger.transactions {
            if let asOf, transaction.date > asOf { continue }
            for split in transaction.splits where split.accountId == accountId {
                total = try Money.add(total, split.value)
            }
        }
        return total
    }

    private static func sum(_ ledger: Ledger, types: Set<AccountType>, from: String? = nil, to: String? = nil) throws -> Money {
        let ids = Set(ledger.accounts.filter { types.contains($0.type) }.map(\.id))
        var total = Money.zero
        for transaction in ledger.transactions {
            if let from, transaction.date < from { continue }
            if let to, transaction.date > to { continue }
            for split in transaction.splits where ids.contains(split.accountId) {
                total = try Money.add(total, split.value)
            }
        }
        return total
    }

    public static func trialBalance(_ ledger: Ledger, asOf: String? = nil) throws -> TrialBalance {
        var rows: [TrialBalanceRow] = []
        var debits = Money.zero
        var credits = Money.zero
        for account in ledger.accounts {
            let balance = try accountBalance(ledger, account.id, asOf: asOf)
            if balance == Money.zero { continue }
            let debit = balance.num > 0 ? balance : Money.zero
            let credit = balance.num < 0 ? balance.negated() : Money.zero
            rows.append(TrialBalanceRow(accountId: account.id, name: account.name, type: account.type, debit: debit, credit: credit))
            debits = try Money.add(debits, debit)
            credits = try Money.add(credits, credit)
        }
        return TrialBalance(rows: rows, totalDebits: debits, totalCredits: credits)
    }

    public static func balanceSheet(_ ledger: Ledger, asOf: String) throws -> BalanceSheet {
        let assets = try sum(ledger, types: [.asset, .bank, .cash, .receivable], to: asOf)
        let liabilities = try sum(ledger, types: [.liability, .credit, .payable], to: asOf).negated()
        let equity = try sum(ledger, types: [.equity], to: asOf).negated()
        let income = try sum(ledger, types: [.income], to: asOf)
        let expense = try sum(ledger, types: [.expense], to: asOf)
        let retained = try Money.add(income, expense).negated()
        let total = try Money.add(try Money.add(liabilities, equity), retained)
        return BalanceSheet(assets: assets, liabilities: liabilities, equity: equity, retainedEarnings: retained, totalLiabilitiesAndEquity: total)
    }

    /// Checks a ledger that may have come from an import, not through `post`.
    /// Same codes and semantics as `verifyLedger` on the web track.
    public static func verify(_ ledger: Ledger, asOf: String) throws -> [LedgerInvariantFailure] {
        var failures: [LedgerInvariantFailure] = []
        if try !trialBalance(ledger, asOf: asOf).balanced {
            failures.append(
                LedgerInvariantFailure(
                    code: .unbalancedTrialBalance,
                    message: "trial balance debits do not equal credits"
                )
            )
        }
        if try !balanceSheet(ledger, asOf: asOf).balanced {
            failures.append(
                LedgerInvariantFailure(
                    code: .assetsNotEqualLiabilitiesPlusEquity,
                    message: "assets do not equal liabilities plus equity"
                )
            )
        }
        return failures
    }

    public static func incomeStatement(_ ledger: Ledger, from: String, to: String) throws -> IncomeStatement {
        let revenue = try sum(ledger, types: [.income], from: from, to: to).negated()
        let expenses = try sum(ledger, types: [.expense], from: from, to: to)
        return IncomeStatement(revenue: revenue, expenses: expenses, netIncome: try Money.subtract(revenue, expenses))
    }
}
