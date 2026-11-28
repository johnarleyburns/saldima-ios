// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Ported from the web track's `packages/importers/src/csv.ts` (parsing
/// only; CSV *export* already exists as `RegisterExport.swift`'s
/// `serializeCsv`, over the unrelated `RegisterExportRow` shape).

public struct CsvColumnMap: Sendable, Hashable {
    public let dateIndex: Int
    public let descriptionIndex: Int
    public let valueIndex: Int?
    public let outflowIndex: Int?
    public let inflowIndex: Int?
    public let categoryIndex: Int?
    public let referenceIndex: Int?

    public init(
        dateIndex: Int,
        descriptionIndex: Int,
        valueIndex: Int?,
        outflowIndex: Int?,
        inflowIndex: Int?,
        categoryIndex: Int?,
        referenceIndex: Int?
    ) {
        self.dateIndex = dateIndex
        self.descriptionIndex = descriptionIndex
        self.valueIndex = valueIndex
        self.outflowIndex = outflowIndex
        self.inflowIndex = inflowIndex
        self.categoryIndex = categoryIndex
        self.referenceIndex = referenceIndex
    }
}

public struct CsvTable: Sendable {
    public let header: [String]
    public let rows: [[String]]
    public let delimiter: Character
}

private let csvDelimiters: [Character] = [",", ";", "\t", "|"]

private let dateNames = ["date", "posted", "postdate", "transactiondate", "bookingdate", "valuedate", "datum"]
private let descriptionNames = ["description", "payee", "name", "details", "narrative", "merchant", "memo"]
private let valueNames = ["amount", "value", "transactionamount", "amountusd", "amt"]
private let outflowNames = ["debit", "debitamount", "withdrawal", "withdrawals", "moneyout", "paidout", "outflow"]
private let inflowNames = ["credit", "creditamount", "deposit", "deposits", "moneyin", "paidin", "inflow"]
private let categoryNames = ["category", "type", "classification", "class"]
private let referenceNames = [
    "reference", "ref", "checknumber", "checkno", "check", "fitid", "transactionid", "id",
]

private func normaliseHeader(_ value: String) -> String {
    var trimmed = value
    if trimmed.first == "\u{FEFF}" { trimmed.removeFirst() }
    return trimmed.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

// Both the delimiter/quote scan below and `scan()` itself walk Unicode
// *scalars*, not `Character`s: Swift's `Character` is an extended grapheme
// cluster, and a bare CR+LF pair is defined to be a *single* grapheme
// cluster -- so a `[Character]` walk would see one opaque "\r\n" element
// that matches neither the `\r`-drop branch nor the `\n`-row-break branch
// below, silently swallowing every line break in a CRLF file. Scalars
// don't merge like that, matching the web source's own UTF-16-code-unit
// (never-merged) semantics for plain ASCII line endings.

private func countOutsideQuotes(_ line: [Unicode.Scalar], _ delimiter: Unicode.Scalar) -> Int {
    var count = 0
    var quoted = false
    var index = 0
    while index < line.count {
        let character = line[index]
        if character == "\"" {
            if quoted, index + 1 < line.count, line[index + 1] == "\"" {
                index += 1
            } else {
                quoted.toggle()
            }
        } else if !quoted, character == delimiter {
            count += 1
        }
        index += 1
    }
    return count
}

private func firstNonBlankLine(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var lineStart = 0
    var index = 0
    while index <= scalars.count {
        if index == scalars.count || scalars[index] == "\n" {
            let line = Array(scalars[lineStart..<index])
            if line.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return line
            }
            if index == scalars.count { break }
            lineStart = index + 1
        }
        index += 1
    }
    return []
}

private func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
    let line = firstNonBlankLine(scalars)
    var best: Unicode.Scalar = ","
    var bestCount = 0
    for delimiter in csvDelimiters {
        let scalar = delimiter.unicodeScalars.first!
        let count = countOutsideQuotes(line, scalar)
        if count > bestCount {
            best = scalar
            bestCount = count
        }
    }
    return best
}

