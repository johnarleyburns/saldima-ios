// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Ported from the web track's `packages/importers/src/date.ts`. Bank
/// exports are not ISO. Supports ISO, US and European slash dates (the
/// first component above 12 disambiguates day-first) and OFX timestamps.
/// Mirrors `date.ts`'s own private `isLeap`/`daysInMonth` rather than
/// reusing `Recurrence.swift`'s copies, exactly as the web source keeps
/// its own private copy separate from `recurrence.ts`.

private func importDateIsLeap(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

private func importDateDaysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return importDateIsLeap(year) ? 29 : 28
    default: return 30
    }
}

private func isoDate(year: Int, month: Int, day: Int) -> String? {
    guard month >= 1, month <= 12 else { return nil }
    guard day >= 1, day <= importDateDaysInMonth(year, month) else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func fullYear(_ value: Int, digits: Int) -> Int {
    digits == 4 ? value : (value >= 70 ? 1900 + value : 2000 + value)
}

private func intGroup(_ match: Regex<AnyRegexOutput>.Match, _ index: Int) -> Int? {
    guard index < match.output.count, let substring = match.output[index].substring else { return nil }
    return Int(substring)
}

private func textGroup(_ match: Regex<AnyRegexOutput>.Match, _ index: Int) -> Substring? {
    guard index < match.output.count else { return nil }
    return match.output[index].substring
}

public func parseImportDate(_ text: String) -> String? {
    // Built locally rather than as stored globals: Swift 6 strict
    // concurrency treats a global `Regex` as unsynchronized mutable state
    // (it isn't `Sendable`), and this repo's Swift 6 guard script rejects
    // the usual ways around that restriction.
    let ofxStampPattern = try! Regex(#"^(\d{4})(\d{2})(\d{2})"#)
    let isoPattern = try! Regex(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#)
    let numericPattern = try! Regex(#"^(\d{1,4})[/. '-](\d{1,2})[/. '-](\d{1,4})$"#)

    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if let match = value.firstMatch(of: ofxStampPattern),
       let year = intGroup(match, 1), let month = intGroup(match, 2), let day = intGroup(match, 3) {
        return isoDate(year: year, month: month, day: day)
    }

    if let match = value.firstMatch(of: isoPattern),
       let year = intGroup(match, 1), let month = intGroup(match, 2), let day = intGroup(match, 3) {
        return isoDate(year: year, month: month, day: day)
    }

    guard let match = value.firstMatch(of: numericPattern),
          let firstText = textGroup(match, 1), let first = Int(firstText),
          let middle = intGroup(match, 2),
          let thirdText = textGroup(match, 3), let third = Int(thirdText)
    else {
        return nil
    }

    if firstText.count == 4 {
        return isoDate(year: first, month: middle, day: third)
    }
    let year = fullYear(third, digits: thirdText.count)
    if first > 12 {
        return isoDate(year: year, month: middle, day: first)
    }
    return isoDate(year: year, month: first, day: middle)
}
