// swift-tools-version:5.10
// Vendored copy of swift-nio-ssh (Citadel fork, github.com/Wellz26/swift-nio-ssh
// tag 0.3.7, commit d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c) with local patches
// for xFinder. See PATCHES.md. Licensed under Apache License v2.0 (LICENSE.txt).
import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        )
    ]
)
