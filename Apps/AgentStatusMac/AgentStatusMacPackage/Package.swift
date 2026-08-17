// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusMacFeature",
    platforms: [.macOS(.v15)],
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
            url: "https://github.com/twinkling-reality/opennook.git",
            revision: "03e1acd37e28548475d76b2fee5a430f03c9378d"
        ),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "AgentStatusMacFeature",
            dependencies: [
                .product(name: "AgentStatusIPCClient", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusRemote", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NookApp", package: "opennook"),
                .product(name: "NookComponents", package: "opennook"),
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
