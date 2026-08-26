// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Transport",
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
    ],
    products: [
        .library(name: "Transport", targets: ["Transport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "Transport",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: [
                "Transport",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
