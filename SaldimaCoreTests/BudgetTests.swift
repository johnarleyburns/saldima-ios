// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
@testable import SaldimaTestKit

private func budgetBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("budget-\(UUID().uuidString).gnucash")
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

/// `BookStore`-level tests for desktop GnuCash's "Budgets", mirroring the
/// web engine's locked design (`johnarleyburns/saldima#102`/#103): a
/// recurrence plus a period count, immutable after creation (same
/// convention as scheduled transactions); per-account-per-period amounts;
/// and a live, never-stored "actual".
@Suite("Budgets")
struct BudgetTests {
    private func openBook() async throws -> (store: BookStore, checking: Guid, salary: Guid) {
        let url = try budgetBook()
        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let checking = try #require(account(named: "Checking", in: roots)).guid
        let salary = try #require(account(named: "Salary", in: roots)).guid
        return (store, checking, salary)
    }

    private func draft(
        name: String = "2026 household",
        description: String = "Household budget for 2026",
        periodCount: Int = 12,
        start: String = "2026-01-01",
        recurrence: Recurrence? = nil
    ) -> BudgetDraft {
        BudgetDraft(
            name: name,
            description: description,
            periodCount: periodCount,
            recurrence: recurrence ?? Recurrence(periodType: .month, start: start)
        )
    }

