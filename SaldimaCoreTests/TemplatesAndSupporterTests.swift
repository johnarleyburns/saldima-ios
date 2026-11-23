// SPDX-License-Identifier: AGPL-3.0-only
import Synchronization
import Testing

@testable import SaldimaCore

@Suite("Book templates")
struct TemplateTests {
    @Test("all three templates have unique paths and valid types")
    func templates() {
        #expect(BookTemplates.all.map(\.id) == ["personal", "small-business", "insurance-agency"])
        for template in BookTemplates.all {
            let rows = BookTemplates.flatten(template)
            #expect(Set(rows.map(\.path)).count == rows.count)
            #expect(rows.allSatisfy { !$0.name.isEmpty })
        }
        let paths = BookTemplates.flatten(BookTemplates.insuranceAgency).map(\.path)
        #expect(paths.contains("Assets/Trust/Premium Trust"))
        #expect(paths.contains("Expenses/E&O Insurance"))
    }
}

private final class FakePurchasing: SupporterPurchasing {
    private let resultBox = Mutex<SupporterPurchaseResult>(.purchased)
    private let callsBox = Mutex<Int>(0)

    var result: SupporterPurchaseResult {
        get { resultBox.withLock { $0 } }
        set { resultBox.withLock { $0 = newValue } }
    }

    var calls: Int { callsBox.withLock { $0 } }

    func purchase() async throws -> SupporterPurchaseResult {
        callsBox.withLock { $0 += 1 }
        return resultBox.withLock { $0 }
    }
}

private final class FakeFlags: SupporterFlags {
    private let valueBox = Mutex<Bool>(false)
    func isSupporter() -> Bool { valueBox.withLock { $0 } }
    func markSupporter() { valueBox.withLock { $0 = true } }
}

@Suite("Supporter policy")
struct SupporterTests {
    @Test("a verified purchase sets the one-way flag")
    func purchaseSetsFlag() async throws {
        let purchasing = FakePurchasing()
        let flags = FakeFlags()
        let controller = SupporterController(purchasing: purchasing, flags: flags)
        #expect(!controller.isSupporter)
        #expect(try await controller.purchase() == .purchased)
        #expect(controller.isSupporter)
        #expect(purchasing.calls == 1)
    }

    @Test("cancel and pending never set the flag")
    func noFlagWithoutPurchase() async throws {
        let purchasing = FakePurchasing()
        let flags = FakeFlags()
        let controller = SupporterController(purchasing: purchasing, flags: flags)
        purchasing.result = .cancelled
        #expect(try await controller.purchase() == .cancelled)
        #expect(!controller.isSupporter)
        purchasing.result = .pending
        #expect(try await controller.purchase() == .pending)
        #expect(!controller.isSupporter)
    }

    @Test("the product is one-time and never a subscription")
    func productID() {
        #expect(SupporterProduct.id == "guru.parso.saldima.support.dev")
        #expect(SupporterProduct.displayName == "Supporter")
    }
}
