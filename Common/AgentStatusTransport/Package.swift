// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusTransport",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "AgentStatusTransport", targets: ["AgentStatusTransport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "AgentStatusTransport",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AgentStatusTransportTests",
            dependencies: [
                "AgentStatusTransport",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
