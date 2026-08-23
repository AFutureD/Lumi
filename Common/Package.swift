// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Common",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Adapters", targets: ["Adapters"]),
        .library(name: "IPCClient", targets: ["IPCClient"]),
        .library(name: "Remote", targets: ["Remote"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    dependencies: [
        .package(path: "Transport"),
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
            name: "Diagnostics",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ]
        ),
        .target(
            name: "Core",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Transport", package: "Transport"),
            ]
        ),
        .target(
            name: "Adapters",
            dependencies: [
                "Core",
                "Diagnostics",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Transport", package: "Transport"),
            ]
        ),
        .target(
            name: "IPCClient",
            dependencies: [
                "Diagnostics",
                .product(name: "Transport", package: "Transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "DesignSystem",
            dependencies: [
                "Core",
                .product(name: "Transport", package: "Transport"),
            ]
        ),
        .target(
            name: "Remote",
            dependencies: [
                "Diagnostics",
                .product(name: "Transport", package: "Transport"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AdaptersTests",
            dependencies: [
                "Adapters",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: [
                "DesignSystem",
                "Core",
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: [
                "Diagnostics",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "RemoteTests",
            dependencies: [
                "Remote",
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
