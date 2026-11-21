// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The AGPL source offer: the About screen links the public repository at the
/// commit this build came from. Builds pass `SALDIMA_SOURCE_COMMIT`.
public enum SourceOffer {
    public static let repository = URL(string: "https://github.com/johnarleyburns/saldima-ios")!

    public static func url(commit: String) -> URL {
        let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "main" else {
            return repository
        }
        return repository
            .appendingPathComponent("tree")
            .appendingPathComponent(trimmed)
    }
}
