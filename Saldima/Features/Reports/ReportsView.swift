// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI

import SaldimaCore

/// Desktop GnuCash's own report option: a balance sheet and trial balance
/// are always a snapshot "as of" one date; a profit & loss statement is
/// always a range of activity, never a single-date snapshot.
private enum ReportPeriodPreset: String, CaseIterable, Identifiable {
    case allTime = "All time"
    case thisMonth = "This month"
    case thisQuarter = "This quarter"
    case thisYear = "This year"
    case custom = "Custom"

    var id: String { rawValue }
}

private enum StatementKind: String, CaseIterable, Identifiable {
    case balanceSheet = "Balance Sheet"
    case incomeStatement = "Income Statement"
    case cashFlow = "Cash Flow"
    case trialBalance = "Trial Balance"

    var id: String { rawValue }
}

/// One line of a printed financial statement: a label and a right-aligned,
/// monospaced amount, with an indent level and an optional top rule and
/// bold weight for subtotals/grand totals.
private struct StatementLine: View {
    let label: String
    let amount: String
    var indent: CGFloat = 0
    var emphasized = false
    var topRule = false

    var body: some View {
        VStack(spacing: 4) {
            if topRule {
                Divider()
            }
            HStack {
                Text(label)
                    .padding(.leading, indent)
                    .fontWeight(emphasized ? .semibold : .regular)
                Spacer()
                Text(amount)
                    .font(.callout.monospacedDigit())
                    .fontWeight(emphasized ? .semibold : .regular)
            }
        }
    }
}

private struct StatementSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }
}

