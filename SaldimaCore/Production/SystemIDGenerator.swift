// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Production GUID source. This file is the one allowed place in `SaldimaCore`
/// to mint UUIDs; the seam guard enforces it.
public final class SystemIDGenerator: IDGenerator {
    private let provider: @Sendable () -> UUID

    public init(uuid: @escaping @Sendable () -> UUID = { UUID() }) {
        self.provider = uuid
    }

    public func guid() -> Guid {
        let raw = provider().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard let guid = Guid(raw) else {
            preconditionFailure("UUID produced an invalid GnuCash GUID")
        }
        return guid
    }
}
