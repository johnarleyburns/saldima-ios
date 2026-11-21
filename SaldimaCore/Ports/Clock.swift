// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The only way product code learns the time. Tests inject `ManualClock`.
public protocol Clock: Sendable {
    func now() -> Date
}

public enum ClockError: Error, Equatable, Sendable {
    case negativeAdvance
}
