// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacFeature",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "MacFeature",
            targets: ["MacFeature"]
        ),
    ],
    dependencies: [
        .package(name: "Common", path: "../../../Common"),
        .package(name: "Transport", path: "../../../Common/Transport"),
        .package(
            url: "https://github.com/AFutureD/opennook.git",
            revision: "e4c51a4d161d12ce91aac360706dc818c0c3a96d"
        ),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "MacFeature",
            dependencies: [
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Core", package: "Common"),
                .product(name: "DesignSystem", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Remote", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "NookApp", package: "opennook"),
                .product(name: "NookComponents", package: "opennook"),
            ],
            resources: [
                .copy("Resources/codex.svg"),
                .copy("Resources/claude.svg"),
            ]
        ),
        .testTarget(
            name: "MacFeatureTests",
            dependencies: [
                "MacFeature",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
