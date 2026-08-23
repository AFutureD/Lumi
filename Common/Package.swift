// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentStatusCommon",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "AgentStatusCore", targets: ["AgentStatusCore"]),
        .library(name: "AgentStatusCodex", targets: ["AgentStatusCodex"]),
        .library(name: "AgentStatusIPCClient", targets: ["AgentStatusIPCClient"]),
        .library(name: "AgentStatusRemote", targets: ["AgentStatusRemote"]),
        .library(name: "AgentStatusDesignSystem", targets: ["AgentStatusDesignSystem"]),
        .library(name: "AgentStatusLogging", targets: ["AgentStatusLogging"]),
    ],
    dependencies: [
        .package(path: "AgentStatusTransport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.0.0"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "AgentStatusLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
        ),
        .target(
            name: "AgentStatusCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ]
        ),
        .target(
            name: "AgentStatusCodex",
            dependencies: [
                "AgentStatusCore",
                "AgentStatusLogging",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ]
        ),
        .target(
            name: "AgentStatusIPCClient",
            dependencies: [
                "AgentStatusLogging",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "AgentStatusDesignSystem",
            dependencies: [
                "AgentStatusCore",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ]
        ),
        .target(
            name: "AgentStatusRemote",
            dependencies: [
                "AgentStatusLogging",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "AgentStatusCoreTests",
            dependencies: [
                "AgentStatusCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AgentStatusCodexTests",
            dependencies: [
                "AgentStatusCodex",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AgentStatusDesignSystemTests",
            dependencies: [
                "AgentStatusDesignSystem",
                "AgentStatusCore",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AgentStatusLoggingTests",
            dependencies: [
                "AgentStatusLogging",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AgentStatusRemoteTests",
            dependencies: [
                "AgentStatusRemote",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
