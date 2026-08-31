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
            revision: "b2a49eaa5b6a274e757c90353cc906a655f64cd7"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "MacFeature",
            dependencies: [
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Core", package: "Common"),
                .product(name: "Persistence", package: "Common"),
                .product(name: "DesignSystem", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Remote", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "NookApp", package: "opennook"),
                .product(name: "NookComponents", package: "opennook"),
                .product(name: "Sparkle", package: "Sparkle"),
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
