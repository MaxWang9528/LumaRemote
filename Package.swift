// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LumaRemote",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product, representing the main app.
        .library(name: "LumaRemote", targets: ["LumaRemote"]),
    ],
    dependencies: [
        .package(path: "Core"),
    ],
    targets: [
        .target(
            name: "LumaRemote",
            dependencies: [.product(name: "LumaCore", package: "Core")]
        ),
    ]
)
