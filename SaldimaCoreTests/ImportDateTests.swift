// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

@Suite("Import date parsing")
struct ImportDateTests {
    @Test("accepts the date shapes banks export")
    func acceptsBankDateShapes() {
        #expect(parseImportDate("2024-01-31") == "2024-01-31")
        #expect(parseImportDate("2024/1/31") == "2024-01-31")
        #expect(parseImportDate("01/31/2024") == "2024-01-31")
        #expect(parseImportDate("31/01/2024") == "2024-01-31")
        #expect(parseImportDate("1/2/24") == "2024-01-02")
        #expect(parseImportDate("20240131120000[0:GMT]") == "2024-01-31")
    }

    @Test("rejects impossible and unrecognised dates")
    func rejectsImpossibleDates() {
        #expect(parseImportDate("2024-02-30") == nil)
        #expect(parseImportDate("13/13/2024") == nil)
        #expect(parseImportDate("yesterday") == nil)
        #expect(parseImportDate("") == nil)
    }

    @Test("handles leap years, short years and other separators")
    func handlesLeapYearsAndShortYears() {
        #expect(parseImportDate("02/29/2024") == "2024-02-29")
        #expect(parseImportDate("02/29/2023") == nil)
        #expect(parseImportDate("01/02/70") == "1970-01-02")
        #expect(parseImportDate("2024/13/01") == nil)
        #expect(parseImportDate("1 2 2024") == "2024-01-02")
        #expect(parseImportDate("20241301") == nil)
    }
}
