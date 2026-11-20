# Local patches to swift-nio-ssh

Base: Citadel's fork `https://github.com/Wellz26/swift-nio-ssh.git`, tag `0.3.7`
(commit `d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c`). Only `Sources/NIOSSH` and the
license are kept; examples, tests and tooling were removed.

The vendored Citadel (`Vendor/Citadel`) and xFinderKit both depend on this directory
as a local package.

## 1. RSA SHA-2 user authentication (RFC 8332)

OpenSSH ≥ 8.8 refuses `ssh-rsa` (SHA-1) signatures. With RSA keys the public-key
*algorithm name* sent in `SSH_MSG_USERAUTH_REQUEST` must be `rsa-sha2-256` /
`rsa-sha2-512` while the key blob still starts with `ssh-rsa`. Upstream NIOSSH
always writes the same string for both.

Patch: `Keys And Signatures/CustomKeys.swift` adds the
`NIOSSHPublicKeyBlobPrefixProviding` protocol; `NIOSSHPublicKey.swift` writes the
blob prefix from it for custom keys. xFinderKit's `RSASHA2PrivateKey` uses it.
