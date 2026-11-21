// SPDX-License-Identifier: AGPL-3.0-only

/// The only way product code mints GUIDs. Tests inject `SeededIDGenerator`.
public protocol IDGenerator: Sendable {
    func guid() -> Guid
}
