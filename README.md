# xFinder

A native macOS remote file browser (SFTP, SCP (shell), FTP/FTPS, WebDAV, S3) in the spirit of
WinSCP, FileZilla and Transmit. See [FEATURES.md](FEATURES.md) for the full
feature specification.

## Layout

- `Sources/xFinderKit` — SwiftPM library: models, protocol implementations,
  transfer engine, import/export, update logic.
- `Sources/CBcryptPBKDF` — OpenBSD `bcrypt_pbkdf` (for encrypted OpenSSH keys).
- `Tests/xFinderKitTests` — unit tests (`swift test`).
- `App/` — the SwiftUI/AppKit application.
- `Vendor/swift-nio-ssh` — locally patched swift-nio-ssh (see its `PATCHES.md`).
- `Vendor/Citadel` — locally patched Citadel SSH/SFTP client (see its `PATCHES.md`).
- `scripts/test_protocol_servers.sh` — starts throwaway FTP, FTPS, WebDAV and S3 (moto) servers and runs the protocol integration tests.
- `scripts/test_sftp_server.sh` — starts throwaway sshd instances on 127.0.0.1:2222 (with SFTP) and
  127.0.0.1:2223 (without an SFTP subsystem) and runs the SFTP and SCP (shell) integration tests.
- `scripts/` — build, icon and release packaging scripts.

## Building

Requirements: Apple Silicon, macOS 15+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build.sh            # xcodegen generate + xcodebuild (Debug)
swift test                  # xFinderKit unit tests
```

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published on the [Releases page](https://github.com/tianlan-dev/xFinder/releases).

1. Set `MARKETING_VERSION` in `project.yml`, commit and push `main`.
2. Tag and push: `git tag -a v0.0.2 -m "xFinder 0.0.2" && git push origin v0.0.2`.
3. The workflow runs the unit tests, builds an ad-hoc signed Release, and
   publishes `xFinder-<version>.zip`, `xFinder-<version>.dmg` and
   `SHA256SUMS.txt`. Running the workflow manually (`workflow_dispatch`) only
   builds and uploads the files as a workflow artifact.

`scripts/package_release.sh <version> [build]` does the same build locally into `dist/`.

Builds are not notarized (there is no Developer ID). After downloading, either
right-click xFinder and choose **Open**, or run
`xattr -dr com.apple.quarantine /Applications/xFinder.app`.

## Updates

xFinder checks the latest GitHub release about 5 seconds after launch (at most
once a day) and from **xFinder ▸ Check for Updates…**. Clicking **Update**
downloads the zip, verifies its SHA-256, unpacks it, removes the quarantine
attribute, checks the bundle ID, version and code signature, then quits,
swaps the app bundle in place and relaunches the new version. If the app's
folder is not writable (for example `/Applications` owned by root), macOS asks
for an administrator password for the swap.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
