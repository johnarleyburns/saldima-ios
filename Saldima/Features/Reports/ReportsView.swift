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

struct ReportsView: View {
    let session: BookSession

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
            List {
                if !session.isOpen || session.accounts.isEmpty {
                    ContentUnavailableView(
                        "No book open",
                        systemImage: "chart.bar",
                        description: Text("Open a book to see its reports.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Period") {
                        DatePicker(
                            "Balance sheet & trial balance, as of",
                            selection: $asOf,
                            displayedComponents: .date
                        )
                        Picker("Profit & loss", selection: $preset) {
                            ForEach(ReportPeriodPreset.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        if preset == .custom {
                            DatePicker("From", selection: $customFrom, displayedComponents: .date)
                            DatePicker("To", selection: $customTo, displayedComponents: .date)
                        }
                    }
                    Section("Trial balance") {
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
                        LabeledContent("Debits", value: session.formatted(asOfTotals.debits))
                        LabeledContent("Credits", value: session.formatted(asOfTotals.credits))
                        LabeledContent(
                            "Status",
                            value: asOfTotals.debits == asOfTotals.credits ? "Balanced" : "Out of balance"
                        )
                    }
                    Section("Balance sheet") {
                        LabeledContent("Assets", value: session.formatted(asOfTotals.assets))
                        LabeledContent("Liabilities", value: session.formatted(asOfTotals.liabilities))
                        LabeledContent(
                            "Equity",
                            value: session.formatted(
                                try! Money.add(asOfTotals.equity, asOfTotals.retained)
                            )
                        )
                    }
                    Section("Profit & loss") {
                        LabeledContent("Revenue", value: session.formatted(periodTotals.revenue))
                        LabeledContent("Expenses", value: session.formatted(periodTotals.expenses))
                        LabeledContent("Net income", value: session.formatted(periodTotals.profit))
                    }
                }
            }
            .navigationTitle("Reports")
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
