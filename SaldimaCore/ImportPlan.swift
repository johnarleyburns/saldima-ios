// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Ported from the web track's `packages/importers/src/plan.ts`. Builds
/// balanced two-or-more-split transactions from statement rows; account
/// identifiers are `Guid` here (the web type uses a plain string since
/// TypeScript has no such distinct type).
public struct ImportMapping: Sendable {
    public let targetAccountGuid: Guid
    public let defaultAccountGuid: Guid
    public let categoryAccounts: [String: Guid]

    public init(targetAccountGuid: Guid, defaultAccountGuid: Guid, categoryAccounts: [String: Guid] = [:]) {
        self.targetAccountGuid = targetAccountGuid
        self.defaultAccountGuid = defaultAccountGuid
        self.categoryAccounts = categoryAccounts
    }
}

public struct PlannedSplit: Sendable, Hashable {
    public let accountGuid: Guid
    public let value: Money
}

public struct PlannedTransaction: Sendable, Hashable {
    public let date: String
    public let description: String
    public let splits: [PlannedSplit]
}

/// QIF writes transfers as `[Savings]`; map either form to the account name.
public func categoryKey(_ category: String) -> String {
    let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.count >= 2, value.hasPrefix("["), value.hasSuffix("]") {
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
}

private func counterGuid(_ category: String, _ mapping: ImportMapping) -> Guid {
    mapping.categoryAccounts[categoryKey(category)] ?? mapping.defaultAccountGuid
}

private func description(for row: ImportRow) -> String {
    let parts = [row.payee, row.memo]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let joined = parts.isEmpty ? "Imported transaction" : parts.joined(separator: " — ")
    return String(joined.prefix(200))
}

/// Builds balanced two-or-more-split transactions from statement rows.
public func planImport(_ rows: [ImportRow], mapping: ImportMapping) throws -> [PlannedTransaction] {
    try rows.map { row in
        var splits: [PlannedSplit] = [PlannedSplit(accountGuid: mapping.targetAccountGuid, value: row.amount)]
        if row.splits.isEmpty {
            splits.append(
                PlannedSplit(accountGuid: counterGuid(row.category, mapping), value: row.amount.negated())
            )
        } else {
            var counterTotal = Money.zero
            for split in row.splits {
                let value = split.amount.negated()
                counterTotal = try Money.add(counterTotal, value)
                splits.append(PlannedSplit(accountGuid: counterGuid(split.category, mapping), value: value))
            }
            let remainder = try Money.add(counterTotal, row.amount)
            if remainder != Money.zero {
                splits.append(PlannedSplit(accountGuid: mapping.defaultAccountGuid, value: remainder.negated()))
            }
        }
        return PlannedTransaction(date: row.date, description: description(for: row), splits: splits)
    }
}
