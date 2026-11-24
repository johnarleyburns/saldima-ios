// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

struct SupporterCard: View {
    @AppStorage("saldima.isSupporter") private var isSupporter = false
    @State private var isPurchasing = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await purchase() }
            } label: {
                Label(
                    isSupporter ? "Thanks for supporting Saldima" : "Become a Supporter",
                    systemImage: isSupporter ? "heart.fill" : "heart"
                )
            }
            .buttonStyle(.glass)
            .disabled(isPurchasing)
            .accessibilityIdentifier("settings.supporter")

            Text(
                isSupporter
                    ? "You have the Supporter badge. Every feature stays free."
                    : "A one-time purchase. Every feature is already free; this only adds a thank-you badge."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let message {
                Text(message).font(.footnote)
            }
        }
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await SupporterStore.shared.purchase() {
            case .purchased:
                message = "Thank you for supporting Saldima."
            case .cancelled:
                message = "No purchase was made."
            case .pending:
                message = "The purchase is pending approval."
            }
        } catch {
            message = "Purchase failed: \(error.localizedDescription)"
        }
    }
}
