// SPDX-License-Identifier: AGPL-3.0-only

/// Ported from the web track's `packages/importers/src/qif.ts` (parsing
/// only; QIF *export* already exists as `RegisterExport.swift`'s
/// `serializeQif`, over the unrelated `RegisterExportRow` shape).

private struct QifRecord {
    var date = ""
    var amount: Money?
    var payee = ""
    var memo = ""
    var reference = ""
    var category = ""
    var splits: [ImportSplit] = []
    var warnings: [String] = []
}

private struct QifSplitInProgress {
    var category: String
    var amount: Money?
}

private func finishSplit(_ record: inout QifRecord, _ split: QifSplitInProgress?) {
    guard let split else { return }
    guard let amount = split.amount else {
        record.warnings.append("record: split \"\(split.category)\" has no amount")
        return
    }
    record.splits.append(ImportSplit(category: split.category, amount: amount))
}

public func parseQif(_ text: String) throws -> ImportResult {
    var rows: [ImportRow] = []
    var warnings: [String] = []
    var record = QifRecord()
    var recordNumber = 1
    var split: QifSplitInProgress?

    func finish() {
        for warning in record.warnings {
            warnings.append("record \(recordNumber): \(warning)")
        }
        if let date = parseImportDate(record.date) {
            if let amount = record.amount {
                if amount == Money.zero {
                    warnings.append("record \(recordNumber): skipped (zero amount)")
                } else {
                    rows.append(
                        ImportRow(
                            date: date,
                            amount: amount,
                            payee: record.payee,
                            memo: record.memo,
                            reference: record.reference,
                            category: record.category,
                            splits: record.splits
                        )
                    )
                }
            } else {
                warnings.append("record \(recordNumber): skipped (no valid amount)")
            }
        } else {
            warnings.append("record \(recordNumber): skipped (no valid date)")
        }
        recordNumber += 1
        record = QifRecord()
        split = nil
    }

    let normalised = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    for rawSubstring in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
        let raw = String(rawSubstring)
        if raw.hasPrefix("!") || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continue
        }
        let value = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.hasPrefix("^") {
            finishSplit(&record, split)
            finish()
            continue
        }
        if raw.hasPrefix("S") {
            finishSplit(&record, split)
            split = QifSplitInProgress(category: value, amount: nil)
            continue
        }
        if raw.hasPrefix("$") {
            if split == nil {
                record.warnings.append("record: split amount without a category")
            } else {
                split?.amount = parseImportAmount(value)
            }
            continue
        }
        if raw.hasPrefix("D") { record.date = value }
        else if raw.hasPrefix("T") { record.amount = parseImportAmount(value) }
        else if raw.hasPrefix("P") { record.payee = value }
        else if raw.hasPrefix("M") { record.memo = value }
        else if raw.hasPrefix("N") { record.reference = value }
        else if raw.hasPrefix("L") { record.category = value }
    }

    // A final record without the `^` terminator is still a record.
    if !record.date.isEmpty || record.amount != nil || !record.payee.isEmpty {
        finishSplit(&record, split)
        finish()
    }

    guard !rows.isEmpty else { throw ImportFormatError("No QIF transactions found.") }
    return ImportResult(source: .qif, rows: rows, warnings: warnings)
}
