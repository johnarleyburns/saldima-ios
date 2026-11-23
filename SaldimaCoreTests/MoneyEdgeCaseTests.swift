// SPDX-License-Identifier: AGPL-3.0-only
import Testing

@testable import SaldimaCore

@Suite("Money edge cases")
struct MoneyEdgeCaseTests {
    @Test("a zero or negative denominator is rejected")
    func badDenominator() {
        #expect(throws: MoneyError.invalidDenominator) {
            _ = try Money(num: 1, denom: 0)
        }
        #expect(throws: MoneyError.invalidDenominator) {
            _ = try Money(num: 1, denom: -100)
        }
    }

    @Test("junk decimals are rejected instead of coerced")
    func junkDecimals() {
        for text in ["1,234.56", "1e3", "", ".", "1.", ".5", "--1", "1.2.3"] {
            #expect(throws: MoneyError.self) {
                _ = try Money.parse(text, fraction: 100)
            }
        }
    }

    @Test("formatting needs a power-of-ten fraction")
    func formattingFraction() throws {
        let value = try Money(num: 100, denom: 100)
        #expect(throws: MoneyError.fractionNotPowerOfTen) {
            _ = try value.formatted(fraction: 3)
        }
        #expect(throws: MoneyError.nonPositiveFraction) {
            _ = try value.rounded(toFraction: 0)
        }
    }

    @Test("overflow throws instead of wrapping")
    func overflow() throws {
        let maximum = try Money(num: .max, denom: 1)
        let one = try Money(num: 1, denom: 1)
        #expect(throws: MoneyError.overflow) {
            _ = try Money.add(maximum, one)
        }
        #expect(throws: MoneyError.overflow) {
            _ = try Money.multiply(maximum, maximum)
        }
    }

    @Test("negative zero parses to zero")
    func negativeZero() throws {
        #expect(try Money.parse("-0.00", fraction: 100) == .zero)
    }
}
