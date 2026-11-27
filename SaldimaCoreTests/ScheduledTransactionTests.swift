// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
@testable import SaldimaTestKit

private func scheduleBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("schedule-\(UUID().uuidString).gnucash")
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

@Suite("Scheduled transactions")
struct ScheduledTransactionTests {
    private func openBook() async throws -> (store: BookStore, checking: Guid, salary: Guid) {
        let url = try scheduleBook()
        let store = try BookStore(url: url)
        let roots = try await store.accounts()
        let checking = try #require(account(named: "Checking", in: roots)).guid
        let salary = try #require(account(named: "Salary", in: roots)).guid
        return (store, checking, salary)
    }

    private func draft(
        name: String = "Paycheck",
        checking: Guid,
        salary: Guid,
        autoCreate: Bool = false,
        autoCreateNotify: Bool = false,
        advanceCreateDays: Int = 0,
        advanceRemindDays: Int = 0,
        start: String = "2026-01-01",
        end: ScheduledEndCondition? = nil,
        recurrence: Recurrence? = nil
    ) -> ScheduledTransactionDraft {
        ScheduledTransactionDraft(
            name: name,
            autoCreate: autoCreate,
            autoCreateNotify: autoCreateNotify,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays,
            start: start,
            end: end,
            recurrence: recurrence ?? Recurrence(periodType: .month, start: start),
            templateSplits: [
                ScheduledSplit(accountGuid: checking, value: try! Money(num: 250_000, denom: 100)),
                ScheduledSplit(accountGuid: salary, value: try! Money(num: -250_000, denom: 100)),
            ]
        )
    }

