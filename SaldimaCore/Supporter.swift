// SPDX-License-Identifier: AGPL-3.0-only

public enum SupporterProduct {
    /// One-time, optional consumable. It never gates a feature.
    public static let id = "guru.parso.saldima.support.dev"
    public static let displayName = "Supporter"
}

public enum SupporterPurchaseResult: Sendable, Equatable {
    case purchased
    case cancelled
    case pending
}

public protocol SupporterPurchasing: Sendable {
    func purchase() async throws -> SupporterPurchaseResult
}

public protocol SupporterFlags: Sendable {
    func isSupporter() -> Bool
    func markSupporter()
}

/// Pure purchase policy: only a verified purchase flips the one-way flag.
public final class SupporterController: Sendable {
    private let purchasing: any SupporterPurchasing
    private let flags: any SupporterFlags

    public init(purchasing: any SupporterPurchasing, flags: any SupporterFlags) {
        self.purchasing = purchasing
        self.flags = flags
    }

    @discardableResult
    public func purchase() async throws -> SupporterPurchaseResult {
        let result = try await purchasing.purchase()
        if result == .purchased {
            flags.markSupporter()
        }
        return result
    }

    public var isSupporter: Bool {
        flags.isSupporter()
    }
}
