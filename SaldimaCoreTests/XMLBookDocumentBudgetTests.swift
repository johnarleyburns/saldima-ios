// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

private func loadFixtureData(_ name: String) throws -> Data {
    let raw = try Data(contentsOf: fixture(name))
    return raw.starts(with: [0x1f, 0x8b]) ? try Gzip.inflate(raw) : raw
}

/// Mirrors the web engine's locked `describe("budgets", ...)` suite in
/// `packages/gnucash/src/xml-document.test.ts` (`johnarleyburns/saldima#102`/#103)
/// byte-for-byte where the assertions are about the on-disk XML shape.
@Suite("XMLBookDocument budgets")
struct XMLBookDocumentBudgetTests {
    private func openFixture() throws -> (document: XMLBookDocument, bank: Guid, salary: Guid) {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bank = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let salary = try #require(document.accounts().first { $0.name == "Salary" }?.guid)
        return (document, bank, salary)
    }

    private func monthlyBudgetGuid(_ character: Character) throws -> Guid {
        try #require(Guid(String(repeating: character, count: 32)))
    }

    @discardableResult
    private func createMonthlyBudget(_ document: XMLBookDocument, guid: Guid) -> BudgetRow {
        document.createBudget(
            guid: guid,
            name: "2026 household",
            description: "Household budget for 2026",
            periodCount: 12,
            recurrence: Recurrence(periodType: .month, multiplier: 1, start: "2026-01-01")
        )
    }

