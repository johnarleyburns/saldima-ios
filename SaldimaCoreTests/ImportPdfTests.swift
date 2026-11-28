// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ money: Money) throws -> String {
    try money.formatted(fraction: 100)
}

@Suite("PDF statement line-parsing heuristic")
struct ImportPdfTests {
    @Test("a clean single-amount line becomes a row")
    func cleanLine() throws {
        let rows = parsePdfStatementLines(["01/15/2024 Grocery Store -45.67"], inferredYear: 2024)
        let row = try #require(rows.first)
        #expect(row.date == "2024-01-15")
        #expect(try cents(row.amount) == "-45.67")
        #expect(row.payee == "Grocery Store")
    }

    @Test("amount then running balance: the first token on the line wins")
    func amountThenBalance() throws {
        let rows = parsePdfStatementLines(["01/16/2024 Paycheck 1500.00 2500.00"], inferredYear: 2024)
        let row = try #require(rows.first)
        #expect(row.date == "2024-01-16")
        #expect(try cents(row.amount) == "1500.00")
        #expect(row.payee == "Paycheck 2500.00")
    }

    @Test("a parenthesized amount is negative")
    func parenthesizedNegative() throws {
        let rows = parsePdfStatementLines(["02/01/2024 Refund Adjustment (12.34)"], inferredYear: 2024)
        let row = try #require(rows.first)
        #expect(row.date == "2024-02-01")
        #expect(try cents(row.amount) == "-12.34")
        #expect(row.payee == "Refund Adjustment")
    }

    @Test("a trailing bare dash is also negative")
    func trailingDashNegative() throws {
        let rows = parsePdfStatementLines(["02/02/2024 Fee 5.00-"], inferredYear: 2024)
        let row = try #require(rows.first)
        #expect(try cents(row.amount) == "-5.00")
    }

    @Test("every date-token form is recognised in priority order")
    func everyDateTokenForm() throws {
        let cases: [(line: String, expectedDate: String)] = [
            ("01/15/2024 Foo 10.00", "2024-01-15"),
            ("01-15-2024 Foo 10.00", "2024-01-15"),
            ("01/15/24 Foo 10.00", "2024-01-15"),
            ("Jan 15, 2024 Foo 10.00", "2024-01-15"),
            ("Jan 15 2024 Foo 10.00", "2024-01-15"),
        ]
        for (line, expectedDate) in cases {
            let rows = parsePdfStatementLines([line], inferredYear: 1999)
            let row = try #require(rows.first, "expected a row for line: \(line)")
            #expect(row.date == expectedDate, "line: \(line)")
        }
    }

    @Test("a date with no year uses the inferred year")
    func noYearDateUsesInferredYear() throws {
        let slashRows = parsePdfStatementLines(["01/15 Foo 10.00"], inferredYear: 2024)
        #expect(try #require(slashRows.first).date == "2024-01-15")

        let monthNameRows = parsePdfStatementLines(["Jan 15 Foo 10.00"], inferredYear: 2024)
        #expect(try #require(monthNameRows.first).date == "2024-01-15")
    }

    @Test("a line missing the date, the amount, or both is skipped silently")
    func skipsLinesMissingEitherToken() {
        #expect(parsePdfStatementLines(["Just some text with no date or amount"], inferredYear: 2024).isEmpty)
        #expect(parsePdfStatementLines(["01/15/2024 Grocery Store, no amount here"], inferredYear: 2024).isEmpty)
        #expect(parsePdfStatementLines(["Amount only, no date 45.67"], inferredYear: 2024).isEmpty)
    }

    @Test("the amount token may come before the date token on the line")
    func amountBeforeDate() throws {
        let rows = parsePdfStatementLines(["Amount 45.67 posted 01/15/2024 Grocery"], inferredYear: 2024)
        let row = try #require(rows.first)
        #expect(row.date == "2024-01-15")
        #expect(try cents(row.amount) == "45.67")
        #expect(row.payee == "Amount posted Grocery")
    }

    @Test("infers the statement year from the first ~2000 characters")
    func infersStatementYear() {
        #expect(inferStatementYear("Statement period: Jan 1 2022 - Jan 31 2022", fallbackYear: 2024) == 2022)
        #expect(inferStatementYear("No year printed anywhere in this statement", fallbackYear: 2024) == 2024)
    }

    @Test("a blank (scanned/image) PDF surfaces a clear message instead of a crash")
    func scannedPdfSurfacesMessage() {
        #expect(throws: ImportFormatError.self) {
            try parsePdfStatementText("", fallbackYear: 2024)
        }
        #expect(throws: ImportFormatError.self) {
            try parsePdfStatementText("   \n  \n", fallbackYear: 2024)
        }
    }

    @Test("a real-shaped statement produces rows and the experimental-import warning")
    func realShapedStatementProducesWarning() throws {
        let text = """
        Monthly Statement - January 2024

        01/15/2024 Grocery Store -45.67 954.33
        01/16/2024 Paycheck 1500.00 2454.33
        Thank you for your business.
        """
        let result = try parsePdfStatementText(text, fallbackYear: 2099)
        #expect(result.source == .pdf)
        #expect(result.rows.count == 2)
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0]
                == "Experimental PDF import: 2 transaction-like line(s) found. Review every row carefully before importing."
        )
    }
}
