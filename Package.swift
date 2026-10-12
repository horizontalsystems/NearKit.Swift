// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NearKit",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "NearKit",
            targets: ["NearKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/horizontalsystems/HdWalletKit.Swift.git", exact: "1.3.2"),
        .package(url: "https://github.com/horizontalsystems/HsCryptoKit.Swift.git", exact: "1.3.2"),
        .package(url: "https://github.com/horizontalsystems/HsExtensions.Swift.git", exact: "1.0.6"),
        .package(url: "https://github.com/horizontalsystems/HsToolKit.Swift.git", exact: "2.0.7"),
    ],
    targets: [
        .target(
            name: "NearKit",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HdWalletKit", package: "HdWalletKit.Swift"),
                .product(name: "HsCryptoKit", package: "HsCryptoKit.Swift"),
                .product(name: "HsExtensions", package: "HsExtensions.Swift"),
                .product(name: "HsToolKit", package: "HsToolKit.Swift"),
            ]
        ),
        .testTarget(
            name: "NearKitTests",
            dependencies: [
                "NearKit",
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HdWalletKit", package: "HdWalletKit.Swift"),
                .product(name: "HsCryptoKit", package: "HsCryptoKit.Swift"),
                .product(name: "HsExtensions", package: "HsExtensions.Swift"),
                .product(name: "HsToolKit", package: "HsToolKit.Swift"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
