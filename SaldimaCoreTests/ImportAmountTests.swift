// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ money: Money?) throws -> String {
    try #require(money).formatted(fraction: 100)
}

@Suite("Import amount parsing")
struct ImportAmountTests {
    @Test("parses exact cents from common formats")
    func parsesCommonFormats() throws {
        #expect(try cents(parseImportAmount("1,234.56")) == "1234.56")
        #expect(try cents(parseImportAmount("$1.234,56")) == "1234.56")
        #expect(try cents(parseImportAmount("(45.00)")) == "-45.00")
        #expect(try cents(parseImportAmount("-12.345")) == "-12.35")
        #expect(try cents(parseImportAmount("1.234")) == "1.23")
    }

    @Test("rejects empty and non-numeric text")
    func rejectsInvalid() {
        #expect(parseImportAmount("") == nil)
        #expect(parseImportAmount("n/a") == nil)
        #expect(parseImportAmount(".") == nil)
        #expect(parseImportAmount(",") == nil)
    }

    @Test("handles signs, thousands and multiple separators")
    func handlesSignsAndSeparators() throws {
        #expect(try cents(parseImportAmount("45.00-")) == "-45.00")
        #expect(try cents(parseImportAmount("+45.00")) == "45.00")
        #expect(try cents(parseImportAmount("1,234")) == "1234.00")
        #expect(try cents(parseImportAmount("1,23")) == "1.23")
        #expect(try cents(parseImportAmount("1.234.567")) == "1234567.00")
        #expect(try cents(parseImportAmount("USD 12.00")) == "12.00")
        #expect(try cents(parseImportAmount("1,234.56")) == "1234.56")
        #expect(try cents(parseImportAmount("1.234,56")) == "1234.56")
    }
}
