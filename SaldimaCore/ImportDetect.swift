// SPDX-License-Identifier: AGPL-3.0-only

/// Ported from the web track's `packages/importers/src/detect.ts`.

private func hasQifTypeMarker(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        line.drop(while: \.isWhitespace).lowercased().hasPrefix("!type:")
    }
}

private func hasQifTerminatorLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        var trimmed = line
        if trimmed.last == "\r" { trimmed = trimmed.dropLast() }
        return trimmed == "^"
    }
}

private func isDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
}

private func matchesQifDateLine(_ line: Substring) -> Bool {
    guard line.first == "D" else { return false }
    let rest = line.dropFirst().drop(while: \.isWhitespace)
    guard let first = rest.first else { return false }
    return isDigit(first)
}

private func matchesQifAmountLine(_ line: Substring) -> Bool {
    guard line.first == "T" else { return false }
    var rest = line.dropFirst().drop(while: \.isWhitespace)
    if let first = rest.first, first == "-" || first == "+" || first == "(" {
        rest = rest.dropFirst()
    }
    guard let first = rest.first else { return false }
    return isDigit(first)
}

private func hasQifDateOrAmountLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        matchesQifDateLine(line) || matchesQifAmountLine(line)
    }
}

public func detectImportSource(fileName: String, text: String) -> ImportSource {
    if isOfx(text) { return .ofx }
    if hasQifTypeMarker(text) { return .qif }
    if hasQifTerminatorLine(text) && hasQifDateOrAmountLine(text) { return .qif }
    let extension_ = fileName.lowercased().split(separator: ".").last.map(String.init) ?? ""
    if extension_ == "ofx" || extension_ == "qfx" { return .ofx }
    return .csv
}

/// Entry point for the text-based formats (QIF, OFX, CSV). PDF statements
/// never go through here: PDF text extraction happens in the app target
/// via PDFKit, and the result is handed straight to `parsePdfStatementText`.
public func parseImportFile(fileName: String, text: String) throws -> ImportResult {
    switch detectImportSource(fileName: fileName, text: text) {
    case .qif: return try parseQif(text)
    case .ofx: return try parseOfx(text)
    case .csv: return try parseCsv(text)
    case .pdf:
        // `detectImportSource` never returns `.pdf` -- PDF statements are
        // bytes, not decoded text, and are routed to
        // `parsePdfStatementText` by the caller before reaching here.
        throw ImportFormatError("PDF statements must be parsed with parsePdfStatementText.")
    }
}
