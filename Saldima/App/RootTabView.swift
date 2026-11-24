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
            Tab("Register", systemImage: "list.bullet.rectangle") {
                RegisterView(session: session)
            }
            Tab("Receipts", systemImage: "doc.viewfinder") {
                ReceiptsView()
            }
            Tab("Reports", systemImage: "chart.bar") {
                ReportsView(session: session)
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(session: session)
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
