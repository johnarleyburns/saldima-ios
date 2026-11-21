// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct EmptyFeatureView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            }
            .navigationTitle(title)
        }
    }
}