    @Test("creates a budget matching real GnuCash's on-disk shape, and reads it back")
    func createsBudgetMatchingOnDiskShape() throws {
        let (document, _, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        #expect(budget.guid == guid)
        #expect(budget.name == "2026 household")
        #expect(budget.description == "Household budget for 2026")
        #expect(budget.periodCount == 12)
        #expect(budget.recurrence == Recurrence(periodType: .month, multiplier: 1, start: "2026-01-01"))

        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<gnc:budget version=\"2.0.0\">"))
        #expect(xml.contains("<bgt:id type=\"guid\">\(guid.rawValue)</bgt:id>"))
        #expect(xml.contains("<bgt:name>2026 household</bgt:name>"))
        #expect(xml.contains("<bgt:num-periods>12</bgt:num-periods>"))
        // No separate wrapper -- the version attribute and recurrence:* children
        // sit directly on <bgt:recurrence>, unlike sx:schedule's inner gnc:recurrence.
        #expect(xml.contains("<bgt:recurrence version=\"1.0.0\">"))
        #expect(xml.contains("<recurrence:period_type>month</recurrence:period_type>"))
        #expect(!xml.contains("<gnc:recurrence"))

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.budget(guid) == budget)
    }

    @Test("supports multiple budgets per book")
    func supportsMultipleBudgets() throws {
        let (document, _, _) = try openFixture()
        createMonthlyBudget(document, guid: try monthlyBudgetGuid("1"))
        document.createBudget(
            guid: try monthlyBudgetGuid("2"),
            name: "Vacation fund",
            description: "",
            periodCount: 4,
            recurrence: Recurrence(periodType: .endOfMonth, multiplier: 3, start: "2026-01-01")
        )
        #expect(document.budgets().map(\.name).sorted() == ["2026 household", "Vacation fund"])
    }

    @Test("updates name, description and periodCount independently")
    func updatesFieldsIndependently() throws {
        let (document, _, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        document.updateBudget(guid, name: "Renamed", description: budget.description, periodCount: budget.periodCount)
        var updated = try #require(document.budget(guid))
        #expect(updated.name == "Renamed")
        #expect(updated.description == budget.description)
        #expect(updated.periodCount == budget.periodCount)

        document.updateBudget(guid, name: updated.name, description: updated.description, periodCount: 6)
        updated = try #require(document.budget(guid))
        #expect(updated.periodCount == 6)
        #expect(updated.name == "Renamed")

        document.updateBudget(guid, name: updated.name, description: "New description", periodCount: updated.periodCount)
        updated = try #require(document.budget(guid))
        #expect(updated.description == "New description")
        #expect(updated.name == "Renamed")
    }

    @Test("updating an unknown budget is a silent no-op")
    func updatingUnknownBudgetIsNoop() throws {
        let (document, _, _) = try openFixture()
        document.updateBudget(try monthlyBudgetGuid("f"), name: "x", description: "", periodCount: 1)
        #expect(document.budgets().isEmpty)
    }

    @Test("deletes a budget; deleting an unknown budget is a silent no-op")
    func deletesBudget() throws {
        let (document, _, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        createMonthlyBudget(document, guid: guid)
        document.deleteBudget(guid)
        #expect(document.budgets().isEmpty)
        document.deleteBudget(try monthlyBudgetGuid("f"))
        #expect(document.budgets().isEmpty)
    }

    @Test("computes each period's [start, end) range from the recurrence")
    func computesPeriodRange() throws {
        let (document, _, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        var range = try document.periodRange(budget, periodIndex: 0)
        #expect(range.start == "2026-01-01")
        #expect(range.end == "2026-02-01")

        range = try document.periodRange(budget, periodIndex: 1)
        #expect(range.start == "2026-02-01")
        #expect(range.end == "2026-03-01")

        range = try document.periodRange(budget, periodIndex: 11)
        #expect(range.start == "2026-12-01")
        #expect(range.end == "2027-01-01")

        #expect(throws: BudgetRangeError.invalidPeriodIndex) {
            try document.periodRange(budget, periodIndex: -1)
        }
    }

    @Test("throws computing a period's end past a 'once' recurrence's single instance")
    func throwsPastOnceRecurrencesSingleInstance() throws {
        // A "once" recurrence has no second instance -- not a realistic
        // budget recurrence in practice (desktop GnuCash's own budget
        // editor only offers repeating period types), but the engine
        // should fail loudly rather than silently miscomputing a range.
        let (document, _, _) = try openFixture()
        let budget = document.createBudget(
            guid: try monthlyBudgetGuid("5"),
            name: "One-off",
            description: "",
            periodCount: 1,
            recurrence: Recurrence(periodType: .once, start: "2026-01-01")
        )
        #expect(throws: BudgetRangeError.recurrenceExhausted) {
            try document.periodRange(budget, periodIndex: 0)
        }
    }

    @Test("sets, reads back and removes a per-account-per-period amount, never writing a zero placeholder")
    func setsReadsAndRemovesAmount() throws {
        let (document, bank, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == nil)

        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 0, amount: try Money(num: 150_000, denom: 100))
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == (try Money(num: 150_000, denom: 100)))

        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<slot:key>\(bank.rawValue)</slot:key>"))
        #expect(xml.contains("<slot:value type=\"frame\">"))
        #expect(xml.contains("<slot:key>0</slot:key><slot:value type=\"numeric\">150000/100</slot:value>"))

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == (try Money(num: 150_000, denom: 100)))

        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 0, amount: nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == nil)
        // Removing the only set period removes the now-empty account frame too.
        #expect(!String(decoding: document.serialize(), as: UTF8.self).contains("<slot:key>\(bank.rawValue)</slot:key>"))
    }

    @Test("tracks several accounts and periods independently on the same budget")
    func tracksSeveralAccountsAndPeriods() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 0, amount: try Money(num: 100_000, denom: 100))
        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 1, amount: try Money(num: 110_000, denom: 100))
        document.setBudgetAmount(budget.guid, accountGuid: salary, periodIndex: 0, amount: try Money(num: -250_000, denom: 100))

        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == (try Money(num: 100_000, denom: 100)))
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 1) == (try Money(num: 110_000, denom: 100)))
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 2) == nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: salary, periodIndex: 0) == (try Money(num: -250_000, denom: 100)))

        // Overwriting an already-set period updates it in place.
        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 1, amount: try Money(num: 120_000, denom: 100))
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 1) == (try Money(num: 120_000, denom: 100)))

        // Removing a period that was never set, on an account that still
        // has a frame (because another period on it is set), is also a no-op.
        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 5, amount: nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 5) == nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 1) == (try Money(num: 120_000, denom: 100)))

        // Removing one period leaves the account's other set period untouched.
        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 0, amount: nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 0) == nil)
        #expect(document.budgetAmount(budget.guid, accountGuid: bank, periodIndex: 1) == (try Money(num: 120_000, denom: 100)))
    }

    @Test("removing an amount from an unknown budget or an account with no frame is a silent no-op")
    func removingFromUnknownBudgetIsNoop() throws {
        let (document, bank, _) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)
        document.setBudgetAmount(budget.guid, accountGuid: bank, periodIndex: 0, amount: nil)
        #expect(document.budgetAmount(try monthlyBudgetGuid("f"), accountGuid: bank, periodIndex: 0) == nil)
    }

    @Test("computes actual as the sum of an account's splits inside the period, live, never stored")
    func computesActualLive() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try monthlyBudgetGuid("1")
        let budget = createMonthlyBudget(document, guid: guid)

        document.postTransaction(
            guid: try #require(Guid(String(repeating: "9", count: 32))),
            date: "2026-01-15",
            description: "January paycheck",
            splits: [
                (accountGuid: bank, value: try Money(num: 300_000, denom: 100), splitGuid: try #require(Guid("a0".repeating(16)))),
                (accountGuid: salary, value: try Money(num: -300_000, denom: 100), splitGuid: try #require(Guid("a1".repeating(16)))),
            ]
        )
        // Outside period 0's range -- must not be counted.
        document.postTransaction(
            guid: try #require(Guid(String(repeating: "a", count: 32))),
            date: "2026-02-15",
            description: "February paycheck",
            splits: [
                (accountGuid: bank, value: try Money(num: 300_000, denom: 100), splitGuid: try #require(Guid("b0".repeating(16)))),
                (accountGuid: salary, value: try Money(num: -300_000, denom: 100), splitGuid: try #require(Guid("b1".repeating(16)))),
            ]
        )

        // `Money.add` normalizes to lowest terms, so 300000/100 comes back as 3000/1.
        #expect(try document.budgetActual(budget.guid, accountGuid: bank, periodIndex: 0) == (try Money(num: 3_000, denom: 1)))
        #expect(try document.budgetActual(budget.guid, accountGuid: salary, periodIndex: 0) == (try Money(num: -3_000, denom: 1)))
        #expect(try document.budgetActual(budget.guid, accountGuid: bank, periodIndex: 1) == (try Money(num: 3_000, denom: 1)))
        // Never written to disk.
        #expect(!String(decoding: document.serialize(), as: UTF8.self).contains("budget-actual"))
    }

    @Test("throws computing actual for an unknown budget")
    func throwsComputingActualForUnknownBudget() throws {
        let (document, bank, _) = try openFixture()
        #expect(throws: BudgetRangeError.unknownBudget) {
            try document.budgetActual(try monthlyBudgetGuid("f"), accountGuid: bank, periodIndex: 0)
        }
    }
}

private extension String {
    /// Builds a 32-hex-character GUID by repeating a two-character pair, matching
    /// the web test's `"a0".repeat(16)` helper.
    func repeating(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
