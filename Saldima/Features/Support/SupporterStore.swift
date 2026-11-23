// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import StoreKit

import SaldimaCore

/// StoreKit 2 adapter for the optional one-time Supporter consumable.
/// This is the only file in the app that imports StoreKit.
@MainActor
final class SupporterStore {
    static let shared = SupporterStore()

    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == SupporterProduct.id {
                    self.markSupporter()
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProduct() async throws -> Product {
        if let product { return product }
        let products = try await Product.products(for: [SupporterProduct.id])
        guard let product = products.first else { throw SupporterError.notAvailable }
        self.product = product
        return product
    }

    func purchase() async throws -> SupporterPurchaseResult {
        let product = try await loadProduct()
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw SupporterError.unverified
            }
            markSupporter()
            await transaction.finish()
            return .purchased
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    private func markSupporter() {
        UserDefaults.standard.set(true, forKey: AppPreferences.isSupporter)
    }
}

enum SupporterError: Error {
    case notAvailable
    case unverified
}

private enum AppPreferences {
    static let isSupporter = "saldima.isSupporter"
}
