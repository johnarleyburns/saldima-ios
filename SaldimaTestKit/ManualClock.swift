// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Synchronization

import SaldimaCore

/// Deterministic clock. Nothing moves until the test calls `advance(by:)` or
/// `set(_:)`.
public final class ManualClock: Clock {
    private let state: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        self.state = Mutex(start)
    }

    public func now() -> Date {
        state.withLock { $0 }
    }

    public func advance(by seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw ClockError.negativeAdvance
        }
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    public func set(_ date: Date) {
        state.withLock { $0 = date }
    }
}
