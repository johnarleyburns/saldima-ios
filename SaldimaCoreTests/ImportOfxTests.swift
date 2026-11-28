// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import SaldimaCore

private func cents(_ rows: [ImportRow]) throws -> [String] {
    try rows.map { try $0.amount.formatted(fraction: 100) }
}

private let ofxSgml = """
OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20240115120000<TRNAMT>-45.67<FITID>abc123<NAME>Grocery Mart<MEMO>Card</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20240116<TRNAMT>1500.00<FITID>def456<NAME>Employer</STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
"""

private let ofxXml = """
<?xml version="1.0"?>
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20240115</DTPOSTED><TRNAMT>-45.67</TRNAMT><FITID>abc123</FITID><NAME>Grocery Mart</NAME><MEMO>Card</MEMO></STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
"""

@Suite("OFX import parsing")
struct ImportOfxTests {
    @Test("reads SGML bank transactions")
    func readsSgml() throws {
        let result = try parseOfx(ofxSgml)
        #expect(result.source == .ofx)
        #expect(result.rows.count == 2)
        #expect(result.rows[0].date == "2024-01-15")
        #expect(result.rows[0].payee == "Grocery Mart")
        #expect(result.rows[0].memo == "Card")
        #expect(result.rows[0].reference == "abc123")
        #expect(try cents(result.rows) == ["-45.67", "1500.00"])
    }

    @Test("reads XML bank transactions")
    func readsXml() throws {
        let result = try parseOfx(ofxXml)
        #expect(result.rows.count == 1)
        #expect(result.rows[0].payee == "Grocery Mart")
    }

    @Test("keeps usable rows and falls back to payee and check number")
    func keepsUsableRowsWithFallbacks() throws {
        let result = try parseOfx(
            """
            <OFX>
            <STMTTRN><DTPOSTED>bad<TRNAMT>1.00</STMTTRN>
            <STMTTRN><DTPOSTED>20240101<TRNAMT>bad</STMTTRN>
            <STMTTRN><DTPOSTED>20240101<TRNAMT>0.00</STMTTRN>
            <STMTTRN><DTPOSTED>20240102<TRNAMT>2.00<PAYEE>Payee Co<CHECKNUM>77</STMTTRN>
            </OFX>
            """
        )
        #expect(result.rows.count == 1)
        #expect(result.rows[0].payee == "Payee Co")
        #expect(result.rows[0].reference == "77")
        #expect(result.warnings.count == 3)
    }

    @Test("rejects files without transactions")
    func rejectsFilesWithoutTransactions() {
        #expect(throws: ImportFormatError.self) {
            try parseOfx("<OFX></OFX>")
        }
    }
}
