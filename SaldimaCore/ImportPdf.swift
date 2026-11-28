// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Experimental PDF statement line-parsing. There is nothing to port here
/// -- this is a from-scratch heuristic over already-extracted page text.
/// PDF text extraction itself (`PDFDocument`/`PDFPage.string`, via
/// PDFKit) happens in the `Saldima` app target, which is Apple-only; this
/// file stays plain Swift/Foundation so it keeps building and testing on
/// Linux like the rest of `SaldimaCore`.
///
/// Known, documented limitations (not solved here):
/// - Year inference can mis-attribute dates across a year boundary when
///   the statement never prints a year anywhere in its first ~2000
///   characters.
/// - Multi-line-wrapped descriptions are not stitched back together.
/// - A scanned/image-only PDF yields no extractable text at all; real OCR
///   (e.g. an on-device ML model) is out of scope for this milestone, so
///   that case surfaces a clear message instead of a crash or a
///   fabricated row.

private let monthAbbreviations: [String: Int] = [
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
]
private let monthAlternation = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"

private func pdfIsLeap(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

private func pdfDaysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return pdfIsLeap(year) ? 29 : 28
    default: return 30
    }
}

private func isoOrNil(_ year: Int, _ month: Int, _ day: Int) -> String? {
    guard month >= 1, month <= 12 else { return nil }
    guard day >= 1, day <= pdfDaysInMonth(year, month) else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func pdfFullYear(_ twoDigit: Int) -> Int {
    twoDigit < 70 ? 2000 + twoDigit : 1900 + twoDigit
}

private struct DateToken {
    let range: Range<String.Index>
    let iso: String
}

// Priority order matters: the first pattern below (tried in this order)
// that matches anywhere in the line, and validates as a real calendar
// date, wins.
//
// Bundled into one struct and built once per `parsePdfStatementLines`
// call (passed down as a plain, non-escaping argument) rather than as
// stored globals: Swift 6 strict concurrency treats a global `Regex` as
// unsynchronized mutable state (it isn't `Sendable`), and this repo's
// Swift 6 guard script rejects the usual ways around that restriction.
private struct PdfPatterns {
    let mmddyyyySlash = try! Regex(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#)
    let mmddyyyyDash = try! Regex(#"\b(\d{1,2})-(\d{1,2})-(\d{4})\b"#)
    let mmddyySlash = try! Regex(#"\b(\d{1,2})/(\d{1,2})/(\d{2})\b"#)
    let monthDayCommaYear = try! Regex("(?i)\\b(\(monthAlternation))\\s+(\\d{1,2}),\\s*(\\d{4})\\b")
    let monthDaySpaceYear = try! Regex("(?i)\\b(\(monthAlternation))\\s+(\\d{1,2})\\s+(\\d{4})\\b")
    let mmddNoYear = try! Regex(#"\b(\d{1,2})/(\d{1,2})\b"#)
    let monthDayNoYear = try! Regex("(?i)\\b(\(monthAlternation))\\s+(\\d{1,2})\\b")
    // Optional `$`, digits with optional comma thousands separators, a
    // literal decimal point, exactly two digits; negative when wrapped in
    // parentheses, or immediately adjacent (no space) to a bare `-`
    // before or after. Tried in this order so the more specific negative
    // forms win over the bare positive form at the same starting position.
    let amount = try! Regex(
        #"\(\s*\$?\d+(?:,\d{3})*\.\d{2}\s*\)|-\$?\d+(?:,\d{3})*\.\d{2}|\$?\d+(?:,\d{3})*\.\d{2}-|\$?\d+(?:,\d{3})*\.\d{2}"#
    )
}

private func intCapture(_ match: Regex<AnyRegexOutput>.Match, _ index: Int) -> Int? {
    guard index < match.output.count, let substring = match.output[index].substring else { return nil }
    return Int(substring)
}

private func textCapture(_ match: Regex<AnyRegexOutput>.Match, _ index: Int) -> String? {
    guard index < match.output.count, let substring = match.output[index].substring else { return nil }
    return String(substring)
}

private func findDateToken(in line: String, inferredYear: Int, patterns: PdfPatterns) -> DateToken? {
    if let match = line.firstMatch(of: patterns.mmddyyyySlash),
       let month = intCapture(match, 1), let day = intCapture(match, 2), let year = intCapture(match, 3),
       let iso = isoOrNil(year, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.mmddyyyyDash),
       let month = intCapture(match, 1), let day = intCapture(match, 2), let year = intCapture(match, 3),
       let iso = isoOrNil(year, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.mmddyySlash),
       let month = intCapture(match, 1), let day = intCapture(match, 2), let shortYear = intCapture(match, 3),
       let iso = isoOrNil(pdfFullYear(shortYear), month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.monthDayCommaYear),
       let monthText = textCapture(match, 1), let month = monthAbbreviations[monthText.lowercased()],
       let day = intCapture(match, 2), let year = intCapture(match, 3),
       let iso = isoOrNil(year, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.monthDaySpaceYear),
       let monthText = textCapture(match, 1), let month = monthAbbreviations[monthText.lowercased()],
       let day = intCapture(match, 2), let year = intCapture(match, 3),
       let iso = isoOrNil(year, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.mmddNoYear),
       let month = intCapture(match, 1), let day = intCapture(match, 2),
       let iso = isoOrNil(inferredYear, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    if let match = line.firstMatch(of: patterns.monthDayNoYear),
       let monthText = textCapture(match, 1), let month = monthAbbreviations[monthText.lowercased()],
       let day = intCapture(match, 2),
       let iso = isoOrNil(inferredYear, month, day) {
        return DateToken(range: match.range, iso: iso)
    }
    return nil
}

/// Scans the first ~2000 characters for a 4-digit number in `[2000, 2099]`;
/// that's the default year for any date token found later with no year of
/// its own. Falls back to `fallbackYear` (the caller's injected "today",
/// never a raw wall-clock call) if nothing is found -- a statement
/// spanning a year boundary with no explicit year printed can still
/// mis-attribute dates; that is a known, documented limitation.
public func inferStatementYear(_ text: String, fallbackYear: Int) -> Int {
    let head = String(text.prefix(2000))
    guard let match = head.firstMatch(of: try! Regex(#"\b(20\d{2})\b"#)),
          let yearText = match.output[1].substring,
          let year = Int(yearText)
    else {
        return fallbackYear
    }
    return year
}

/// One date token and one amount token (the first on the line, so an
/// "Amount, then running Balance" column layout is handled correctly) make
/// a row; a line missing either is skipped silently, never fabricated.
/// Multi-line-wrapped descriptions are not stitched together.
public func parsePdfStatementLines(_ lines: [String], inferredYear: Int) -> [ImportRow] {
    let patterns = PdfPatterns()
    var rows: [ImportRow] = []
    for line in lines {
        guard let dateToken = findDateToken(in: line, inferredYear: inferredYear, patterns: patterns) else { continue }
        guard let amountMatch = line.firstMatch(of: patterns.amount),
              let amount = parseImportAmount(String(line[amountMatch.range]))
        else {
            continue
        }

        let dateRange = dateToken.range
        let amountRange = amountMatch.range
        let first = dateRange.lowerBound < amountRange.lowerBound ? dateRange : amountRange
        let second = dateRange.lowerBound < amountRange.lowerBound ? amountRange : dateRange

        var pieces: [Substring] = [line[line.startIndex..<first.lowerBound]]
        if first.upperBound <= second.lowerBound {
            pieces.append(line[first.upperBound..<second.lowerBound])
            pieces.append(line[second.upperBound...])
        } else {
            // Overlapping ranges shouldn't normally happen (a date token and
            // an amount token can't share characters); fall back to
            // dropping from the earliest start to the latest end.
            pieces.append(line[max(first.upperBound, second.upperBound)...])
        }

        let payee = pieces.joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        rows.append(ImportRow(date: dateToken.iso, amount: amount, payee: String(payee.prefix(200))))
    }
    return rows
}

/// Entry point for the PDF import path: `text` is the full, already
/// extracted statement text (every page's `PDFPage.string`, concatenated
/// in page order). Blank extraction means a scanned/image PDF -- OCR is
/// out of scope, so this throws the same way a corrupt QIF/OFX/CSV file
/// would, with a message the UI can show as-is.
public func parsePdfStatementText(_ text: String, fallbackYear: Int) throws -> ImportResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ImportFormatError("This looks like a scanned image, not a text PDF — OCR isn't supported yet.")
    }
    let year = inferStatementYear(text, fallbackYear: fallbackYear)
    let lines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let rows = parsePdfStatementLines(lines, inferredYear: year)
    let warning =
        "Experimental PDF import: \(rows.count) transaction-like line(s) found. Review every row carefully before importing."
    return ImportResult(source: .pdf, rows: rows, warnings: [warning])
}
