// SPDX-License-Identifier: AGPL-3.0-only
import Synchronization

import SaldimaCore

/// Deterministic 32-hex GUIDs. Never use outside tests.
public final class SeededIDGenerator: IDGenerator {
    private let counter: Mutex<UInt64>

    public init(start: UInt64 = 0) {
        self.counter = Mutex(start)
    }

    public func guid() -> Guid {
        let value = counter.withLock { current in
            defer { current &+= 1 }
            return current
        }
        let hex = String(value, radix: 16)
        let padded = String(repeating: "0", count: 32 - hex.count) + hex
        guard let guid = Guid(padded) else {
            preconditionFailure("seeded generator produced an invalid GUID")
        }
        return guid
    }
}
