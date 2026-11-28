// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Import duplicate detection")
struct ImportDuplicatesTests {
    private var existing: [ExistingEntry] {
        [ExistingEntry(date: "2024-01-10", amount: try! Money(num: 1000, denom: 100))]
    }

    @Test("flags the same amount within three days")
    func flagsWithinWindow() throws {
        #expect(
            isLikelyDuplicate(
                date: "2024-01-13",
                amount: try Money(num: 10, denom: 1),
                existing: existing
            )
        )
    }

    @Test("does not flag a different amount or a distant date")
    func doesNotFlagMismatches() throws {
        #expect(
            !isLikelyDuplicate(date: "2024-01-13", amount: try Money(num: 1001, denom: 100), existing: existing)
        )
        #expect(
            !isLikelyDuplicate(date: "2024-01-14", amount: try Money(num: 1000, denom: 100), existing: existing)
        )
        #expect(
            !isLikelyDuplicate(date: "2024-01-10", amount: try Money(num: -1000, denom: 100), existing: existing)
        )
    }

    @Test("ignores entries with unreadable dates")
    func ignoresUnreadableDates() throws {
        #expect(
            !isLikelyDuplicate(date: "not-a-date", amount: try Money(num: 1000, denom: 100), existing: existing)
        )
        #expect(
            !isLikelyDuplicate(
                date: "2024-01-10",
                amount: try Money(num: 1000, denom: 100),
                existing: [ExistingEntry(date: "not-a-date", amount: try Money(num: 1000, denom: 100))]
            )
        )
    }

    @Test("exactly three days away still counts, four does not")
    func windowBoundary() throws {
        let anchor = [ExistingEntry(date: "2024-01-10", amount: try! Money(num: 500, denom: 100))]
        #expect(isLikelyDuplicate(date: "2024-01-13", amount: try Money(num: 500, denom: 100), existing: anchor))
        #expect(isLikelyDuplicate(date: "2024-01-07", amount: try Money(num: 500, denom: 100), existing: anchor))
        #expect(!isLikelyDuplicate(date: "2024-01-14", amount: try Money(num: 500, denom: 100), existing: anchor))
        #expect(!isLikelyDuplicate(date: "2024-01-06", amount: try Money(num: 500, denom: 100), existing: anchor))
    }
}
