// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.system(size: 56))
                    .accessibilityHidden(true)
                Text("Saldima")
                    .font(.largeTitle.bold())
                Text("Compatible with GnuCash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("Saldima")
        }
    }
}

#Preview {
    RootView()
}
