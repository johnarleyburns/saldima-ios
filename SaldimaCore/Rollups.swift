// SPDX-License-Identifier: AGPL-3.0-only

public enum AccountRollup {
    /// GnuCash shows a parent's balance as its own balance plus every
    /// descendant, and leaves as their own balance. This returns both.
    public static func totals(
        _ accounts: [Account],
        balances: [Guid: Money]
    ) throws -> [Guid: Money] {
        var totals: [Guid: Money] = [:]
        func walk(_ node: Account) throws -> Money {
            var total = balances[node.guid] ?? .zero
            for child in node.children {
                total = try Money.add(total, walk(child))
            }
            totals[node.guid] = total
            return total
        }
        for root in accounts {
            _ = try walk(root)
        }
        return totals
    }
}
