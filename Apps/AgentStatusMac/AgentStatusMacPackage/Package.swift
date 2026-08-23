// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusMacFeature",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "AgentStatusMacFeature",
            targets: ["AgentStatusMacFeature"]
        ),
    ],
    dependencies: [
        .package(name: "AgentStatusCommon", path: "../../../Common"),
        .package(name: "AgentStatusTransport", path: "../../../Common/AgentStatusTransport"),
        .package(
            url: "https://github.com/AFutureD/opennook.git",
            revision: "e4c51a4d161d12ce91aac360706dc818c0c3a96d"
        ),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "AgentStatusMacFeature",
            dependencies: [
                .product(name: "AgentStatusIPCClient", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusDesignSystem", package: "AgentStatusCommon"),
                .product(name: "AgentStatusLogging", package: "AgentStatusCommon"),
                .product(name: "AgentStatusRemote", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NookApp", package: "opennook"),
                .product(name: "NookComponents", package: "opennook"),
            ],
            resources: [
                .copy("Resources/codex.svg"),
                .copy("Resources/claude.svg"),
            ]
        ),
        .testTarget(
            name: "AgentStatusMacFeatureTests",
            dependencies: [
                "AgentStatusMacFeature",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
