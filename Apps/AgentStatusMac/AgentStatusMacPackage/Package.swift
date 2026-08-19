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
            revision: "7b0ca6ca251885aecec5834b374ef4dc0907bd8f"
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
