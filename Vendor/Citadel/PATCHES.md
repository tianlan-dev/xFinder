# Local patches to Citadel

Base: `https://github.com/orlandos-nl/Citadel.git`, tag `0.12.1`
(commit `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`). Only `Sources/` and the
license are kept; the server example and tests were removed. `Package.swift`
points at the vendored `../swift-nio-ssh`.

1. `SSHAuthenticationMethod.swift`: a `.custom` authentication delegate is kept
   after its first use. Upstream drops it, so a delegate could only make a single
   offer; xFinder's delegate tries keys and passwords in order and re-prompts.
2. `SFTP/Client/SFTPClient.swift`: `listDirectory` closes the directory handle
   after reading (upstream leaks one handle per listing).
3. `SFTP/Client/SFTPClient.swift`, `Errors.swift`: `openSFTP` waits for the
   server's reply to the `sftp` subsystem request and fails with the new
   `SFTPError.subsystemRejected` when it is refused. Upstream ignores the reply,
   so a server without an SFTP subsystem left the connection hanging forever.
4. `TTY/Client/TTY.swift`: `TTYStdinWriter.sendEOF()` half-closes the exec
   channel so commands that read standard input (`cat > file`, `scp -t`) see
   end-of-file. Used by xFinder's SCP (shell) mode.
