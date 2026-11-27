// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct RootTabView: View {
    @State private var session = BookSession()
    @AppStorage(ThemeKeys.accent) private var accentRaw = AccentChoice.indigo.rawValue
    @AppStorage(ThemeKeys.appearance) private var appearanceRaw = AppearanceChoice.system.rawValue

    private var accent: AccentChoice {
        AccentChoice(rawValue: accentRaw) ?? .indigo
    }

    private var appearance: AppearanceChoice {
        AppearanceChoice(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "building.columns") {
                AccountsView(session: session)
            }
            Tab("Invoices", systemImage: "doc.text") {
                InvoicesView(session: session)
            }
            Tab("Bills", systemImage: "truck.box") {
                BillsView(session: session)
            }
            Tab("Receipts", systemImage: "doc.viewfinder") {
                ReceiptsView(session: session)
            }
        }
        .tint(accent.color)
        .preferredColorScheme(appearance.scheme)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await session.openDefaultBook()
        }
    }
}

#Preview {
    RootTabView()
}