    @Test("creates a schedule and reads it back")
    func createsAndReads() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(
            draft(checking: checking, salary: salary),
            ids: ids
        )
        let all = try await store.scheduledTransactions()
        #expect(all.count == 1)
        #expect(all.first?.guid == guid)
        #expect(all.first?.name == "Paycheck")
        #expect(all.first?.enabled == true)
        #expect(all.first?.instanceCount == 0)
        let one = try await store.scheduledTransaction(guid)
        #expect(one?.templateSplits.count == 2)
    }

    @Test("rejects an invalid draft: blank name, too few splits, unbalanced, unknown account")
    func rejectsInvalidDrafts() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let unknown = try #require(Guid(String(repeating: "c", count: 32)))

        var blankName = draft(checking: checking, salary: salary)
        blankName.name = "  "
        await #expect(throws: ScheduledTransactionError.invalidName) {
            try await store.createScheduledTransaction(blankName, ids: ids)
        }

        var tooFew = draft(checking: checking, salary: salary)
        tooFew.templateSplits = [ScheduledSplit(accountGuid: checking, value: .zero)]
        await #expect(throws: ScheduledTransactionError.tooFewSplits) {
            try await store.createScheduledTransaction(tooFew, ids: ids)
        }

        var unbalanced = draft(checking: checking, salary: salary)
        unbalanced.templateSplits = [
            ScheduledSplit(accountGuid: checking, value: try Money(num: 100, denom: 100)),
            ScheduledSplit(accountGuid: salary, value: try Money(num: -50, denom: 100)),
        ]
        await #expect(throws: ScheduledTransactionError.unbalanced) {
            try await store.createScheduledTransaction(unbalanced, ids: ids)
        }

        var unknownAccount = draft(checking: checking, salary: salary)
        unknownAccount.templateSplits = [
            ScheduledSplit(accountGuid: checking, value: try Money(num: 100, denom: 100)),
            ScheduledSplit(accountGuid: unknown, value: try Money(num: -100, denom: 100)),
        ]
        await #expect(throws: ScheduledTransactionError.unknownAccount(unknown)) {
            try await store.createScheduledTransaction(unknownAccount, ids: ids)
        }
    }

    @Test("updates only the restricted field set, and rejects an unknown schedule")
    func updatesRestrictedFields() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(draft(checking: checking, salary: salary), ids: ids)

        try await store.updateScheduledTransaction(
            guid,
            with: ScheduledTransactionEditDraft(
                name: "Renamed",
                enabled: false,
                autoCreate: true,
                autoCreateNotify: true,
                advanceCreateDays: 3,
                advanceRemindDays: 5
            )
        )
        let updated = try await store.scheduledTransaction(guid)
        #expect(updated?.name == "Renamed")
        #expect(updated?.enabled == false)
        #expect(updated?.autoCreate == true)
        #expect(updated?.advanceCreateDays == 3)
        #expect(updated?.start == "2026-01-01")

        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: ScheduledTransactionError.unknownScheduledTransaction(unknown)) {
            try await store.updateScheduledTransaction(
                unknown,
                with: ScheduledTransactionEditDraft(
                    name: "x", enabled: true, autoCreate: false, autoCreateNotify: false,
                    advanceCreateDays: 0, advanceRemindDays: 0
                )
            )
        }
    }

    @Test("deletes a schedule, and rejects an unknown one")
    func deletes() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(draft(checking: checking, salary: salary), ids: ids)
        try await store.deleteScheduledTransaction(guid)
        #expect(try await store.scheduledTransactions().isEmpty)

        await #expect(throws: ScheduledTransactionError.unknownScheduledTransaction(guid)) {
            try await store.deleteScheduledTransaction(guid)
        }
    }

    @Test("classifies due instances: needs approval, reminder, auto-post, and auto-post-with-notify")
    func classifiesDueInstances() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)

        let needsApproval = try await store.createScheduledTransaction(
            draft(name: "Needs approval", checking: checking, salary: salary, start: "2026-01-01"),
            ids: ids
        )
        let autoPost = try await store.createScheduledTransaction(
            draft(name: "Auto post", checking: checking, salary: salary, autoCreate: true, start: "2026-01-01"),
            ids: ids
        )
        let autoPostNotify = try await store.createScheduledTransaction(
            draft(
                name: "Auto post notify", checking: checking, salary: salary,
                autoCreate: true, autoCreateNotify: true, start: "2026-01-01"
            ),
            ids: ids
        )
        let reminder = try await store.createScheduledTransaction(
            draft(name: "Reminder", checking: checking, salary: salary, advanceRemindDays: 10, start: "2026-01-10"),
            ids: ids
        )

        let due = try await store.dueScheduledInstances(asOf: "2026-01-01")
        let byGuid = Dictionary(uniqueKeysWithValues: due.map { ($0.scheduledTransactionGuid, $0.action) })
        #expect(byGuid[needsApproval] == .needsApproval)
        #expect(byGuid[autoPost] == .autoPost)
        #expect(byGuid[autoPostNotify] == .autoPostNotify)
        #expect(byGuid[reminder] == .reminder)
    }

    @Test("check on open auto-posts, surfaces a notify entry, and leaves needs-approval/reminder for review")
    func processDueOnOpen() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)

        let needsApproval = try await store.createScheduledTransaction(
            draft(name: "Needs approval", checking: checking, salary: salary, start: "2026-01-01"),
            ids: ids
        )
        let autoPost = try await store.createScheduledTransaction(
            draft(name: "Auto post", checking: checking, salary: salary, autoCreate: true, start: "2026-01-01"),
            ids: ids
        )
        let autoPostNotify = try await store.createScheduledTransaction(
            draft(
                name: "Auto post notify", checking: checking, salary: salary,
                autoCreate: true, autoCreateNotify: true, start: "2026-01-01"
            ),
            ids: ids
        )

        let review = try await store.processDueScheduledTransactions(asOf: "2026-01-01", ids: ids)
        let reviewGuids = Set(review.map(\.scheduledTransactionGuid))
        #expect(!reviewGuids.contains(autoPost)) // silent: not in the review list
        #expect(reviewGuids.contains(autoPostNotify)) // posted, but still shown
        #expect(reviewGuids.contains(needsApproval))

        let transactions = try await store.transactions()
        #expect(transactions.count == 2) // autoPost + autoPostNotify were posted

        let autoPostRow = try await store.scheduledTransaction(autoPost)
        #expect(autoPostRow?.instanceCount == 1)
        #expect(autoPostRow?.last == "2026-01-01")
        let needsApprovalRow = try await store.scheduledTransaction(needsApproval)
        #expect(needsApprovalRow?.instanceCount == 0) // never auto-advanced
    }

    @Test("approving posts a real transaction and advances the schedule")
    func approveInstance() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(
            draft(checking: checking, salary: salary, start: "2026-01-01"), ids: ids
        )

        let txGuid = try await store.approveScheduledInstance(guid, date: "2026-01-01", ids: ids)
        let transactions = try await store.transactions()
        #expect(transactions.contains { $0.guid == txGuid })
        #expect(transactions.first { $0.guid == txGuid }?.description == "Paycheck")

        let row = try await store.scheduledTransaction(guid)
        #expect(row?.last == "2026-01-01")
        #expect(row?.instanceCount == 1)

        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: ScheduledTransactionError.unknownScheduledTransaction(unknown)) {
            try await store.approveScheduledInstance(unknown, date: "2026-01-01", ids: ids)
        }
    }

    @Test("skipping advances the schedule permanently, without posting anything")
    func skipInstance() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(
            draft(checking: checking, salary: salary, start: "2026-01-01"), ids: ids
        )

        try await store.skipScheduledInstance(guid, date: "2026-01-01")
        #expect(try await store.transactions().isEmpty)
        let row = try await store.scheduledTransaction(guid)
        #expect(row?.last == "2026-01-01")
        #expect(row?.instanceCount == 1)

        // The skipped instance never reappears (no deferred/postponed list):
        // the schedule has already moved on to the following month.
        let due = try await store.dueScheduledInstances(asOf: "2026-02-01")
        let next = due.first { $0.scheduledTransactionGuid == guid }
        #expect(next?.date == "2026-02-01")
        #expect(next?.action == .needsApproval)

        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: ScheduledTransactionError.unknownScheduledTransaction(unknown)) {
            try await store.skipScheduledInstance(unknown, date: "2026-01-01")
        }
    }

    @Test("a schedule stops producing due instances once its occurrence count is exhausted")
    func occurrenceExhaustion() async throws {
        let (store, checking, salary) = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createScheduledTransaction(
            draft(checking: checking, salary: salary, start: "2026-01-01", end: .occurrences(1)),
            ids: ids
        )

        try await store.skipScheduledInstance(guid, date: "2026-01-01")
        let due = try await store.dueScheduledInstances(asOf: "2027-01-01")
        #expect(due.contains { $0.scheduledTransactionGuid == guid } == false)
    }
}
