// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ rows: [ImportRow]) throws -> [String] {
    try rows.map { try $0.amount.formatted(fraction: 100) }
}

private let qifFixture = """
!Type:Bank
D01/15/2024
T-45.67
PGrocery Mart
MGroceries
LFood:Groceries
N1234
^
D01/16/2024
T1,500.00
PEmployer
LSalary
^
D01/17/2024
T-100.00
PTransfer
L[Savings]
^
D03/01/2024
T-60.00
PStore
SGroceries
$-40.00
SHousehold
$-20.00
^

"""

@Suite("QIF import parsing")
struct ImportQifTests {
    @Test("reads dates, exact amounts, categories, references and splits")
    func readsFullRecords() throws {
        let result = try parseQif(qifFixture)
        #expect(result.source == .qif)
        #expect(result.rows.count == 4)
        let first = result.rows[0]
        #expect(first.date == "2024-01-15")
        #expect(first.payee == "Grocery Mart")
        #expect(first.memo == "Groceries")
        #expect(first.category == "Food:Groceries")
        #expect(first.reference == "1234")
        #expect(try cents(result.rows) == ["-45.67", "1500.00", "-100.00", "-60.00"])
        #expect(result.rows[2].category == "[Savings]")
        #expect(result.rows[3].splits.map(\.category) == ["Groceries", "Household"])
        #expect(try result.rows[3].splits.map { try $0.amount.formatted(fraction: 100) } == ["-40.00", "-20.00"])
    }

    @Test("skips records without a date or amount with a warning")
    func skipsIncompleteRecords() throws {
        let result = try parseQif(
            """
            !Type:Bank
            D01/01/2024
            ^
            T10.00
            ^
            D01/02/2024
            PGood
            T1.00
            ^

            """
        )
        #expect(result.rows.count == 1)
        #expect(result.rows[0].payee == "Good")
        #expect(result.warnings.count == 2)
    }

    @Test("rejects a file with no usable rows")
    func rejectsUnusableFile() {
        #expect(throws: ImportFormatError.self) {
            try parseQif("not a qif file")
        }
    }

    @Test("keeps the last record without a terminator and warns about odd splits")
    func keepsUnterminatedFinalRecord() throws {
        let result = try parseQif(
            """
            !Type:Bank
            !Option:AutoSwitch
            D01/01/2024
            T0.00
            ^
            D01/02/2024
            T5.00
            PGift
            SFood
            ^
            D01/03/2024
            T6.00
            PFinal
            $9.00
            """
        )
        #expect(result.rows.count == 2)
        #expect(result.rows[1].payee == "Final")
        #expect(result.warnings.count == 3)
    }
}
