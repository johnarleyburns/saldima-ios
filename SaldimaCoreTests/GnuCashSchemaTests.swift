// SPDX-License-Identifier: AGPL-3.0-only
import Testing

@testable import SaldimaCore

@Suite("GnuCash schema gate")
struct GnuCashSchemaTests {
    @Test("accepts the two tested release lines")
    func acceptsTestedLines() {
        #expect(GnuCashSchema.supports(major: 4, minor: 14))
        #expect(GnuCashSchema.supports(major: 5, minor: 0))
        #expect(GnuCashSchema.supports(major: 5, minor: 16))
        #expect(GnuCashSchema.supports(major: 5, minor: 99))
    }

    @Test("refuses older and unreleased lines")
    func refusesUntestedLines() {
        #expect(!GnuCashSchema.supports(major: 4, minor: 13))
        #expect(!GnuCashSchema.supports(major: 6, minor: 0))
        #expect(!GnuCashSchema.supports(major: 3, minor: 8))
        #expect(!GnuCashSchema.supports(major: -1, minor: 4))
    }
}
