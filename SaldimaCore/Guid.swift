// SPDX-License-Identifier: AGPL-3.0-only

/// A GnuCash GUID: exactly 32 lowercase hexadecimal characters.
public struct Guid: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard rawValue.utf8.count == 32 else { return nil }
        let isLowercaseHex = rawValue.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
        guard isLowercaseHex else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
