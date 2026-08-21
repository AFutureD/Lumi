// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusIOSFeature",
    platforms: [.iOS(.v18)],
    products: [
        .library(
            name: "AgentStatusIOSFeature",
            targets: ["AgentStatusIOSFeature"]
        ),
    ],
    dependencies: [
        .package(name: "AgentStatusCommon", path: "../../../Common"),
        .package(name: "AgentStatusTransport", path: "../../../Common/AgentStatusTransport"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "AgentStatusIOSFeature",
            dependencies: [
                .product(name: "AgentStatusRemote", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusDesignSystem", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ]
        ),
        .testTarget(
            name: "AgentStatusIOSFeatureTests",
            dependencies: [
                "AgentStatusIOSFeature",
                .product(name: "AgentStatusRemote", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
