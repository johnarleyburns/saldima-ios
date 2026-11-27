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

@Suite("XMLBookDocument scheduled transactions")
struct XMLBookDocumentScheduledTests {
    private func openFixture() throws -> (document: XMLBookDocument, bank: Guid, salary: Guid) {
        let document = try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
        let bank = try #require(document.accounts().first { $0.name == "Bank" }?.guid)
        let salary = try #require(document.accounts().first { $0.name == "Salary" }?.guid)
        return (document, bank, salary)
    }

    @Test("creates a schedule, lazily building the Template Root and its template transaction")
    func createsScheduleAndTemplateScaffolding() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        let recurrence = Recurrence(periodType: .month, start: "2026-01-01")

        let row = document.createScheduledTransaction(
            guid: guid,
            name: "Paycheck",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: nil,
            recurrence: recurrence,
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: 100_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: -100_000, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )

        #expect(row.name == "Paycheck")
        #expect(row.enabled)
        #expect(row.instanceCount == 0)
        #expect(row.last == nil)
        #expect(row.end == nil)
        #expect(row.recurrence == recurrence)
        #expect(row.templateSplits.count == 2)
        #expect(document.scheduledTransactions().count == 1)
        #expect(document.scheduledTransaction(guid) == row)

        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<gnc:template-transactions>"))
        #expect(xml.contains("<act:name>Template Root</act:name>"))
        #expect(xml.contains("<act:type>ROOT</act:type>"))
        #expect(xml.contains("<cmdty:space>template</cmdty:space>"))
        #expect(xml.contains("<cmdty:id>template</cmdty:id>"))
        #expect(xml.contains("<recurrence:period_type>month</recurrence:period_type>"))
        #expect(xml.contains("<sx:name>Paycheck</sx:name>"))
        #expect(xml.contains("<gdate>2026-01-01</gdate>"))
        // weekend_adj is omitted entirely when "none".
        #expect(!xml.contains("recurrence:weekend_adj"))
        // sx:last is absent until the first post/skip.
        #expect(!xml.contains("<sx:last>"))
        // no end given: neither num-occur/rem-occur nor sx:end are written.
        #expect(!xml.contains("sx:num-occur"))
        #expect(!xml.contains("sx:end"))
    }

    @Test("a second schedule reuses the same Template Root instead of creating another")
    func reusesTemplateRootAcrossSchedules() throws {
        let (document, bank, salary) = try openFixture()
        let recurrence = Recurrence(periodType: .month, start: "2026-01-01")
        func makeSplits() -> [ScheduledSplitRow] {
            [
                ScheduledSplitRow(accountGuid: bank, value: try! Money(num: 5_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try! Money(num: -5_000, denom: 100)),
            ]
        }
        document.createScheduledTransaction(
            guid: try #require(Guid(String(repeating: "1", count: 32))),
            name: "First",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: nil,
            recurrence: recurrence,
            templateSplits: makeSplits(),
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )
        document.createScheduledTransaction(
            guid: try #require(Guid(String(repeating: "2", count: 32))),
            name: "Second",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-05",
            end: nil,
            recurrence: recurrence,
            templateSplits: makeSplits(),
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 950)
        )

        #expect(document.scheduledTransactions().count == 2)
        let xml = String(decoding: document.serialize(), as: UTF8.self)
        let templateRootOccurrences = xml.components(separatedBy: "<act:name>Template Root</act:name>").count - 1
        #expect(templateRootOccurrences == 1)
        let wrapperOccurrences = xml.components(separatedBy: "<gnc:template-transactions>").count - 1
        #expect(wrapperOccurrences == 1)
    }

    @Test("the sched-xaction KVP frame always writes both sides, the unused one empty")
    func kvpFrameWritesBothSidesAlways() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        document.createScheduledTransaction(
            guid: guid,
            name: "Rent",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: nil,
            recurrence: Recurrence(periodType: .month, start: "2026-01-01"),
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: -150_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: 150_000, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )
        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<slot:key>credit-formula</slot:key><slot:value type=\"string\"/>"))
        #expect(xml.contains("<slot:key>credit-numeric</slot:key><slot:value type=\"numeric\">0/1</slot:value>"))
        #expect(xml.contains("<slot:key>debit-formula</slot:key><slot:value type=\"string\">1500.00</slot:value>"))
        #expect(xml.contains("<slot:key>debit-numeric</slot:key><slot:value type=\"numeric\">150000/100</slot:value>"))
    }

    @Test("reads back recurrence, end and template splits exactly as written")
    func readsBackFields() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        let recurrence = Recurrence(periodType: .nthWeekday, multiplier: 2, start: "2026-01-06", weekendAdjust: .forward)
        document.createScheduledTransaction(
            guid: guid,
            name: "Biweekly thing",
            enabled: false,
            autoCreate: true,
            autoCreateNotify: true,
            advanceCreateDays: 3,
            advanceRemindDays: 5,
            start: "2026-01-06",
            end: .occurrences(12),
            recurrence: recurrence,
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: 2_500, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: -2_500, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )

        let row = try #require(document.scheduledTransaction(guid))
        #expect(row.enabled == false)
        #expect(row.autoCreate)
        #expect(row.autoCreateNotify)
        #expect(row.advanceCreateDays == 3)
        #expect(row.advanceRemindDays == 5)
        #expect(row.start == "2026-01-06")
        #expect(row.end == .occurrences(12))
        #expect(row.recurrence == recurrence)
        #expect(Set(row.templateSplits.map(\.accountGuid)) == Set([bank, salary]))

        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<recurrence:period_type>nth weekday</recurrence:period_type>"))
        #expect(xml.contains("<recurrence:weekend_adj>forward</recurrence:weekend_adj>"))
        #expect(xml.contains("<sx:num-occur>12</sx:num-occur>"))
        #expect(xml.contains("<sx:rem-occur>12</sx:rem-occur>"))

        // Round trip survives a reparse.
        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.scheduledTransaction(guid) == row)
    }

    @Test("writes an end date instead of occurrences, mutually exclusive")
    func writesEndDate() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        document.createScheduledTransaction(
            guid: guid,
            name: "Ends on a date",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: .date("2026-12-31"),
            recurrence: Recurrence(periodType: .month, start: "2026-01-01"),
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: 1_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: -1_000, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )
        let row = try #require(document.scheduledTransaction(guid))
        #expect(row.end == .date("2026-12-31"))
        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(!xml.contains("sx:num-occur"))
        #expect(!xml.contains("sx:rem-occur"))
        #expect(xml.contains("<sx:end>"))
    }

    @Test("advancing inserts sx:last once, right after sx:start, and never duplicates it")
    func advanceInsertsLastOnce() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        document.createScheduledTransaction(
            guid: guid,
            name: "Advances",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: nil,
            recurrence: Recurrence(periodType: .month, start: "2026-01-01"),
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: 1_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: -1_000, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )

        document.advanceScheduledTransaction(guid, to: "2026-01-01")
        var row = try #require(document.scheduledTransaction(guid))
        #expect(row.last == "2026-01-01")
        #expect(row.instanceCount == 1)
        var xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.components(separatedBy: "<sx:last>").count - 1 == 1)

        document.advanceScheduledTransaction(guid, to: "2026-02-01")
        row = try #require(document.scheduledTransaction(guid))
        #expect(row.last == "2026-02-01")
        #expect(row.instanceCount == 2)
        xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.components(separatedBy: "<sx:last>").count - 1 == 1)
    }

    @Test("updating a schedule only touches the restricted set of fields")
    func updateRestrictedFields() throws {
        let (document, bank, salary) = try openFixture()
        let guid = try #require(Guid(String(repeating: "1", count: 32)))
        let recurrence = Recurrence(periodType: .month, start: "2026-01-01")
        document.createScheduledTransaction(
            guid: guid,
            name: "Original",
            enabled: true,
            autoCreate: false,
            autoCreateNotify: false,
            advanceCreateDays: 0,
            advanceRemindDays: 0,
            start: "2026-01-01",
            end: nil,
            recurrence: recurrence,
            templateSplits: [
                ScheduledSplitRow(accountGuid: bank, value: try Money(num: 1_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try Money(num: -1_000, denom: 100)),
            ],
            currencyCode: "USD",
            currencyFraction: 100,
            ids: SeededIDGenerator(start: 900)
        )

        document.updateScheduledTransaction(
            guid,
            name: "Renamed",
            enabled: false,
            autoCreate: true,
            autoCreateNotify: true,
            advanceCreateDays: 7,
            advanceRemindDays: 2
        )

        let row = try #require(document.scheduledTransaction(guid))
        #expect(row.name == "Renamed")
        #expect(row.enabled == false)
        #expect(row.autoCreate)
        #expect(row.autoCreateNotify)
        #expect(row.advanceCreateDays == 7)
        #expect(row.advanceRemindDays == 2)
        // Untouched.
        #expect(row.start == "2026-01-01")
        #expect(row.recurrence == recurrence)
        #expect(row.templateSplits.count == 2)
    }

    @Test("deleting a schedule removes its template transaction and account, but keeps the shared Template Root")
    func deleteRemovesTemplateButKeepsRoot() throws {
        let (document, bank, salary) = try openFixture()
        let keep = try #require(Guid(String(repeating: "1", count: 32)))
        let remove = try #require(Guid(String(repeating: "2", count: 32)))
        let recurrence = Recurrence(periodType: .month, start: "2026-01-01")
        func makeSplits() -> [ScheduledSplitRow] {
            [
                ScheduledSplitRow(accountGuid: bank, value: try! Money(num: 1_000, denom: 100)),
                ScheduledSplitRow(accountGuid: salary, value: try! Money(num: -1_000, denom: 100)),
            ]
        }
        document.createScheduledTransaction(
            guid: keep, name: "Keep", enabled: true, autoCreate: false, autoCreateNotify: false,
            advanceCreateDays: 0, advanceRemindDays: 0, start: "2026-01-01", end: nil,
            recurrence: recurrence, templateSplits: makeSplits(),
            currencyCode: "USD", currencyFraction: 100, ids: SeededIDGenerator(start: 900)
        )
        document.createScheduledTransaction(
            guid: remove, name: "Remove", enabled: true, autoCreate: false, autoCreateNotify: false,
            advanceCreateDays: 0, advanceRemindDays: 0, start: "2026-01-01", end: nil,
            recurrence: recurrence, templateSplits: makeSplits(),
            currencyCode: "USD", currencyFraction: 100, ids: SeededIDGenerator(start: 950)
        )

        document.deleteScheduledTransaction(remove)

        #expect(document.scheduledTransaction(remove) == nil)
        #expect(document.scheduledTransaction(keep) != nil)
        #expect(document.scheduledTransactions().count == 1)
        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<act:name>Template Root</act:name>"))
        #expect(xml.contains("<gnc:template-transactions>"))
    }
}
