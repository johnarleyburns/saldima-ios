// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One account's register as a flat row, ready to write out as QIF or CSV
/// -- the mirror of `packages/importers`' `ImportRow` on the web track, so
/// a file exported here reads back in there (and vice versa). Pure: no
/// Foundation date/number formatting, so it's directly unit-testable.
public struct RegisterExportRow: Sendable, Hashable {
    public let date: String
    public let amount: Money
    public let payee: String
    public let memo: String
    public let category: String

    public init(date: String, amount: Money, payee: String, memo: String, category: String) {
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.category = category
    }
}

/// Builds one account's register rows from the book's transactions, the
/// same convention desktop GnuCash's own QIF export uses for a two-split
/// transaction: the other split becomes the "category", or "Split
/// Transaction" when there's more than one.
public func registerExportRows(
    transactions: [StoredTransaction],
    accountNames: [Guid: String],
    accountGuid: Guid
) -> [RegisterExportRow] {
    var rows: [RegisterExportRow] = []
    for transaction in transactions {
        let mine = transaction.splits.filter { $0.accountGuid == accountGuid }
        guard !mine.isEmpty else { continue }
        let others = transaction.splits.filter { $0.accountGuid != accountGuid }
        let category: String
        if others.count == 1, let only = others.first {
            category = accountNames[only.accountGuid] ?? ""
        } else {
            category = "Split Transaction"
        }
        for split in mine {
            rows.append(
                RegisterExportRow(
                    date: String(transaction.date.prefix(10)),
                    amount: split.value,
                    payee: transaction.description,
                    memo: split.memo,
                    category: category
                )
            )
        }
    }
    return rows.sorted { $0.date < $1.date }
}

/// Writes a register's rows as a `!Type:Bank` QIF file, the same format
/// `packages/importers`' `serializeQif` writes on the web track.
public func serializeQif(_ rows: [RegisterExportRow]) throws -> String {
    var lines = ["!Type:Bank"]
    for row in rows {
        lines.append("D\(row.date)")
        lines.append("T\(try row.amount.formatted(fraction: 100))")
        if !row.payee.isEmpty { lines.append("P\(row.payee)") }
        if !row.memo.isEmpty { lines.append("M\(row.memo)") }
        if !row.category.isEmpty { lines.append("L\(row.category)") }
        lines.append("^")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func escapeCsvCell(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

/// Writes a register's rows with the same CSV headers `packages/importers`'
/// `serializeCsv` writes on the web track.
public func serializeCsv(_ rows: [RegisterExportRow]) throws -> String {
    var lines = ["Date,Description,Memo,Amount,Category"]
    for row in rows {
        let cells = [row.date, row.payee, row.memo, try row.amount.formatted(fraction: 100), row.category]
        lines.append(cells.map(escapeCsvCell).joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
}

/// A safe, extension-free filename stem from an account name.
public func registerExportFilename(accountName: String, extension fileExtension: String) -> String {
    let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = trimmed.map { character -> Character in
        character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
            ? character
            : "-"
    }
    var collapsed = ""
    var lastWasDash = false
    for character in safe {
        if character == "-" {
            if !lastWasDash { collapsed.append(character) }
            lastWasDash = true
        } else {
            collapsed.append(character)
            lastWasDash = false
        }
    }
    let stem = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "\(stem.isEmpty ? "account" : stem).\(fileExtension)"
}
