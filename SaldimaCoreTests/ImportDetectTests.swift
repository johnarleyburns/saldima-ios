// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private let qifFixture = """
!Type:Bank
D01/15/2024
T-45.67
PGrocery Mart
MGroceries
LFood:Groceries
N1234
^

"""

private let ofxSgmlFixture = """
OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20240115<TRNAMT>-45.67</STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
"""

@Suite("Import source detection")
struct ImportDetectTests {
    @Test("sniffs QIF, OFX and CSV regardless of extension")
    func sniffsFormatsRegardlessOfExtension() {
        #expect(detectImportSource(fileName: "statement.txt", text: qifFixture) == .qif)
        #expect(detectImportSource(fileName: "statement.csv", text: ofxSgmlFixture) == .ofx)
        #expect(detectImportSource(fileName: "statement.qif", text: "Date,Amount\n2024-01-01,5.00") == .csv)
        #expect(detectImportSource(fileName: "statement.qfx", text: "no markers here") == .ofx)
        #expect(detectImportSource(fileName: "statement.txt", text: "^ only\nsomething") == .csv)
    }

    @Test("routes a parsed file through the right parser")
    func routesToRightParser() throws {
        let result = try parseImportFile(fileName: "statement.qif", text: qifFixture)
        #expect(result.source == .qif)
        #expect(result.rows.count == 1)
        #expect(throws: ImportFormatError.self) {
            try parseImportFile(fileName: "empty.csv", text: "Name,Note\n")
        }
    }
}
