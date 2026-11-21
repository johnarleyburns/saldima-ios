// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct AccountsView: View {
    var body: some View {
        EmptyFeatureView(
            title: "Accounts",
            message: "Open a .gnucash book to see its account tree.",
            systemImage: "building.columns"
        )
    }
}
