// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusCLI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentStatusDaemonRuntime", targets: ["AgentStatusDaemonRuntime"]),
        .executable(name: "agent-status-daemon", targets: ["AgentStatusDaemon"]),
        .executable(name: "agent-status-helper", targets: ["AgentStatusHelper"]),
    ],
    dependencies: [
        .package(name: "AgentStatusCommon", path: "../Common"),
        .package(name: "AgentStatusTransport", path: "../Common/AgentStatusTransport"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "AgentStatusDaemonRuntime",
            dependencies: [
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCodex", package: "AgentStatusCommon"),
                .product(name: "AgentStatusIPCClient", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "AgentStatusDaemon",
            dependencies: ["AgentStatusDaemonRuntime"]
        ),
        .executableTarget(
            name: "AgentStatusHelper",
            dependencies: [
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCodex", package: "AgentStatusCommon"),
                .product(name: "AgentStatusIPCClient", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "AgentStatusDaemonRuntimeTests",
            dependencies: [
                "AgentStatusDaemonRuntime",
                .product(name: "AgentStatusCodex", package: "AgentStatusCommon"),
                .product(name: "AgentStatusCore", package: "AgentStatusCommon"),
                .product(name: "AgentStatusIPCClient", package: "AgentStatusCommon"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
