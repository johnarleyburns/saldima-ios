// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Recurrence")
struct RecurrenceTests {
    @Test("once fires exactly once, then never again")
    func once() throws {
        let recurrence = Recurrence(periodType: .once, start: "2026-01-15")
        #expect(try nextInstance(recurrence, after: "2026-01-10") == "2026-01-15")
        #expect(try nextInstance(recurrence, after: "2026-01-15") == nil)
        #expect(try nextInstance(recurrence, after: "2026-01-20") == nil)
    }

    @Test("day period steps by the multiplier")
    func dayPeriod() throws {
        let everyDay = Recurrence(periodType: .day, start: "2026-01-01")
        #expect(try nextInstance(everyDay, after: "2026-01-01") == "2026-01-02")
        #expect(try nextInstance(everyDay, after: "2026-01-05") == "2026-01-06")

        let everyThirdDay = Recurrence(periodType: .day, multiplier: 3, start: "2026-01-01")
        #expect(try nextInstance(everyThirdDay, after: "2026-01-01") == "2026-01-04")
        #expect(try nextInstance(everyThirdDay, after: "2026-01-04") == "2026-01-07")
    }

    @Test("week period steps by 7 times the multiplier")
    func weekPeriod() throws {
        let everyWeek = Recurrence(periodType: .week, start: "2026-01-01")
        #expect(try nextInstance(everyWeek, after: "2026-01-01") == "2026-01-08")

        let everyOtherWeek = Recurrence(periodType: .week, multiplier: 2, start: "2026-01-01")
        #expect(try nextInstance(everyOtherWeek, after: "2026-01-01") == "2026-01-15")
    }

    @Test("month period clamps the day down for shorter months")
    func monthPeriodClampsShortMonths() throws {
        let monthly = Recurrence(periodType: .month, start: "2026-01-31")
        #expect(try nextInstance(monthly, after: "2026-01-31") == "2026-02-28")
    }

    @Test("year period keeps month and day, clamping a leap Feb 29 off a non-leap year")
    func yearPeriodClampsLeapDay() throws {
        let yearly = Recurrence(periodType: .year, start: "2024-02-29")
        #expect(try nextInstance(yearly, after: "2024-02-29") == "2025-02-28")
    }

    @Test("end of month always lands on the last day of the target month")
    func endOfMonth() throws {
        let recurrence = Recurrence(periodType: .endOfMonth, start: "2026-01-01")
        #expect(try nextInstance(recurrence, after: "2026-01-15") == "2026-01-31")
        #expect(try nextInstance(recurrence, after: "2026-01-31") == "2026-02-28")
    }

    @Test("nth weekday finds the same ordinal weekday as start in the target month")
    func nthWeekdayNormal() throws {
        // 2026-01-06 is the 1st Tuesday of January 2026.
        let recurrence = Recurrence(periodType: .nthWeekday, start: "2026-01-06")
        #expect(try nextInstance(recurrence, after: "2026-01-06") == "2026-02-03")
    }

    @Test("nth weekday falls back to the last occurrence when the ordinal doesn't exist")
    func nthWeekdayFallsBackWhenMissing() throws {
        // 2026-12-29 is the 5th Tuesday of December 2026; January 2027 only has 4.
        let recurrence = Recurrence(periodType: .nthWeekday, start: "2026-12-29")
        #expect(try nextInstance(recurrence, after: "2026-12-29") == "2027-01-26")
    }

    @Test("last weekday always lands on the final occurrence of start's weekday")
    func lastWeekday() throws {
        // 2026-01-27 is the last Tuesday of January 2026.
        let recurrence = Recurrence(periodType: .lastWeekday, start: "2026-01-27")
        #expect(try nextInstance(recurrence, after: "2026-01-27") == "2026-02-24")
    }

    @Test("weekend adjust 'back' moves a Saturday to Friday and a Sunday to Friday")
    func weekendAdjustBack() throws {
        let recurrence = Recurrence(periodType: .day, start: "2026-01-01", weekendAdjust: .back)
        // Candidate 2026-01-03 is a Saturday.
        #expect(try nextInstance(recurrence, after: "2026-01-02") == "2026-01-02")
        // Candidate 2026-01-04 is a Sunday.
        #expect(try nextInstance(recurrence, after: "2026-01-03") == "2026-01-02")
    }

    @Test("weekend adjust 'forward' moves a Saturday and a Sunday both to Monday")
    func weekendAdjustForward() throws {
        let recurrence = Recurrence(periodType: .day, start: "2026-01-01", weekendAdjust: .forward)
        // Candidate 2026-01-03 is a Saturday.
        #expect(try nextInstance(recurrence, after: "2026-01-02") == "2026-01-05")
        // Candidate 2026-01-04 is a Sunday.
        #expect(try nextInstance(recurrence, after: "2026-01-03") == "2026-01-05")
    }

    @Test("weekend adjust 'none' leaves a weekend candidate untouched")
    func weekendAdjustNone() throws {
        let recurrence = Recurrence(periodType: .day, start: "2026-01-01", weekendAdjust: .none)
        #expect(try nextInstance(recurrence, after: "2026-01-02") == "2026-01-03")
    }

    @Test("a multiplier below 1 throws")
    func invalidMultiplier() throws {
        let recurrence = Recurrence(periodType: .day, multiplier: 0, start: "2026-01-01")
        #expect(throws: RecurrenceError.invalidMultiplier) {
            try nextInstance(recurrence, after: "2026-01-01")
        }
    }

    @Test("a malformed date throws")
    func invalidDate() throws {
        let recurrence = Recurrence(periodType: .day, start: "not-a-date")
        #expect(throws: RecurrenceError.invalidDate) {
            try nextInstance(recurrence, after: "2026-01-01")
        }
        let valid = Recurrence(periodType: .day, start: "2026-01-01")
        #expect(throws: RecurrenceError.invalidDate) {
            try nextInstance(valid, after: "2026/01/01")
        }
    }

    @Test("addDays is plain calendar-day arithmetic")
    func addDaysHelper() throws {
        #expect(try addDays("2026-01-30", 5) == "2026-02-04")
        #expect(try addDays("2026-03-01", -1) == "2026-02-28")
    }

    @Test("daysBetween is absolute and order-independent")
    func daysBetweenHelper() throws {
        #expect(try daysBetween("2026-01-01", "2026-01-10") == 9)
        #expect(try daysBetween("2026-01-10", "2026-01-01") == 9)
        #expect(try daysBetween("2026-01-01", "2026-01-01") == 0)
        #expect(try daysBetween("2025-12-28", "2026-01-04") == 7)
    }
}