private func scan(_ scalars: [Unicode.Scalar], _ delimiter: Unicode.Scalar) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var cell = ""
    var quoted = false
    var index = 0
    while index < scalars.count {
        let character = scalars[index]
        if quoted {
            if character == "\"" {
                if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                    cell.unicodeScalars.append("\"")
                    index += 1
                } else {
                    quoted = false
                }
            } else {
                cell.unicodeScalars.append(character)
            }
        } else if character == "\"" {
            quoted = true
        } else if character == delimiter {
            row.append(cell)
            cell = ""
        } else if character == "\n" {
            row.append(cell)
            rows.append(row)
            row = []
            cell = ""
        } else if character != "\r" {
            cell.unicodeScalars.append(character)
        }
        index += 1
    }
    if !cell.isEmpty || !row.isEmpty {
        row.append(cell)
        rows.append(row)
    }
    return rows.filter { candidate in candidate.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

public func parseCsvTable(_ text: String) -> CsvTable {
    let scalars = Array(text.unicodeScalars)
    let delimiterScalar = detectDelimiter(scalars)
    let rows = scan(scalars, delimiterScalar)
    let header = (rows.first ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return CsvTable(header: header, rows: Array(rows.dropFirst()), delimiter: Character(delimiterScalar))
}

private func findColumn(_ header: [String], _ names: [String], _ claimed: Set<Int>) -> Int? {
    let normalised = header.map(normaliseHeader)
    if let exact = normalised.indices.first(where: { !claimed.contains($0) && names.contains(normalised[$0]) }) {
        return exact
    }
    return normalised.indices.first { index in
        !claimed.contains(index) && names.contains { normalised[index].contains($0) }
    }
}

private func columnsDescription(_ header: [String]) -> String {
    let joined = header.joined(separator: ", ")
    return joined.isEmpty ? "(none)" : joined
}

/// Detects the common bank CSV shapes; throws when the table is unusable.
public func detectCsvMap(_ header: [String]) throws -> CsvColumnMap {
    var claimed: Set<Int> = []
    func take(_ names: [String]) -> Int? {
        guard let found = findColumn(header, names, claimed) else { return nil }
        claimed.insert(found)
        return found
    }

    let dateIndex = take(dateNames)
    var descriptionIndex = take(descriptionNames)
    if descriptionIndex == nil {
        if let fallback = header.indices.first(where: { !claimed.contains($0) }) {
            descriptionIndex = fallback
            claimed.insert(fallback)
        } else {
            descriptionIndex = 0
        }
    }
    let valueIndex = take(valueNames)
    let outflowIndex = take(outflowNames)
    let inflowIndex = take(inflowNames)
    let categoryIndex = take(categoryNames)
    let referenceIndex = take(referenceNames)

    guard let dateIndex else {
        throw ImportFormatError("No date column found. Columns: \(columnsDescription(header)).")
    }
    guard valueIndex != nil || outflowIndex != nil || inflowIndex != nil else {
        throw ImportFormatError("No amount, debit or credit column found. Columns: \(columnsDescription(header)).")
    }

    return CsvColumnMap(
        dateIndex: dateIndex,
        descriptionIndex: descriptionIndex ?? 0,
        valueIndex: valueIndex,
        outflowIndex: outflowIndex,
        inflowIndex: inflowIndex,
        categoryIndex: categoryIndex,
        referenceIndex: referenceIndex
    )
}

private func cell(_ row: [String], _ index: Int?) -> String {
    guard let index, index >= 0, index < row.count else { return "" }
    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
}

public func parseCsv(_ text: String, map: CsvColumnMap? = nil) throws -> ImportResult {
    let table = parseCsvTable(text)
    guard !table.header.isEmpty else { throw ImportFormatError("The CSV file is empty.") }
    let columns = try map ?? detectCsvMap(table.header)

    var rows: [ImportRow] = []
    var warnings: [String] = []

    for (offset, row) in table.rows.enumerated() {
        let line = offset + 2
        guard let date = parseImportDate(cell(row, columns.dateIndex)) else {
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                warnings.append("row \(line): skipped (invalid date)")
            }
            continue
        }

        var amount: Money?
        if let valueIndex = columns.valueIndex {
            amount = parseImportAmount(cell(row, valueIndex))
        } else {
            let outflowText = cell(row, columns.outflowIndex)
            let inflowText = cell(row, columns.inflowIndex)
            let outAmount = outflowText.isEmpty ? nil : parseImportAmount(outflowText)
            let inAmount = inflowText.isEmpty ? nil : parseImportAmount(inflowText)
            if !outflowText.isEmpty, outAmount == nil {
                warnings.append("row \(line): skipped (invalid debit)")
                continue
            }
            if !inflowText.isEmpty, inAmount == nil {
                warnings.append("row \(line): skipped (invalid credit)")
                continue
            }
            if outflowText.isEmpty, inflowText.isEmpty {
                amount = nil
            } else {
                amount = try? Money.add(inAmount ?? Money.zero, (outAmount ?? Money.zero).negated())
            }
        }

        guard let amount else {
            warnings.append("row \(line): skipped (invalid amount)")
            continue
        }
        if amount == Money.zero {
            warnings.append("row \(line): skipped (zero amount)")
            continue
        }

        rows.append(
            ImportRow(
                date: date,
                amount: amount,
                payee: cell(row, columns.descriptionIndex),
                memo: "",
                reference: cell(row, columns.referenceIndex),
                category: cell(row, columns.categoryIndex)
            )
        )
    }

    guard !rows.isEmpty else { throw ImportFormatError("No usable CSV transactions found.") }
    return ImportResult(source: .csv, rows: rows, warnings: warnings)
}
