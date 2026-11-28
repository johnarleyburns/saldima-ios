// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Ported from the web track's `packages/importers/src/amount.ts`. Reads a
/// bank amount exactly to cents, handling currency symbols, thousands
/// separators, European decimal commas and accounting parentheses.

private enum DecimalSeparator {
    case comma
    case dot
    case none
}

private func decimalSeparator(_ value: String) -> DecimalSeparator {
    let commaIndex = value.lastIndex(of: ",")
    let dotIndex = value.lastIndex(of: ".")
    if let commaIndex, let dotIndex {
        return commaIndex > dotIndex ? .comma : .dot
    }
    if let commaIndex {
        let digitsAfter = value.distance(from: value.index(after: commaIndex), to: value.endIndex)
        let parts = value.components(separatedBy: ",")
        return (parts.count == 2 && digitsAfter > 0 && digitsAfter <= 2) ? .comma : .none
    }
    let dotParts = value.components(separatedBy: ".")
    return dotParts.count > 2 ? .none : .dot
}

/// Strips whitespace/apostrophes (Swiss thousands separator), any Unicode
/// currency symbol, and any ASCII letter -- the Swift equivalent of the
/// web source's `/[\s']/g` then `/[\p{Sc}A-Za-z]/gu` replacements.
private func stripAmountNoise(_ value: String) -> String {
    String(value.unicodeScalars.filter { scalar in
        if CharacterSet.whitespaces.contains(scalar) || scalar.value == 0x27 { return false }
        if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { return false }
        if scalar.properties.generalCategory == .currencySymbol { return false }
        return true
    })
}

private func isUnsignedDecimal(_ value: String) -> Bool {
    let parts = value.components(separatedBy: ".")
    guard parts.count == 1 || parts.count == 2 else { return false }
    guard let whole = parts.first, !whole.isEmpty,
          whole.allSatisfy({ $0.isASCII && $0.isNumber })
    else {
        return false
    }
    if parts.count == 2 {
        let fraction = parts[1]
        guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    }
    return true
}

public func parseImportAmount(_ text: String) -> Money? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    var negative = false
    if value.count >= 2, value.hasPrefix("("), value.hasSuffix(")") {
        negative = true
        value = String(value.dropFirst().dropLast())
    }
    value = stripAmountNoise(value)

    if value.hasPrefix("+") {
        value.removeFirst()
    }
    if value.hasPrefix("-") {
        negative.toggle()
        value.removeFirst()
    }
    if value.hasSuffix("-") {
        negative.toggle()
        value.removeLast()
    }

    let separator = decimalSeparator(value)
    let normalised: String
    switch separator {
    case .comma:
        normalised = value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
    case .dot:
        normalised = value.replacingOccurrences(of: ",", with: "")
    case .none:
        normalised = value.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
    }

    guard isUnsignedDecimal(normalised) else { return nil }
    guard let exact = try? Money.parseExact(normalised),
          let rounded = try? exact.roundedHalfUp(toFraction: 100)
    else {
        return nil
    }
    let signed = negative ? rounded.negated() : rounded
    return signed.normalized()
}
