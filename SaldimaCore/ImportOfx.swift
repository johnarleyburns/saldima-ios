// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Ported from the web track's `packages/importers/src/ofx.ts`. Reads both
/// OFX 1.x SGML (unclosed tags) and OFX 2.x XML statements.

private func clean(_ value: String) -> String {
    var withoutTags = ""
    var insideTag = false
    for character in value {
        if character == "<" {
            insideTag = true
            withoutTags.append(" ")
            continue
        }
        if character == ">" {
            insideTag = false
            continue
        }
        if !insideTag { withoutTags.append(character) }
    }
    return withoutTags.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func field(_ block: String, _ name: String) -> String {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    if let regex = try? Regex("<\(escapedName)\\b[^>]*>([\\s\\S]*?)</\(escapedName)>").ignoresCase(),
       let match = block.firstMatch(of: regex),
       let captured = match.output[1].substring {
        return clean(String(captured))
    }
    if let regex = try? Regex("<\(escapedName)\\b[^>]*>([^<\\r\\n]*)").ignoresCase(),
       let match = block.firstMatch(of: regex),
       let captured = match.output[1].substring {
        return clean(String(captured))
    }
    return ""
}

private func statementBlocks(_ text: String) -> [String] {
    // Built locally, not as stored globals -- see the note in
    // `ImportDate.swift`'s `parseImportDate`.
    let stmtTrnMarker = try! Regex(#"<STMTTRN\b[^>]*>"#).ignoresCase()
    let stmtTrnCloser = try! Regex(#"</STMTTRN>"#).ignoresCase()

    var starts: [String.Index] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex, let match = text[searchStart...].firstMatch(of: stmtTrnMarker) {
        starts.append(match.range.upperBound)
        searchStart = match.range.upperBound
    }
    return starts.enumerated().map { index, start in
        let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
        let block = String(text[start..<end])
        return block.replacing(stmtTrnCloser, with: "")
    }
}

/// `OFXHEADER` (SGML) or an `<OFX` root element (XML) within the first
/// 4096 characters.
public func isOfx(_ text: String) -> Bool {
    let head = String(text.prefix(4096))
    let lowered = head.lowercased()
    if lowered.contains("ofxheader") { return true }
    var searchRange = lowered.startIndex..<lowered.endIndex
    while let range = lowered.range(of: "<ofx", range: searchRange) {
        if let next = lowered[range.upperBound...].first, next.isWhitespace || next == ">" {
            return true
        }
        searchRange = range.upperBound..<lowered.endIndex
    }
    return false
}

public func parseOfx(_ text: String) throws -> ImportResult {
    let blocks = statementBlocks(text)
    guard !blocks.isEmpty else { throw ImportFormatError("No OFX transactions found.") }

    var rows: [ImportRow] = []
    var warnings: [String] = []

    for (index, block) in blocks.enumerated() {
        guard let date = parseImportDate(field(block, "DTPOSTED")) else {
            warnings.append("transaction \(index + 1): skipped (invalid date)")
            continue
        }
        guard let amount = parseImportAmount(field(block, "TRNAMT")) else {
            warnings.append("transaction \(index + 1): skipped (invalid amount)")
            continue
        }
        if amount == Money.zero {
            warnings.append("transaction \(index + 1): skipped (zero amount)")
            continue
        }
        let name = field(block, "NAME")
        let fitid = field(block, "FITID")
        rows.append(
            ImportRow(
                date: date,
                amount: amount,
                payee: name.isEmpty ? field(block, "PAYEE") : name,
                memo: field(block, "MEMO"),
                reference: fitid.isEmpty ? field(block, "CHECKNUM") : fitid,
                category: field(block, "CATEGORY")
            )
        )
    }

    guard !rows.isEmpty else { throw ImportFormatError("No usable OFX transactions found.") }
    return ImportResult(source: .ofx, rows: rows, warnings: warnings)
}
