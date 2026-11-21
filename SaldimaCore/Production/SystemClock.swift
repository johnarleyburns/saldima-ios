// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Production clock. This file is the one allowed place in `SaldimaCore` to
/// read the wall clock; the seam guard enforces it.
public final class SystemClock: Clock {
    private let provider: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = now
    }

    public func now() -> Date {
        provider()
    }
}
