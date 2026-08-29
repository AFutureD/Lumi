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
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            exact: "2.12.0"
        ),
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
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .executableTarget(
            name: "Daemon",
            dependencies: [
                "DaemonRuntime",
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Persistence", package: "Common"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .executableTarget(
            name: "Helper",
            dependencies: [
                .product(name: "IPCClient", package: "Common"),
                .product(name: "Diagnostics", package: "Common"),
                .product(name: "Transport", package: "Transport"),
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
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
