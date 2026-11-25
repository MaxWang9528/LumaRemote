// swift-tools-version: 6.0
// Pure-Swift protocol logic for DayBetter lights. Never import CoreBluetooth, UIKit or SwiftUI here:
// this package must build and test on Linux (`swift test --package-path Core`).

import PackageDescription

let package = Package(
    name: "LumaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
    ],
    targets: [
        .target(name: "LumaCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
