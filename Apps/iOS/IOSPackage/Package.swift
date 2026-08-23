// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "IOSFeature",
    platforms: [.iOS(.v18)],
    products: [
        .library(
            name: "IOSFeature",
            targets: ["IOSFeature"]
        ),
    ],
    dependencies: [
        .package(name: "Common", path: "../../../Common"),
        .package(name: "Transport", path: "../../../Common/Transport"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "swift-6.2.4-RELEASE"),
    ],
    targets: [
        .target(
            name: "IOSFeature",
            dependencies: [
                .product(name: "Remote", package: "Common"),
                .product(name: "Core", package: "Common"),
                .product(name: "DesignSystem", package: "Common"),
                .product(name: "Transport", package: "Transport"),
            ]
        ),
        .testTarget(
            name: "IOSFeatureTests",
            dependencies: [
                "IOSFeature",
                .product(name: "Remote", package: "Common"),
                .product(name: "Core", package: "Common"),
                .product(name: "Transport", package: "Transport"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
