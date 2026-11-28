// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ money: Money) throws -> String {
    try money.formatted(fraction: 100)
}

private let target = Guid(String(repeating: "1", count: 32))!
private let unclassified = Guid(String(repeating: "2", count: 32))!
private let groceries = Guid(String(repeating: "3", count: 32))!
private let salary = Guid(String(repeating: "4", count: 32))!
private let household = Guid(String(repeating: "5", count: 32))!
private let savings = Guid(String(repeating: "6", count: 32))!

private let mapping = ImportMapping(
    targetAccountGuid: target,
    defaultAccountGuid: unclassified,
    categoryAccounts: [
        "Food:Groceries": groceries,
        "Salary": salary,
        "Household": household,
    ]
)

@Suite("Planning double-entry rows")
struct ImportPlanTests {
    @Test("posts a two-split transaction")
    func twoSplitTransaction() throws {
        let planned = try planImport(
            [
                ImportRow(
                    date: "2024-01-15",
                    amount: try Money(num: -4567, denom: 100),
                    payee: "Grocery Mart",
                    reference: "1001",
                    category: "Food:Groceries"
                ),
            ],
            mapping: mapping
        )
        let only = try #require(planned.first)
        #expect(only.description == "Grocery Mart")
        #expect(only.splits.map(\.accountGuid) == [target, groceries])
        #expect(try only.splits.map { try cents($0.value) } == ["-45.67", "45.67"])
    }

    @Test("keeps QIF splits and balances any remainder to the default account")
    func keepsSplitsAndBalancesRemainder() throws {
        let planned = try planImport(
            [
                ImportRow(
                    date: "2024-03-01",
                    amount: try Money(num: -6000, denom: 100),
                    payee: "Store",
                    splits: [
                        ImportSplit(category: "Food:Groceries", amount: try Money(num: -4000, denom: 100)),
                        ImportSplit(category: "Household", amount: try Money(num: -1900, denom: 100)),
                    ]
                ),
            ],
            mapping: mapping
        )
        let only = try #require(planned.first)
        #expect(only.splits.map(\.accountGuid) == [target, groceries, household, unclassified])
        #expect(try only.splits.map { try cents($0.value) } == ["-60.00", "40.00", "19.00", "1.00"])
    }

    @Test("falls back to the default account for unknown categories")
    func fallsBackToDefaultAccount() throws {
        let planned = try planImport(
            [
                ImportRow(
                    date: "2024-01-01",
                    amount: try Money(num: 150_000, denom: 100),
                    payee: "Employer",
                    memo: "Payroll",
                    category: "Unknown"
                ),
            ],
            mapping: mapping
        )
        let only = try #require(planned.first)
        #expect(only.description == "Employer — Payroll")
        #expect(only.splits.map(\.accountGuid) == [target, unclassified])
    }

    @Test("normalises transfer categories and default descriptions")
    func normalisesTransferCategories() throws {
        let transferMapping = ImportMapping(
            targetAccountGuid: target,
            defaultAccountGuid: unclassified,
            categoryAccounts: ["Savings": savings]
        )
        let planned = try planImport(
            [
                ImportRow(date: "2024-01-01", amount: try Money(num: -1000, denom: 100), category: "[Savings]"),
            ],
            mapping: transferMapping
        )
        let only = try #require(planned.first)
        #expect(only.description == "Imported transaction")
        #expect(only.splits.map(\.accountGuid) == [target, savings])
    }

    @Test("does not add a balancing split when QIF splits already balance")
    func noBalancingSplitWhenAlreadyBalanced() throws {
        let planned = try planImport(
            [
                ImportRow(
                    date: "2024-01-01",
                    amount: try Money(num: -1000, denom: 100),
                    payee: "Shop",
                    splits: [ImportSplit(category: "Food:Groceries", amount: try Money(num: -1000, denom: 100))]
                ),
            ],
            mapping: mapping
        )
        let only = try #require(planned.first)
        #expect(only.splits.count == 2)
    }

    @Test("categoryKey strips QIF transfer bracket syntax")
    func categoryKeyStripsBrackets() {
        #expect(categoryKey("[Savings]") == "Savings")
        #expect(categoryKey("  [ Savings ]  ") == "Savings")
        #expect(categoryKey("Food:Groceries") == "Food:Groceries")
    }
}
