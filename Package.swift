// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let portableTargets: [Target] = [
    .target(
        name: "SaldimaCore",
        path: "SaldimaCore",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "SaldimaSync",
        dependencies: ["SaldimaCore"],
        path: "SaldimaSync",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "SaldimaTestKit",
        dependencies: ["SaldimaCore", "SaldimaSync"],
        path: "SaldimaTestKit",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "SaldimaCoreTests",
        dependencies: ["SaldimaCore", "SaldimaTestKit"],
        path: "SaldimaCoreTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "SaldimaSyncTests",
        dependencies: ["SaldimaSync", "SaldimaTestKit"],
        path: "SaldimaSyncTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]

// Linux deliberately resolves only the pure packages and their tests.
// Apple builds add the SwiftUI app through the generated Xcode project.
#if os(Linux)
let package = Package(
    name: "Saldima",
    products: [
        .library(name: "SaldimaCore", targets: ["SaldimaCore"]),
        .library(name: "SaldimaSync", targets: ["SaldimaSync"]),
        .library(name: "SaldimaTestKit", targets: ["SaldimaTestKit"]),
    ],
    targets: portableTargets
)
#else
let package = Package(
    name: "Saldima",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [
        .library(name: "SaldimaCore", targets: ["SaldimaCore"]),
        .library(name: "SaldimaSync", targets: ["SaldimaSync"]),
        .library(name: "SaldimaTestKit", targets: ["SaldimaTestKit"]),
    ],
    targets: portableTargets
)
#endif
