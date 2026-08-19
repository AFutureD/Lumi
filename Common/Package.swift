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
    ],
    dependencies: [
        .package(path: "AgentStatusTransport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
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
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
            ]
        ),
        .target(
            name: "AgentStatusIPCClient",
            dependencies: [
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "AgentStatusRemote",
            dependencies: [
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
            name: "AgentStatusRemoteTests",
            dependencies: [
                "AgentStatusRemote",
                .product(name: "AgentStatusTransport", package: "AgentStatusTransport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
