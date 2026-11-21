// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore

@Suite("AGPL source offer")
struct SourceOfferTests {
    @Test("links the commit this build came from")
    func commitLink() {
        #expect(
            SourceOffer.url(commit: "abc123").absoluteString
                == "https://github.com/johnarleyburns/saldima-ios/tree/abc123"
        )
    }

    @Test("falls back to the repository when no commit was baked in")
    func fallback() {
        #expect(SourceOffer.url(commit: "") == SourceOffer.repository)
        #expect(SourceOffer.url(commit: "  ") == SourceOffer.repository)
        #expect(SourceOffer.url(commit: "main") == SourceOffer.repository)
    }
}
