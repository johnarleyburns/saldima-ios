// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct RootTabView: View {
    @State private var session = BookSession()

    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "building.columns") {
                AccountsView(session: session)
            }
            Tab("Register", systemImage: "list.bullet.rectangle") {
                RegisterView()
            }
            Tab("Receipts", systemImage: "doc.viewfinder") {
                ReceiptsView()
            }
            Tab("Reports", systemImage: "chart.bar") {
                ReportsView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(session: session)
            }
        }
        .task {
            await session.openDefaultBook()
        }
    }
}

#Preview {
    RootTabView()
}
