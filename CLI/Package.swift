// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CLI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DaemonRuntime", targets: ["DaemonRuntime"]),
        .executable(name: "Lumen", targets: ["Daemon"]),
        .executable(name: "Spark", targets: ["Helper"]),
    ],
    dependencies: [
        .package(name: "Common", path: "../Common"),
        .package(name: "Transport", path: "../Common/Transport"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "DaemonRuntime",
            dependencies: [
                .product(name: "Core", package: "Common"),
                .product(name: "Adapters", package: "Common"),
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Remote", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "Daemon",
            dependencies: [
                "DaemonRuntime",
                .product(name: "Diagnostics", package: "Common"),
            ]
        ),
        .executableTarget(
            name: "Helper",
            dependencies: [
                .product(name: "Core", package: "Common"),
                .product(name: "Adapters", package: "Common"),
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "DaemonRuntimeTests",
            dependencies: [
                "DaemonRuntime",
                .product(name: "Adapters", package: "Common"),
                .product(name: "Core", package: "Common"),
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Remote", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