/// The title block every printed financial statement opens with: the book
/// name, the statement's own title, and either "As of <date>" or "For the
/// period <from> to <to>".
private struct StatementHeader: View {
    let bookName: String
    let title: String
    let periodLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bookName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(periodLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReportsView: View {
    let session: BookSession

    @State private var kind: StatementKind = .balanceSheet
    @State private var asOf = Date()
    @State private var preset: ReportPeriodPreset = .allTime
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private struct Row: Identifiable {
        let name: String
        let value: Money
        let type: String
        var id: String { name + type }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !session.isOpen || session.accounts.isEmpty {
                    ContentUnavailableView(
                        "No book open",
                        systemImage: "chart.bar",
                        description: Text("Open a book to see its reports.")
                    )
                } else {
                    List {
                        Section("Statement") {
                            Picker("Statement", selection: $kind) {
                                ForEach(StatementKind.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        Section("Period") {
                            if kind == .balanceSheet || kind == .trialBalance {
                                DatePicker("As of", selection: $asOf, displayedComponents: .date)
                            } else {
                                Picker("Range", selection: $preset) {
                                    ForEach(ReportPeriodPreset.allCases) { option in
                                        Text(option.rawValue).tag(option)
                                    }
                                }
                                if preset == .custom {
                                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                                }
                            }
                        }
                        Section {
                            statement
                        }
                    }
                }
            }
            .navigationTitle("Reports")
        }
    }

    @ViewBuilder
    private var statement: some View {
        switch kind {
        case .balanceSheet:
            balanceSheet
        case .incomeStatement:
            incomeStatement
        case .cashFlow:
            cashFlow
        case .trialBalance:
            trialBalance
        }
    }

    // MARK: - Balance sheet

    @ViewBuilder
    private var balanceSheet: some View {
        let balances = asOfBalances
        let assets = sectionLines(types: ["ASSET", "BANK", "CASH", "RECEIVABLE"], balances: balances)
        let liabilities = sectionLines(types: ["LIABILITY", "CREDIT", "PAYABLE"], balances: balances, negate: true)
        let equity = sectionLines(types: ["EQUITY"], balances: balances, negate: true)
        let totals = asOfTotals
        let retainedEarnings = (try? Money.add(totals.equity, totals.retained)) ?? totals.equity
        let totalLiabilitiesAndEquity = (try? Money.add(totals.liabilities, retainedEarnings)) ?? totals.liabilities

        StatementHeader(
            bookName: session.bookName,
            title: "Balance Sheet",
            periodLine: "As of \(Self.isoDay(asOf))"
        )
        StatementSectionHeader(title: "Assets")
        ForEach(assets, id: \.name) { line in
            StatementLine(label: line.name, amount: session.formatted(line.amount), indent: 16)
        }
        StatementLine(label: "Total Assets", amount: session.formatted(totals.assets), emphasized: true, topRule: true)

        StatementSectionHeader(title: "Liabilities")
        ForEach(liabilities, id: \.name) { line in
            StatementLine(label: line.name, amount: session.formatted(line.amount), indent: 16)
        }
        StatementLine(label: "Total Liabilities", amount: session.formatted(totals.liabilities), emphasized: true, topRule: true)

        StatementSectionHeader(title: "Equity")
        ForEach(equity, id: \.name) { line in
            StatementLine(label: line.name, amount: session.formatted(line.amount), indent: 16)
        }
        StatementLine(label: "Retained Earnings", amount: session.formatted(totals.retained), indent: 16)
        StatementLine(label: "Total Equity", amount: session.formatted(retainedEarnings), emphasized: true, topRule: true)

        StatementLine(
            label: "Total Liabilities & Equity",
            amount: session.formatted(totalLiabilitiesAndEquity),
            emphasized: true,
            topRule: true
        )
    }

    // MARK: - Income statement

    @ViewBuilder
    private var incomeStatement: some View {
        let balances = periodBalances
        let revenue = sectionLines(types: ["INCOME"], balances: balances, negate: true)
        let expenses = sectionLines(types: ["EXPENSE"], balances: balances)
        let totals = periodTotals

        StatementHeader(
            bookName: session.bookName,
            title: "Income Statement",
            periodLine: periodLine
        )
        StatementSectionHeader(title: "Revenue")
        ForEach(revenue, id: \.name) { line in
            StatementLine(label: line.name, amount: session.formatted(line.amount), indent: 16)
        }
        StatementLine(label: "Total Revenue", amount: session.formatted(totals.revenue), emphasized: true, topRule: true)

        StatementSectionHeader(title: "Expenses")
        ForEach(expenses, id: \.name) { line in
            StatementLine(label: line.name, amount: session.formatted(line.amount), indent: 16)
        }
        StatementLine(label: "Total Expenses", amount: session.formatted(totals.expenses), emphasized: true, topRule: true)

        StatementLine(label: "Net Income", amount: session.formatted(totals.profit), emphasized: true, topRule: true)
    }

    // MARK: - Cash flow

    @ViewBuilder
    private var cashFlow: some View {
        let cashGuids = Set(flat.filter { $0.accountType == "BANK" || $0.accountType == "CASH" }.map(\.guid))
        let names = Dictionary(uniqueKeysWithValues: flat.map { ($0.guid, $0.name) })
        let range = periodRange
        let statement = cashFlowStatement(
            transactions: session.transactions,
            cashAccountGuids: cashGuids,
            accountNames: names,
            from: range.from,
            to: range.to
        )
        // No lower bound means "since the book began" -- by definition the
        // cash accounts started at zero, so there is no real prior balance
        // to look up.
        let beginningCash = range.from.map {
            cashTotal(in: balances(to: Self.dayBefore($0)), accounts: cashGuids)
        } ?? Money.zero
        let endingCash = cashTotal(in: balances(to: range.to), accounts: cashGuids)

        StatementHeader(
            bookName: session.bookName,
            title: "Statement of Cash Flows",
            periodLine: periodLine
        )
        StatementLine(label: "Cash at beginning of period", amount: session.formatted(beginningCash))

        StatementSectionHeader(title: "Cash inflows")
        if statement.inflows.isEmpty {
            StatementLine(label: "None", amount: "", indent: 16)
        }
        ForEach(statement.inflows) { line in
            StatementLine(label: line.category, amount: session.formatted(line.amount), indent: 16)
        }

        StatementSectionHeader(title: "Cash outflows")
        if statement.outflows.isEmpty {
            StatementLine(label: "None", amount: "", indent: 16)
        }
        ForEach(statement.outflows) { line in
            StatementLine(label: line.category, amount: session.formatted(line.amount), indent: 16)
        }

        StatementLine(
            label: "Net Change in Cash",
            amount: session.formatted(statement.netCashFlow),
            emphasized: true,
            topRule: true
        )
        StatementLine(label: "Cash at end of period", amount: session.formatted(endingCash), emphasized: true)
    }

    // MARK: - Trial balance

    @ViewBuilder
    private var trialBalance: some View {
        StatementHeader(
            bookName: session.bookName,
            title: "Trial Balance",
            periodLine: "As of \(Self.isoDay(asOf))"
        )
        ForEach(rows) { row in
            HStack {
                Text(row.name)
                Text(row.type.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accountColor(row.type).opacity(0.16), in: Capsule())
                    .foregroundStyle(accountColor(row.type))
                Spacer()
                Text(session.formatted(row.value))
                    .font(.callout.monospacedDigit())
            }
        }
        StatementLine(label: "Total Debits", amount: session.formatted(asOfTotals.debits), topRule: true)
        StatementLine(label: "Total Credits", amount: session.formatted(asOfTotals.credits))
        StatementLine(
            label: "Status",
            amount: asOfTotals.debits == asOfTotals.credits ? "Balanced" : "Out of balance",
            emphasized: true
        )
    }

    // MARK: - Shared helpers

    private var periodLine: String {
        let range = periodRange
        switch (range.from, range.to) {
        case (nil, nil):
            return "All time"
        case (let from?, let to?):
            return "For the period \(from) to \(to)"
        case (let from?, nil):
            return "Since \(from)"
        case (nil, let to?):
            return "Through \(to)"
        }
    }

    private func sectionLines(
        types: Set<String>,
        balances: [Guid: Money],
        negate: Bool = false
    ) -> [(name: String, amount: Money)] {
        flat
            .filter { types.contains($0.accountType) }
            .compactMap { account -> (name: String, amount: Money)? in
                guard let balance = balances[account.guid], balance != .zero else { return nil }
                return (account.name, negate ? balance.negated() : balance)
            }
            .sorted { $0.name < $1.name }
    }

    private func cashTotal(in balances: [Guid: Money], accounts: Set<Guid>) -> Money {
        accounts.reduce(Money.zero) { sum, guid in
            guard let balance = balances[guid] else { return sum }
            return (try? Money.add(sum, balance)) ?? sum
        }
    }

    private var flat: [Account] {
        func walk(_ nodes: [Account]) -> [Account] {
            nodes.flatMap { [$0] + walk($0.children) }
        }
        return walk(session.accounts)
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// One calendar day before an ISO day string -- used for "cash at the
    /// start of the period" (the balance up to, but not including, `from`).
    private static func dayBefore(_ isoDay: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: isoDay),
              let previous = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date)
        else {
            return isoDay
        }
        return Self.isoDay(previous)
    }

    /// Balances from every split whose transaction date falls within
    /// `from...to` (either bound omitted means unbounded on that side).
    private func balances(from: String? = nil, to: String? = nil) -> [Guid: Money] {
        var totals: [Guid: Money] = [:]
        for transaction in session.transactions {
            let day = String(transaction.date.prefix(10))
            if let from, day < from { continue }
            if let to, day > to { continue }
            for split in transaction.splits {
                let running = totals[split.accountGuid] ?? .zero
                totals[split.accountGuid] = (try? Money.add(running, split.value)) ?? running
            }
        }
        return totals
    }

    private var asOfBalances: [Guid: Money] {
        balances(to: Self.isoDay(asOf))
    }

    /// `nil` for `.allTime` and `.custom` means "unbounded" on that side,
    /// the same convention `balances(from:to:)` uses.
    private var periodRange: (from: String?, to: String?) {
        let calendar = Calendar(identifier: .gregorian)
        switch preset {
        case .allTime:
            return (nil, nil)
        case .custom:
            return (Self.isoDay(customFrom), Self.isoDay(customTo))
        case .thisMonth:
            guard let interval = calendar.dateInterval(of: .month, for: Date()) else { return (nil, nil) }
            return (Self.isoDay(interval.start), Self.isoDay(interval.end.addingTimeInterval(-1)))
        case .thisQuarter:
            let today = Date()
            let month = calendar.component(.month, from: today)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: today)
            components.month = quarterStartMonth
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: DateComponents(month: 3, day: -1), to: start)
            else {
                return (nil, nil)
            }
            return (Self.isoDay(start), Self.isoDay(end))
        case .thisYear:
            guard let interval = calendar.dateInterval(of: .year, for: Date()) else { return (nil, nil) }
            return (Self.isoDay(interval.start), Self.isoDay(interval.end.addingTimeInterval(-1)))
        }
    }

