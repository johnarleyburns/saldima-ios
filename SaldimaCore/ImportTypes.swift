// SPDX-License-Identifier: AGPL-3.0-only

/// Ported from the web track's `packages/importers/src/types.ts`, plus a
/// `pdf` source the web track doesn't have -- this milestone's mobile-only
/// statement importer (`ImportPdf.swift`) accepts PDF statements that web's
/// own importer never had to.
public enum ImportSource: String, Sendable, Hashable, CaseIterable {
    case qif
    case csv
    case ofx
    case pdf
}

/// One category split within a CSV-style multi-category row.
public struct ImportSplit: Sendable, Hashable {
    public let category: String
    public let amount: Money

    public init(category: String, amount: Money) {
        self.category = category
        self.amount = amount
    }
}

/// One statement line, ready to map onto book accounts via `planImport`.
/// `amount` is the statement amount: positive increases the target
/// (statement) account, exactly as the web type's own doc comment states.
/// `splits` is only non-empty for CSV-style multi-category rows -- QIF,
/// OFX and PDF rows never populate it.
public struct ImportRow: Sendable, Hashable {
    public let date: String
    public let amount: Money
    public let payee: String
    public let memo: String
    public let reference: String
    public let category: String
    public let splits: [ImportSplit]

    public init(
        date: String,
        amount: Money,
        payee: String = "",
        memo: String = "",
        reference: String = "",
        category: String = "",
        splits: [ImportSplit] = []
    ) {
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.reference = reference
        self.category = category
        self.splits = splits
    }
}

/// A finished parse: the rows found, plus any warnings about lines/records
/// that were skipped (never silently fabricated).
public struct ImportResult: Sendable {
    public let source: ImportSource
    public let rows: [ImportRow]
    public let warnings: [String]

    public init(source: ImportSource, rows: [ImportRow], warnings: [String]) {
        self.source = source
        self.rows = rows
        self.warnings = warnings
    }
}

/// A statement file (or extracted PDF text) that can't be read at all as
/// the detected or requested format.
public struct ImportFormatError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
