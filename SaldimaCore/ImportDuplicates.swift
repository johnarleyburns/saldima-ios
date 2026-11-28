// SPDX-License-Identifier: AGPL-3.0-only

/// Ported from the web track's `packages/importers/src/duplicates.ts`. The
/// same purchase entered twice usually has different GUIDs but the same
/// account, amount and a date within three days. Day-math reuses
/// `Recurrence.swift`'s own `daysBetween` (the scheduled-transactions
/// port's day-counting code) rather than a second copy.

/// An existing posted split on the target account, for duplicate matching.
public struct ExistingEntry: Sendable, Hashable {
    public let date: String
    public let amount: Money

    public init(date: String, amount: Money) {
        self.date = date
        self.amount = amount
    }
}

public func isLikelyDuplicate(
    date: String,
    amount: Money,
    existing: [ExistingEntry],
    windowDays: Int = 3
) -> Bool {
    existing.contains { entry in
        guard amount.normalized() == entry.amount.normalized() else { return false }
        guard let distance = try? daysBetween(date, entry.date) else { return false }
        return distance <= windowDays
    }
}

public func isLikelyDuplicate(
    _ candidate: ImportRow,
    existing: [ExistingEntry],
    windowDays: Int = 3
) -> Bool {
    isLikelyDuplicate(date: candidate.date, amount: candidate.amount, existing: existing, windowDays: windowDays)
}
