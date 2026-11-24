// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// User-selectable accent. GnuCash users are used to a restrained palette, so
/// the choices are muted rather than saturated.
enum AccentChoice: String, CaseIterable, Identifiable {
    case indigo
    case teal
    case orange
    case violet

    var id: String { rawValue }

    var name: String {
        switch self {
        case .indigo: "Indigo"
        case .teal: "Teal"
        case .orange: "Amber"
        case .violet: "Violet"
        }
    }

    var color: Color {
        switch self {
        case .indigo: Color(red: 0.30, green: 0.36, blue: 0.86)
        case .teal: Color(red: 0.00, green: 0.58, blue: 0.56)
        case .orange: Color(red: 0.90, green: 0.47, blue: 0.14)
        case .violet: Color(red: 0.52, green: 0.32, blue: 0.82)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color, color.opacity(0.68)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Account types keep the same colour everywhere: tree, pickers and reports.
func accountColor(_ type: String) -> Color {
    switch type {
    case "ASSET": .green
    case "BANK": .blue
    case "CASH": .teal
    case "CREDIT": .orange
    case "LIABILITY": .red
    case "INCOME": .mint
    case "EXPENSE": .purple
    case "EQUITY": .indigo
    case "RECEIVABLE": .cyan
    case "PAYABLE": .brown
    default: .secondary
    }
}

enum ThemeKeys {
    static let accent = "saldima.accent"
    static let appearance = "saldima.appearance"
}