    private var periodBalances: [Guid: Money] {
        let range = periodRange
        return balances(from: range.from, to: range.to)
    }

    private var rows: [Row] {
        flat.compactMap { account in
            guard let balance = asOfBalances[account.guid], balance != .zero else { return nil }
            return Row(name: account.name, value: balance, type: account.accountType)
        }
    }

    private struct Totals {
        var debits = Money.zero
        var credits = Money.zero
        var assets = Money.zero
        var liabilities = Money.zero
        var equity = Money.zero
        var revenue = Money.zero
        var expenses = Money.zero
        var retained = Money.zero
        var profit = Money.zero
    }

    private func totals(from balances: [Guid: Money]) -> Totals {
        var result = Totals()
        for account in flat {
            let balance = balances[account.guid] ?? .zero
            switch account.accountType {
            case "ASSET", "BANK", "CASH", "RECEIVABLE":
                result.assets = (try? Money.add(result.assets, balance)) ?? result.assets
            case "LIABILITY", "CREDIT", "PAYABLE":
                result.liabilities = (try? Money.add(result.liabilities, balance)) ?? result.liabilities
            case "EQUITY":
                result.equity = (try? Money.add(result.equity, balance)) ?? result.equity
            case "INCOME":
                result.revenue = (try? Money.add(result.revenue, balance.negated())) ?? result.revenue
            case "EXPENSE":
                result.expenses = (try? Money.add(result.expenses, balance)) ?? result.expenses
            default:
                break
            }
            if balance.num > 0 {
                result.debits = (try? Money.add(result.debits, balance)) ?? result.debits
            } else if balance.num < 0 {
                result.credits = (try? Money.add(result.credits, balance.negated())) ?? result.credits
            }
        }
        result.liabilities = result.liabilities.negated()
        result.equity = result.equity.negated()
        result.retained = (try? Money.add(result.revenue, result.expenses).negated()) ?? .zero
        result.profit = result.retained
        return result
    }

    private var asOfTotals: Totals { totals(from: asOfBalances) }
    private var periodTotals: Totals { totals(from: periodBalances) }
}

#Preview {
    ReportsView(session: BookSession())
}
