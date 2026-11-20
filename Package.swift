// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "xFinderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "xFinderKit", targets: ["xFinderKit"])
    ],
    dependencies: [
        // Locally patched copies of swift-nio-ssh and Citadel (see Vendor/*/PATCHES.md).
        .package(path: "Vendor/swift-nio-ssh"),
        .package(path: "Vendor/Citadel"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "CBcryptPBKDF",
            path: "Sources/CBcryptPBKDF",
            publicHeadersPath: "include"
        ),
        .target(
            name: "xFinderKit",
            dependencies: [
                "CBcryptPBKDF",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "xFinderKitTests",
            dependencies: [
                "xFinderKit",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
