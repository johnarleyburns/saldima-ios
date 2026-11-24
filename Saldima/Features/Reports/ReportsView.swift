// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

struct ReportsView: View {
    let session: BookSession

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
                        LabeledContent("Debits", value: session.formatted(totals.debits))
                        LabeledContent("Credits", value: session.formatted(totals.credits))
                        LabeledContent(
                            "Status",
                            value: totals.debits == totals.credits ? "Balanced" : "Out of balance"
                        )
                    }
                    Section("Balance sheet") {
                        LabeledContent("Assets", value: session.formatted(totals.assets))
                        LabeledContent("Liabilities", value: session.formatted(totals.liabilities))
                        LabeledContent(
                            "Equity",
                            value: session.formatted(
                                try! Money.add(totals.equity, totals.retained)
                            )
                        )
                    }
                    Section("Profit & loss") {
                        LabeledContent("Revenue", value: session.formatted(totals.revenue))
                        LabeledContent("Expenses", value: session.formatted(totals.expenses))
                        LabeledContent("Net income", value: session.formatted(totals.profit))
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

    private var rows: [Row] {
        flat.compactMap { account in
            guard let balance = session.balances[account.guid], balance != .zero else { return nil }
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

    private var totals: Totals {
        var result = Totals()
        for account in flat {
            let balance = session.balances[account.guid] ?? .zero
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
}

#Preview {
    ReportsView(session: BookSession())
}
