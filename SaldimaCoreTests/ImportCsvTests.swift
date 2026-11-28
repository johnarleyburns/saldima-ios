// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ rows: [ImportRow]) throws -> [String] {
    try rows.map { try $0.amount.formatted(fraction: 100) }
}

@Suite("CSV import parsing")
struct ImportCsvTests {
    @Test("detects headers, quoted fields and exact amounts")
    func detectsHeadersAndQuotedFields() throws {
        let result = try parseCsv(
            """
            Date,Description,Amount,Category,Reference
            2024-01-05,"Coffee, shop",-4.50,Meals,1001
            2024-01-06,Paycheck,"2,000.00",Salary,

            """
        )
        #expect(result.source == .csv)
        #expect(result.rows.count == 2)
        #expect(result.rows[0].date == "2024-01-05")
        #expect(result.rows[0].payee == "Coffee, shop")
        #expect(result.rows[0].category == "Meals")
        #expect(result.rows[0].reference == "1001")
        #expect(try cents(result.rows) == ["-4.50", "2000.00"])
    }

    @Test("uses debit and credit columns and a semicolon delimiter")
    func usesDebitAndCreditColumns() throws {
        let text = """
        Date;Description;Debit;Credit
        01/05/2024;Rent;1,200.00;
        01/06/2024;Refund;;25.00

        """
        let table = parseCsvTable(text)
        #expect(table.delimiter == ";")
        let map = try detectCsvMap(table.header)
        #expect(map.valueIndex == nil)
        #expect(map.outflowIndex != nil)
        #expect(map.inflowIndex != nil)
        let result = try parseCsv(text, map: map)
        #expect(try cents(result.rows) == ["-1200.00", "25.00"])
    }

    @Test("warns about rows it cannot read but keeps the rest")
    func warnsAboutUnreadableRows() throws {
        let result = try parseCsv(
            """
            Posted,Payee,Debit,Credit
            2024-01-01,Good,10.00,
            not-a-date,Bad,5.00,
            2024-01-03,Also good,,7.00

            """
        )
        #expect(result.rows.count == 2)
        #expect(result.warnings.count == 1)
    }

    @Test("rejects a table without a date or amount column")
    func rejectsTableWithoutRequiredColumns() {
        #expect(throws: ImportFormatError.self) {
            try detectCsvMap(["Name", "Note"])
        }
    }

    @Test("handles BOM, pipes, escaped quotes and CRLF")
    func handlesBomPipesAndCrlf() throws {
        let result = try parseCsv(
            "\u{FEFF}Date|Description|Amount\r\n2024-01-01|\"A \"\"quoted\"\" shop\"|-1.00\r\n"
        )
        #expect(result.rows[0].payee == "A \"quoted\" shop")
        #expect(try cents(result.rows) == ["-1.00"])
    }

    @Test("skips bad debit, credit, empty and zero rows")
    func skipsBadRows() throws {
        let result = try parseCsv(
            """
            Date,Description,Debit,Credit
            2024-01-01,Bad debit,xx,
            2024-01-02,Bad credit,,yy
            2024-01-03,None,,
            2024-01-04,Zero,0.00,
            ,
            2024-01-05,Good,3.00,

            """
        )
        #expect(result.rows.count == 1)
        #expect(result.warnings.count == 4)
    }

    @Test("uses the first unclaimed column for the description and value headers")
    func usesFirstUnclaimedColumn() throws {
        let result = try parseCsv(
            """
            Date,Merchant,Value,Type,Check Number
            2024-01-01,Bar,5.00,Income,42

            """
        )
        #expect(result.rows[0].payee == "Bar")
        #expect(result.rows[0].category == "Income")
        #expect(result.rows[0].reference == "42")
    }

    @Test("throws when every row is unusable")
    func throwsWhenEveryRowUnusable() {
        #expect(throws: ImportFormatError.self) {
            try parseCsv("Date,Amount\nnot-a-date,5.00")
        }
    }
}
