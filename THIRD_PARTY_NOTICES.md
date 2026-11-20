# Third-party notices

xFinder itself is released under the MIT License (see `LICENSE`). It includes
or links the following third-party software. Each component keeps its own
license; the full license texts are in the listed files, or in the component's
repository for SwiftPM packages.

## Vendored source (in this repository)

| Component | Path | License | License file |
|---|---|---|---|
| Citadel 0.12.1 (patched, see `PATCHES.md`) | `Vendor/Citadel` | MIT, Copyright (c) 2022 Orlandos | `Vendor/Citadel/LICENSE` |
| swift-nio-ssh (patched, see `PATCHES.md`) | `Vendor/swift-nio-ssh` | Apache License 2.0, Copyright Apple Inc. and the SwiftNIO project authors | `Vendor/swift-nio-ssh/LICENSE.txt` |
| OpenBSD `bcrypt_pbkdf` | `Sources/CBcryptPBKDF/bcrypt-kdf.c` | ISC, Copyright (c) 2013 Ted Unangst | header of the source file |
| OpenBSD Blowfish | `Sources/CBcryptPBKDF/blf.c`, `blf.h` (and the copy in `Vendor/Citadel/Sources/CCitadelBcrypt`) | BSD-style, Copyright 1997 Niels Provos | header of the source files |

This product includes software developed by Niels Provos.

## Swift packages (fetched by SwiftPM)

| Package | Version | License |
|---|---|---|
| [swift-nio](https://github.com/apple/swift-nio) | 2.105.0 | Apache License 2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) (includes BoringSSL, under the OpenSSL, ISC and other licenses listed in its repository) | 3.15.1 | Apache License 2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.4 | Apache License 2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache License 2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.6 | Apache License 2.0 |
| [swift-log](https://github.com/apple/swift-log) | 1.17.2 | Apache License 2.0 |
| [swift-system](https://github.com/apple/swift-system) | 1.9.0 | Apache License 2.0 |
| [BigInt](https://github.com/attaswift/BigInt) | 5.7.0 | MIT, Copyright (c) 2016-2017 Károly Lőrentey |

Versions are those pinned in `Package.resolved`.