    @Test("creates a budget and reads it back")
    func createsAndReads() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(), ids: ids)

        let all = try await store.budgets()
        #expect(all.count == 1)
        #expect(all.first?.guid == guid)
        #expect(all.first?.name == "2026 household")
        #expect(all.first?.periodCount == 12)

        let one = try await store.budget(guid)
        #expect(one?.description == "Household budget for 2026")
        #expect(one?.recurrence == Recurrence(periodType: .month, start: "2026-01-01"))
    }

    @Test("supports multiple budgets per book")
    func supportsMultipleBudgets() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        try await store.createBudget(draft(name: "2026 household"), ids: ids)
        try await store.createBudget(
            draft(name: "Vacation fund", periodCount: 4, recurrence: Recurrence(periodType: .endOfMonth, multiplier: 3, start: "2026-01-01")),
            ids: ids
        )
        let names = try await store.budgets().map(\.name).sorted()
        #expect(names == ["2026 household", "Vacation fund"])
    }

    @Test("rejects a blank name or fewer than one period")
    func rejectsInvalidDrafts() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)

        var blankName = draft()
        blankName.name = "  "
        await #expect(throws: BudgetError.invalidName) {
            try await store.createBudget(blankName, ids: ids)
        }

        var noPeriods = draft()
        noPeriods.periodCount = 0
        await #expect(throws: BudgetError.invalidPeriodCount) {
            try await store.createBudget(noPeriods, ids: ids)
        }
    }

    @Test("updates name, description and periodCount independently, and rejects an unknown budget")
    func updatesRestrictedFields() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(), ids: ids)

        try await store.updateBudget(guid, with: BudgetEditDraft(name: "Renamed", description: "Household budget for 2026", periodCount: 12))
        var updated = try await store.budget(guid)
        #expect(updated?.name == "Renamed")
        #expect(updated?.periodCount == 12)

        try await store.updateBudget(guid, with: BudgetEditDraft(name: "Renamed", description: "Household budget for 2026", periodCount: 6))
        updated = try await store.budget(guid)
        #expect(updated?.periodCount == 6)
        #expect(updated?.name == "Renamed")

        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: BudgetError.unknownBudget(unknown)) {
            try await store.updateBudget(unknown, with: BudgetEditDraft(name: "x", description: "", periodCount: 1))
        }

        await #expect(throws: BudgetError.invalidPeriodCount) {
            try await store.updateBudget(guid, with: BudgetEditDraft(name: "Renamed", description: "", periodCount: 0))
        }
    }

    @Test("deletes a budget, and rejects an unknown one")
    func deletes() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(), ids: ids)
        try await store.deleteBudget(guid)
        #expect(try await store.budgets().isEmpty)

        await #expect(throws: BudgetError.unknownBudget(guid)) {
            try await store.deleteBudget(guid)
        }
    }

    @Test("computes each period's [start, end) range from the recurrence")
    func computesPeriodRange() async throws {
        let (store, _, _) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(), ids: ids)

        var range = try await store.budgetPeriodRange(guid, periodIndex: 0)
        #expect(range.start == "2026-01-01")
        #expect(range.end == "2026-02-01")

        range = try await store.budgetPeriodRange(guid, periodIndex: 11)
        #expect(range.start == "2026-12-01")
        #expect(range.end == "2027-01-01")

        await #expect(throws: BudgetError.invalidPeriodIndex) {
            try await store.budgetPeriodRange(guid, periodIndex: -1)
        }
    }

    @Test("sets, reads back and removes a per-account-per-period amount, and computes a live, never-stored actual")
    func setsReadsAndComputesActual() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(), ids: ids)

        #expect(try await store.budgetAmount(guid, accountGuid: checking, periodIndex: 0) == nil)

        try await store.saveBudgetAmounts(guid, edits: [
            BookStore.BudgetAmountEdit(accountGuid: checking, periodIndex: 0, amount: try Money(num: 150_000, denom: 100)),
            BookStore.BudgetAmountEdit(accountGuid: salary, periodIndex: 0, amount: try Money(num: -250_000, denom: 100)),
        ])
        #expect(try await store.budgetAmount(guid, accountGuid: checking, periodIndex: 0) == (try Money(num: 150_000, denom: 100)))
        #expect(try await store.budgetAmount(guid, accountGuid: salary, periodIndex: 0) == (try Money(num: -250_000, denom: 100)))

        try await store.post(
            date: "2026-01-15",
            description: "January paycheck",
            splits: [
                StoredSplit(accountGuid: checking, value: try Money(num: 300_000, denom: 100)),
                StoredSplit(accountGuid: salary, value: try Money(num: -300_000, denom: 100)),
            ],
            ids: ids
        )
        #expect(try await store.budgetActual(guid, accountGuid: checking, periodIndex: 0) == (try Money(num: 3_000, denom: 1)))

        // Clearing an amount (never a zero placeholder) is one whole-grid save away too.
        try await store.saveBudgetAmounts(guid, edits: [
            BookStore.BudgetAmountEdit(accountGuid: checking, periodIndex: 0, amount: nil),
        ])
        #expect(try await store.budgetAmount(guid, accountGuid: checking, periodIndex: 0) == nil)
    }

    @Test("rejects reading or saving amounts against an unknown budget")
    func rejectsUnknownBudgetForAmounts() async throws {
        let (store, checking, _) = try await openBook()
        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: BudgetError.unknownBudget(unknown)) {
            try await store.saveBudgetAmounts(unknown, edits: [
                BookStore.BudgetAmountEdit(accountGuid: checking, periodIndex: 0, amount: try Money(num: 1, denom: 1)),
            ])
        }
        await #expect(throws: BudgetError.unknownBudget(unknown)) {
            try await store.budgetActual(unknown, accountGuid: checking, periodIndex: 0)
        }
    }

    @Test("builds a whole grid in one call: periods, budgeted amounts and live actuals per account")
    func buildsGrid() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createBudget(draft(periodCount: 2), ids: ids)
        try await store.saveBudgetAmounts(guid, edits: [
            BookStore.BudgetAmountEdit(accountGuid: checking, periodIndex: 0, amount: try Money(num: 100_000, denom: 100)),
        ])
        try await store.post(
            date: "2026-01-15",
            description: "January paycheck",
            splits: [
                StoredSplit(accountGuid: checking, value: try Money(num: 300_000, denom: 100)),
                StoredSplit(accountGuid: salary, value: try Money(num: -300_000, denom: 100)),
            ],
            ids: ids
        )

        let grid = try await store.budgetGrid(guid, accountGuids: [checking, salary])
        #expect(grid.periods.count == 2)
        #expect(grid.periods[0].start == "2026-01-01")
        let checkingRow = try #require(grid.rows.first { $0.accountGuid == checking })
        #expect(checkingRow.budgeted[0] == (try Money(num: 100_000, denom: 100)))
        #expect(checkingRow.budgeted[1] == nil)
        #expect(checkingRow.actual[0] == (try Money(num: 3_000, denom: 1)))
        let salaryRow = try #require(grid.rows.first { $0.accountGuid == salary })
        #expect(salaryRow.budgeted[0] == nil)
        #expect(salaryRow.actual[0] == (try Money(num: -3_000, denom: 1)))
    }
}
