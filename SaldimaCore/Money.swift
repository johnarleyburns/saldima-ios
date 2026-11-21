// SPDX-License-Identifier: AGPL-3.0-only

/// GnuCash money: an exact rational held as `Int64` numerator/denominator
/// pairs. No floating point ever touches an amount.
public struct Money: Hashable, Sendable {
    public let num: Int64
    public let denom: Int64

    public init(num: Int64, denom: Int64) throws {
        guard denom > 0 else { throw MoneyError.invalidDenominator }
        self.num = num
        self.denom = denom
    }

    private init(trustedNum: Int64, denom: Int64) {
        self.num = trustedNum
        self.denom = denom
    }

    public static let zero = Money(trustedNum: 0, denom: 1)
}

public enum MoneyError: Error, Equatable, Sendable {
    case invalidDenominator
    case nonPositiveFraction
    case fractionNotPowerOfTen
    case invalidDecimal
    case overflow
}

private func checkedMultiply(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (result, overflow) = left.multipliedReportingOverflow(by: right)
    guard !overflow else { throw MoneyError.overflow }
    return result
}

private func checkedAdd(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw MoneyError.overflow }
    return result
}

private func gcd(_ left: UInt64, _ right: UInt64) -> UInt64 {
    var a = left
    var b = right
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a == 0 ? 1 : a
}

extension Money {
    /// Lowest terms with a positive denominator. Zero becomes 0/1.
    public func normalized() -> Money {
        if num == 0 { return .zero }
        if num == .min { return self }
        let magnitude = num.magnitude
        let divisor = gcd(magnitude, denom.magnitude)
        let sign: Int64 = num < 0 ? -1 : 1
        let reducedNum = Int64(magnitude / divisor) * sign
        let reducedDenom = Int64(denom.magnitude / divisor)
        return Money(trustedNum: reducedNum, denom: reducedDenom)
    }

    public func negated() -> Money {
        Money(trustedNum: -num, denom: denom)
    }

    public static func add(_ left: Money, _ right: Money) throws -> Money {
        let leftNum = try checkedMultiply(left.num, right.denom)
        let rightNum = try checkedMultiply(right.num, left.denom)
        let numerator = try checkedAdd(leftNum, rightNum)
        let denominator = try checkedMultiply(left.denom, right.denom)
        return Money(trustedNum: numerator, denom: denominator).normalized()
    }

    public static func subtract(_ left: Money, _ right: Money) throws -> Money {
        try add(left, right.negated())
    }

    public static func multiply(_ left: Money, _ right: Money) throws -> Money {
        let numerator = try checkedMultiply(left.num, right.num)
        let denominator = try checkedMultiply(left.denom, right.denom)
        return Money(trustedNum: numerator, denom: denominator).normalized()
    }

    /// Round to a commodity fraction using round-half-to-even.
    public func rounded(toFraction fraction: Int64) throws -> Money {
        guard fraction > 0 else { throw MoneyError.nonPositiveFraction }
        let scaled = try checkedMultiply(num, fraction)
        let quotient = scaled / denom
        let remainder = scaled % denom
        let twiceRemainder = try checkedMultiply(Int64(remainder.magnitude), 2)
        let sign: Int64 = remainder < 0 ? -1 : 1

        var rounded = quotient
        if twiceRemainder > denom {
            rounded += sign
        } else if twiceRemainder == denom && quotient % 2 != 0 {
            rounded += sign
        }
        return Money(trustedNum: rounded, denom: fraction)
    }

    public static func decimalPlaces(_ fraction: Int64) throws -> Int {
        guard fraction > 0 else { throw MoneyError.nonPositiveFraction }
        var remaining = fraction
        var places = 0
        while remaining % 10 == 0 && remaining > 1 {
            remaining /= 10
            places += 1
        }
        guard remaining == 1 else { throw MoneyError.fractionNotPowerOfTen }
        return places
    }

    /// Parse a decimal string exactly, then round half-even to `fraction`.
    public static func parse(_ text: String, fraction: Int64) throws -> Money {
        var body = text[...]
        var negative = false
        if body.first == "-" {
            negative = true
            body = body.dropFirst()
        } else if body.first == "+" {
            body = body.dropFirst()
        }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else {
            throw MoneyError.invalidDecimal
        }
        let whole = pieces[0]
        let decimals = pieces.count == 2 ? pieces[1] : ""
        guard !whole.isEmpty,
              whole.allSatisfy({ $0.isASCII && $0.isNumber }),
              decimals.allSatisfy({ $0.isASCII && $0.isNumber }),
              pieces.count == 1 || !decimals.isEmpty
        else {
            throw MoneyError.invalidDecimal
        }
        guard let wholeValue = Int64(whole), let decimalValue = Int64(decimals.isEmpty ? "0" : String(decimals)) else {
            throw MoneyError.overflow
        }
        var scale: Int64 = 1
        for _ in decimals {
            scale = try checkedMultiply(scale, 10)
        }
        let scaledWhole = try checkedMultiply(wholeValue, scale)
        let unscaled = try checkedAdd(scaledWhole, decimalValue)
        let numerator = negative ? -unscaled : unscaled
        return try Money(trustedNum: numerator, denom: scale).rounded(toFraction: fraction)
    }

    public func formatted(fraction: Int64) throws -> String {
        let places = try Self.decimalPlaces(fraction)
        let rounded = try rounded(toFraction: fraction)
        let negative = rounded.num < 0
        let digits = String(rounded.num.magnitude)
        let padded = String(repeating: "0", count: max(0, places + 1 - digits.count)) + digits
        let whole = String(padded.dropLast(places))
        let decimals = places == 0 ? "" : "." + String(padded.suffix(places))
        return (negative ? "-" : "") + whole + decimals
    }
}
