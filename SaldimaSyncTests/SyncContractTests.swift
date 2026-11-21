// SPDX-License-Identifier: AGPL-3.0-only
import Testing

@testable import SaldimaSync
@testable import SaldimaTestKit

@Suite("Sync contract placeholder")
struct SyncContractTests {
    @Test("uses the versioned API prefix")
    func apiPrefix() {
        #expect(SyncContract.apiPrefix == "/api/v1")
    }

    @Test("testkit builds")
    func testkitBuilds() {
        #expect(SaldimaTestKit.version == "0.0.0")
    }
}
