# xFinder Feature Specification

> Renamed from the original RemoteFinder specification to xFinder (library name
> `xFinderKit`; directories, Keychain service, etc. renamed accordingly).
> Section 1 is omitted.

## 2. Overall Architecture

- **Two layers**
  - `xFinderKit`: a SwiftPM library containing models, protocol implementations, the transfer engine, import/export and update logic, with unit tests.
  - `App/`: the SwiftUI interface, partly AppKit (e.g. the file list uses `NSOutlineView`).
- **Dependencies**: Citadel (SSH/SFTP), a locally patched swift-nio-ssh, swift-nio, swift-crypto (including `_CryptoExtras`).
- **Build and signing**: the project is generated with XcodeGen (`project.yml`); requires macOS 15 or later; ad-hoc signing; Hardened Runtime enabled; no sandbox. The Apple Events entitlement is used to control iTerm2.
- **Data storage**
  - Data lives in `~/Library/Application Support/xFinder/`: `sites.json`, `keys.json`, `accounts.json`, `settings.json`, `known_hosts.json`.
  - Files are written as pretty-printed JSON with sorted keys, atomically, with file permissions 0600 (`JSONFile.save`).
  - Passwords and key passphrases are stored in the Keychain (service `xFinder`), with account names `site-password.<UUID>`, `key-passphrase.<UUID>`, `account-password.<UUID>`.
  - Cache directory `~/Library/Caches/xFinder/`: `Edit/` (remote editing), `Staging/` (cross-server copy), `terminal/` (terminal launch scripts), `askpass/` (password helper scripts and socket).
- **Unified protocol interface `RemoteFileSystem`** (RemoteFileSystem.swift)
  - Methods: `connect`, `list`, `stat`, `symlinkTarget`, `rename`, `delete`, `createDirectory`, `setPermissions`, `setModificationDate`, `copyItem`, `download`/`upload` with offset and progress callback, and `makeTransferConnection` (reuses the credentials already entered to open a separate connection for the transfer queue).
  - `RemoteCapabilities` (shell, rename, delete, mkdir, chmod, resume, serverCopy, atomicUpload) tells the UI which features are available and which need a fallback.

| Protocol | Capabilities |
|---|---|
| SFTP | shell, rename, delete, mkdir, chmod, resume, serverCopy |
| SCP (shell) | shell, rename, delete, mkdir, chmod, serverCopy |
| FTP/FTPS | rename, delete, mkdir, chmod, resume |
| WebDAV | rename, delete, mkdir, serverCopy |
| S3 | rename, delete, mkdir, serverCopy, atomicUpload |

## 3. Protocol Implementations

### SFTP (SFTPFileSystem.swift)
- Citadel/NIOSSH; 20-second connection timeout; no automatic reconnect (`reconnect: .never`).
- Keys and passwords are tried in the configured order, moving to the next method on failure; a passphrase is tried at most 4 times, a password 3 times. Successful credentials are kept in memory only, for reuse by transfer connections.
- Additionally enables the `DiffieHellmanGroup14Sha256` key exchange and the RSA public key algorithm.
- 32 KiB chunks with 16 concurrent requests; downloads read concurrently by offset and write sequentially; uploads truncate when the offset is 0, otherwise continue writing from the offset.
- Symbolic links are resolved to absolute paths with REALPATH; recursive delete; chmod uses `mode & 0o7777`.
- Server-side copy runs `cp -pR -- src dst` (arguments shell-escaped); when commands cannot be executed it reports unsupported and the upper layer falls back to download-then-upload.

- When the server refuses the `sftp` subsystem (for example a Home Assistant SSH add-on with SFTP off), connecting fails within about a second with `RemoteError.sftpUnavailable`, and the browser offers *Use SCP (shell)*.

### SCP (shell) (Shell/SCPFileSystem.swift, Shell/ShellListing.swift)
- For SSH servers without an SFTP subsystem, in the spirit of WinSCP's SCP protocol. Sign-in, keys, accounts, host keys and the terminal button work exactly as for SFTP (shared `SSHConnector`).
- Every operation is one SSH exec channel running `exec /bin/sh -c '…'` with `LC_ALL=C` and `TZ=UTC0`, so the login shell (bash, zsh, …) only parses a single simple command. Output before a start marker is discarded, so text printed by shell startup files does not break parsing. All paths are single-quoted.
- On connect, one probe command reads the home folder (`pwd`) and detects `stat -c`, `ls --full-time`, `scp` and `readlink`.
- Listing: with `stat -c` (GNU coreutils and BusyBox) a single `stat` call returns mode, size, mtime, owner, group and name, and symlinks get their target and whether it is a folder. Without it, `ls -la` (with `--full-time` when available) is parsed for GNU, BusyBox and BSD output, including dates without a year, device files and names with spaces or ` -> `.
- Operations: `mkdir`, `mv` (fails if the target exists, like SFTP rename), `rm` / `rm -rf`, `chmod`, `touch -t` for modification dates, `cp -pR` for server-side copy, `readlink`.
- Transfers use the classic SCP protocol (`scp -f` / `scp -t`, file by file) with progress; without `scp` on the server, `cat` / `cat >` is used.
- Limitations: no resume (interrupted transfers restart), uploads are not atomic (the transfer queue still writes a temporary name and renames it), every operation is a separate command so large folders list more slowly than SFTP, file names containing a newline or invalid UTF-8 are not supported, and the server must allow running commands with a POSIX `/bin/sh`.

### FTP / FTPS (FTPFileSystem.swift, FTPConnection.swift, FTPTLSStream.swift, FTPParsing.swift)
- Plain FTP uses `NWConnection`; FTPS uses `URLSessionStreamTask`, supporting explicit AUTH TLS and implicit TLS (usually port 990).
- Data connections are encrypted too (`PBSZ 0`/`PROT P`), never falling back to plaintext.
- EPSV first, then PASV on failure; PASV ignores the IP reported by the server and reuses the control connection's host (NAT friendly).
- If `FEAT` advertises MLST, directories are listed with MLSD, otherwise `LIST -a`, then `LIST`; both Unix (`ls -l`) and Windows/IIS LIST formats are parsed.
- Resume: downloads use `REST`+`RETR`, uploads use `APPE` (otherwise `STOR`); uploads read 256 KiB chunks.
- `SITE CHMOD`; modification times are preserved only if the server supports `MFMT`; server-side copy is not supported.
- Control commands run serially; on disconnect or a 60-second response timeout it reconnects automatically and retries once (no retry during a transfer).
- An empty username means anonymous login (`anonymous`/`anonymous@`).
- Error mapping: 550/450 map to permission denied or not found depending on the message; 500/502/504 map to unsupported.
- Known limitation: servers that require the data connection to reuse the TLS session (vsftpd `require_ssl_reuse=YES`) may reject transfers.

### WebDAV (WebDAVFileSystem.swift, WebDAVParsing.swift)
- Shares `HTTPTransport` (ephemeral URLSession, 60-second timeout, at most 4 connections per host).
- On connect, a Depth 0 PROPFIND validates the base path; the base path is configurable, e.g. Nextcloud's `/remote.php/dav/files/<user>`.
- PROPFIND (Depth 0/1) lists directories and fetches info; MOVE, COPY (Depth infinity), DELETE and MKCOL perform file operations.
- Supports Basic/Digest authentication; an empty username means anonymous.
- Downloads resume with Range (206 appends, 200 replaces, 416 during resume counts as complete); uploads always start from the beginning.
- chmod is not supported; the modification time is determined by the server.
- HTTP status mapping: 401 authentication failed, 403 permission denied, 404 not found, 409 parent directory missing, 405/412 already exists, 423 locked, 507 insufficient storage.

### S3 (S3FileSystem.swift, S3Signer.swift, S3Parsing.swift)
- The username is the Access Key ID and the password is the Secret Access Key (stored in the Keychain).
- Custom SigV4 signing with `UNSIGNED-PAYLOAD`; default region `us-east-1`.
- AWS uses virtual-hosted-style addressing (path-style when the bucket name contains dots); compatible services (MinIO, Wasabi, R2, Ceph, etc.) always use path-style and may opt into plain HTTP.
- Automatic region correction: on 301/307/400 it reads `x-amz-bucket-region` or the Region in the error XML, re-signs and retries once.
- Directories are listed with paginated ListObjectsV2; folders are `/` prefixes, and empty folders are represented by zero-byte marker objects.
- Rename is CopyObject followed by deleting the original; deleting a folder deletes each object under the prefix.
- Single uploads and server-side copies are limited to 5 GB (multipart upload is not implemented); objects only appear after the upload completes, so no temporary file is used.
- Clock skew has its own dedicated error message.

### Host Keys and Certificate Trust
- SSH host keys are compared by `SHA256:` fingerprint and stored in the app's own `known_hosts.json` (separate from `~/.ssh/known_hosts`), keyed as `[host]:port` (KnownHostsStore.swift).
- FTPS and HTTPS are handled by `TLSTrustEvaluator` (TLSTrust.swift): certificates trusted by macOS pass directly; for untrusted certificates the SHA-256 fingerprint of the DER is shown for the user to confirm, and is remembered after confirmation.
- A changed fingerprint triggers a warning showing the old fingerprint.

### Private Key Support (SSHPrivateKeyLoader.swift)
- OpenSSH format (optionally passphrase-protected): Ed25519, RSA, ECDSA P-256/384/521.
- (The photo was truncated here; the original mentions that passphrase derivation uses bcrypt. Implement following the OpenSSH private key format: bcrypt-pbkdf + aes256-ctr and other common ciphers.)

### Protocol Feature Matrix

| Protocol | Browse & transfer | Resume download | Resume upload | Server-side copy | chmod | Terminal |
|---|---|---|---|---|---|---|
| SFTP | Yes | Yes | Yes | Yes (cp) | Yes | Yes |
| SCP (shell) | Yes | No | No | Yes (cp) | Yes | Yes |
| FTP / FTPS | Yes | Yes | Yes | No | When the server supports `SITE CHMOD` | No |
| WebDAV | Yes | Yes (Range) | No, restarts from the beginning | Yes (COPY) | No | No |
| S3 | Yes | Yes (Range) | No, restarts from the beginning | Yes (CopyObject) | No | No |

## 4. Favorites, Accounts and Settings Inheritance

- **Data model** (Models.swift)
  - Server (`Site`) fields: protocol, address, port (empty means the default port: SFTP and SCP 22, FTP/explicit FTPS 21, implicit FTPS 990, WebDAV 80, WebDAVS/S3 443), username, key, authentication order, initial directory, parent folder, ssh config alias, WebDAV base path, S3 bucket/region/plain-HTTP flag, bookmarks, account.
  - Folders (`SiteFolder`) are a single level and can set a default username, key, authentication order, account and bookmarks.
- **Ordering** (SiteLibrary.swift, data format v2)
  - Top-level servers and folders share one ordering; old v1 data is migrated automatically.
  - Supports drag and drop (multi-selection, an insertion line indicates the position, dropping onto a folder moves into it), move up/down, and three natural-name sorts (`srv2` sorts before `srv10`): within a folder, top level, everything.
- **Sidebar** (SitesSidebarView.swift, SitesOutline.swift)
  - Search by name or address, duplicate a server, expand or collapse all folders.
  - Bulk delete: when deleting a folder, choose to keep its servers (moved to the top level) or delete them too; deleting a server also deletes its Keychain password.
  - Open All in Tabs | Open N Servers in Tabs; a server can be opened in the browser or in a terminal.
- **Settings inheritance** (SiteSettingsResolver.swift)

| Setting | Resolution order |
|---|---|
| Username | Account → server → folder → local user name (SFTP and SCP only) |
| Account | The server's account wins; the folder's account is inherited only when the server has no username |
| Key | Server → folder → global default; when an account is selected, the account's key is used. `.none` stops further inheritance |
| Auth order | Server → folder → account → global |

  - A key-only account never sends a password over SSH.
  - A shared account password is not deleted when one server rejects it.
- **Accounts** (Settings ▸ Accounts, AccountsSettingsView.swift, Credentials.swift): name, username, key, whether to use a password, authentication order. The UI lists which servers and folders use the account; duplicate names are numbered automatically; with no key, the password is forced on.
- **Key library** (Settings ▸ Keys, KeyLibrary.swift)
  - Stores only the file path and an alias, never copies the private key; shows the type, fingerprint and whether it is encrypted.
  - The path can be re-pointed, the alias changed, and the passphrase forgotten; on deletion the places referencing it can be reviewed and replaced.
  - Other unregistered keys under `~/.ssh` are never tried automatically.
- **Validation** (SiteValidation.swift): each hostname label is at most 63 characters and the total at most 253; IPv4/IPv6 supported; must not start with `-`; port 1–65535; S3 requires a bucket.
- **Server editor** (SiteEditView.swift, SiteConnectionTester.swift)
  - Shows the fields relevant to the protocol; plain FTP and HTTP display a security warning.
  - The Test button connects with the unsaved settings and checks that the initial directory exists and is a folder; passwords entered during the test are not saved.
  - Servers imported from ssh config show an explanatory note.
- **Password requests** (PasswordBroker.swift): read the Keychain first; multiple simultaneous requests prompt only once; at most 3 attempts; written to the Keychain only after successful authentication and when "save" is checked.

## 5. Import and Export

- **Favorites** (FavoritesTransfer.swift, FavoritesTransferActions.swift)
  - Entry points: File ▸ Import Favorites… / Export Favorites…, and the sidebar + menu.
  - The exported JSON format is named `xFinder Favorites` (v1) and contains folders, servers, global bookmarks, the keys in use (alias and path) and account info, without passwords.
  - Import only adds, never modifies existing content; name clashes get a suffix `Name (2)`.
  - Keys are matched by path; if there is no match but the file exists it is added automatically, otherwise it falls back to Inherit and this is noted in the import result.
  - Accounts are matched by "name (case-insensitive) + username"; if none matches, a new one is created (without a password).
- **Transmit**: reads `.transmitservers`, importing only SFTP and FTP; nested folders become `Parent / Child`; port `0` means default; `remotePath` becomes the initial directory; skipped items are listed with reasons.
- **`~/.ssh/config`** (SSHConfigImporter.swift)
  - Skips wildcard Host entries and `Match` blocks; reads HostName, Port, User, IdentityFile.
  - Imports into the "Imported from ssh config" folder; aliases already imported are skipped.
  - When opened in an external terminal it uses `ssh <alias>`, so ProxyJump and other config still apply; in-app browsing uses only the selected key.
- **Settings** (SettingsTransfer.swift, SettingsTransferActions.swift)
  - Entry points: File ▸ Import Settings… / Export Settings…, and Settings ▸ General.
  - Exports preferences, Open With rules, the key list and accounts; excludes passwords, favorites and trusted host keys.
  - On import, preferences are replaced wholesale after confirmation; keys and accounts are merged (existing ones stay unchanged).
  - Concurrency is clamped to 1–8; a download directory that does not exist on this Mac is reset to `~/Downloads`.

## 6. Tabs and Connections

- **Window layout** (MainWindowView.swift): one window with a `NavigationSplitView` (sidebar + tabs) and a transfer status bar at the bottom; Transfers and Settings are separate windows.
- **Tabs** (SessionTabs.swift, SessionTabBar.swift, ConnectionSession.swift)
  - Each tab has its own connection, path, selection, sort order and expansion state.
  - Opening a favorite reuses the current tab if it is empty, otherwise opens a new tab after it.
  - Closing the last tab shows Quick Connect; the window stays open.
  - Tabs can be reordered by dragging; the context menu has New / Duplicate / Close / Close Other Tabs.
  - A status dot shows idle / connecting / connected / failed / disconnected.
  - A background tab that needs authentication is switched to automatically.
- **Quick Connect** (SFTP, StartView.swift): address, port, username, key, initial directory; Save to Favorites or Connect.
- **Connection flow**
  - If the initial directory cannot be opened, the user is told and it falls back to home; on connection failure Try Again is shown (plus Use SCP (shell) when the server refused SFTP).
  - After a disconnect, Reconnect restores the previous path.
  - Host keys, certificates, passwords, S3 secrets and passphrases are all requested via prompts (PromptViews.swift).
- **Quit confirmation**: quitting asks for confirmation while transfers are in progress or edited files have not been uploaded (xFinderApp.swift).

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘W / ⇧⌘W | New tab / Close tab / Close window |
| ⇧⌘] / ⇧⌘[ | Next / Previous tab |
| ⌘1–⌘9 | Jump to tab |
| ⌥⌘L | Transfers window |
| ⌘[ / ⌘] / ⌘↑ | Back / Forward / Enclosing folder |
| ⌘R | Refresh |
| ⇧⌘N | New folder |
| ⌘U / ⇧⌘D | Upload / Download |
| ⇧⌘G | Go to Folder |
| ⇧⌘. | Show hidden files |
| ⌥⌘T | Open the current folder in an external terminal |
| ⌘O / Return / ⌘↓ | Open |
| ⌘C / ⌘V / ⌘D | Copy / Paste / Duplicate |
| ⌘⌫ | Delete |
| ⌘I | Get Info |
| → / ← | Expand / Collapse folder |

## 7. File Browser

- **File list** (RemoteFileTable.swift): `NSOutlineView` with columns Name, Size, Date Modified, Permissions, Owner, Group; sortable, columns reorderable.
- **Navigation** (BrowserView.swift): breadcrumbs, back/forward, enclosing folder, Go to Folder (supports `~`), show hidden files (synced to all tabs).
- **In-place folder expansion**: via the disclosure triangle or ←/→ keys; multiple levels can be expanded at once and contents load on demand; on refresh, expanded folders are reloaded too and ones that no longer exist collapse automatically. Double-clicking a folder still navigates into it.
- **File operations**
  - New folder, rename (validates the name and checks for duplicates).
  - Recursive delete with confirmation.
  - Change permissions (only when the protocol supports chmod).
  - Copy Path.
- **Get Info** (⌘I, ItemInfoSheet.swift): path, kind, size (bytes), modification time, permissions (symbolic and octal), owner/group; re-fetched from the server when opened, and if that fails it explains that the list's cached info is shown.
- **Symbolic links**
  - The list shows `name → target`: for SFTP the resolved absolute path, for FTP the text shown in LIST (MLSD does not provide the target; it is looked up in Get Info).
  - Get Info shows whether the target is a file, a folder or missing, and offers copying the target path or Go to Target.
- **Bookmarks bar** (BookmarksBar.swift)
  - Add: right-click a folder and choose Add to Bookmarks, or right-click the bookmarks bar and choose Bookmark Current Folder.
  - Three scopes (right-click Show For): this server only, servers in the same favorites folder, all servers.
  - Display order is global → folder → server's own, with duplicates removed.
  - While dragging, colored zones are shown: purple for global, orange for folder, blue for this server; the zone you drop into decides who can see it.
  - Bookmarks are stored in `sites.json`.

## 8. Copy, Paste and Drag & Drop

- **Duplicate** (⌘D): produces names like `name copy.ext`, `name copy 2.ext`.
- **Copy and paste** (⌘C / ⌘V)
  - Pastes into the current folder, or right-click a folder row and choose Paste Into Folder.
  - On name clashes choose Replace / Keep Both / Skip / Stop, optionally applied to all; copying an item into itself or its own subfolder is not allowed.
- **Copy strategy**
  - Same server: prefer server-side copy (SFTP uses `cp`, WebDAV uses COPY, S3 uses CopyObject); when unsupported (e.g. FTP, SFTP-only accounts) fall back to download then upload.
  - Across servers: download into `Caches/xFinder/Staging/<UUID>` first, then upload, and delete the temporary directory when finished.
  - Files copied in Finder can be pasted directly to upload them.
- **Drag & drop** (BrowserDragDrop.swift)
  - Finder → app: dropping on the file list, a folder row or a breadcrumb uploads to that location.
  - App → Finder: uses `NSFilePromiseProvider`; files download through the transfer queue with visible progress.
  - Within the same server: moves via rename without downloading data.
  - Across servers: hovering a dragged file over another tab for 0.4 seconds switches to it, and dropping into its list performs a cross-server copy.

## 9. Transfer Queue

TransferManager.swift, TransfersView.swift, Transfers.swift:

- Entry points: upload via ⌘U, the context menu, or dragging in; download via ⇧⌘D to the download directory, or Download To… to choose a directory.
- **Batches and scheduling**
  - Each transfer is a batch; after scanning it expands into individual files; folders are processed recursively and symbolic links are skipped.
  - `pump()` processes the oldest batch first; default concurrency is 3 (configurable 1–8).
- **Dedicated connections**: transfers use their own connection pool, reusing idle connections per server and closing them after being idle for a while, so closing a tab does not interrupt transfers.
- **Controls and display**
  - Each file can be paused, resumed, cancelled and retried; there are also Pause All / Resume All / Clear Finished.
  - Speed is smoothed and the remaining time is shown; the bottom status bar shows a summary.
- **Destination already exists**
  - A dialog compares both sizes and dates and marks the newer one; choose Replace / Skip / Keep Both / Resume / cancel the whole batch, optionally applying to later conflicts.
  - The default policy can be ask / overwrite / overwrite-if-newer (1-second tolerance) / skip / keep-both.
  - Resume is offered only when the protocol supports resuming and the destination is smaller than the source.
- **Safe overwrite**
  - Data is first written to a temporary file (on the server `.name.rfpart`, locally `name.rfdownload`), then replaces the original when complete, restoring permissions and modification time.
  - S3 objects only appear after the upload completes, so no temporary file is needed.
  - Cancelling a transfer cleans up temporary files.

## 10. Remote File Editing and Auto Upload

EditSyncService.swift:

- **Opening**: double-click, Return, ⌘O, or Open With ▸. The file is downloaded to `~/Library/Caches/xFinder/Edit/` and opened with the corresponding app; reopening a file that has un-uploaded changes does not overwrite the local copy.
- **Save detection**: file size and modification time are checked every 0.5 seconds and uploaded only after being stable for 0.8 seconds, so the multiple writes of one save upload only once. Uploads use the same temporary-file protection.
- **Offline retry**
  - When the server is unreachable it shows Server unreachable and retries after 10 → 20 → 40 seconds, then every 60 seconds (`min(60, 10·2^(n-1))`).
  - It retries immediately when the network comes back (`NWPathMonitor`) or a tab connects to that server; Try now is also available.
  - Errors retrying cannot fix (authentication failure, permission denied, path not found) show Upload failed without automatic retry, offering a Retry button.
- **The server file was changed by someone else**: choose Replace Server Version, Upload as a Copy, Discard My Changes or Decide Later.
- **Status display**: the Transfers window lists files being edited, with status, last upload time and next retry time; you can reveal the local copy, stop watching, and clean up unchanged files.
- **Open With rules** (OpenWith.swift, OpenWithSettingsView.swift)
  - Priority: exact file name (case-insensitive, e.g. `Dockerfile`) > extension (`py, sh, yaml`) > file type (UTType).
  - With no matching rule the system default app is used; if the system has no default app either, a dialog lets the user choose and optionally remember the choice.

## 11. External Terminal

ExternalTerminalLauncher.swift, SSHCommandBuilder.swift, AskpassBroker.swift:

- **Launching**
  - First generates a `.command` script readable/writable only by the owner that deletes itself after running; the script then `exec ssh`.
  - Terminal opens the script directly; iTerm2 creates a new window via AppleScript; Ghostty launches with `-e`.
  - Shortcut ⌥⌘T opens a terminal in the current folder.
- **ssh command**
  - Starts with `ssh -t`; all arguments are single-quote escaped; the target host must not start with `-` or contain whitespace.
  - With a selected key, adds `-i` and `IdentitiesOnly=yes`; key-only accounts additionally add `PreferredAuthentications=publickey`, `PasswordAuthentication=no`, `KbdInteractiveAuthentication=no`; with no key, public key authentication is disabled.
  - The remote `cd` is also safely escaped (`~` expands via `$HOME`, relative paths starting with `-` get a `./` prefix).
- **Automatic password fill (SSH_ASKPASS)**
  - The app generates a 32-byte random one-time token that expires after 60 seconds.
  - The helper script exchanges the token for the password over a Unix socket accessible only to the user (0600, with the peer process UID verified); the password is never written to disk or the command line.
  - Only the first password prompt is answered automatically; other prompts (host key confirmation, retry after a wrong password, verification codes, passphrases) are still typed in the terminal.
  - xFinder must be running for this to work.

## 12. Settings Window

SettingsView.swift, with 6 tabs:

- **General**
  - Whether double-clicking a favorite opens it in the browser or a terminal (default: browser).
  - Whether hidden files are shown by default (default: hidden).
  - Maximum concurrent transfers (default 3).
  - Default handling when a file already exists (default: ask).
  - Download directory (default `~/Downloads`).
  - Settings import/export.
  - Updates section (see next section).
- **Keys**: global default key and authentication order (default key first), plus key management.
- **Accounts**: account management.
- **Terminal**: choose Terminal (default), iTerm2 or Ghostty.
- **Open With**: add, edit, delete and reorder rules.
- **Security**: list of trusted host keys and certificates, which can be removed.

## 13. Automatic Updates

UpdateController.swift (including UpdatePanelView and UpdatesSettingsSection), Updates.swift:

- **When to check**: about 5 seconds after launch, at most once per 24 hours; can also be checked manually via xFinder ▸ Check for Updates… or Settings ▸ General ▸ Check Now. Automatic checks show nothing when there is no update.
- **Data source**: the public GitHub Releases API, `GET /repos/tianlan-dev/xFinder/releases/latest` (no token). Drafts and pre-releases are ignored.
- **Choosing a version**: the release tag (`v0.0.2`) is compared with `CFBundleShortVersionString` using semantic versioning (pre-releases sort before their release). A version the user skipped is ignored by automatic checks only.
- **Assets**: the zip is `xFinder-<version>.zip` (falling back to any `xFinder*.zip`); the checksum comes from GitHub's asset digest, else `<zip>.sha256`, else `SHA256SUMS.txt`.
- **Update window**: app icon, "xFinder X is available — you have Y", release notes (Markdown), and Skip This Version / Remind Me Later / Update.
- **Install flow** (one click, no manual steps)
  - Download the zip with a progress bar (Cancel stops it).
  - Verify SHA-256, unzip with `ditto`, strip `com.apple.quarantine`, check the bundle ID, version and code signature (`codesign --verify --deep --strict`; ad-hoc signatures pass).
  - Start a detached helper script, then quit. The helper waits for the old process to exit, moves the old bundle to `xFinder.app.xfinder-backup`, moves the new one into place and opens it. The backup is removed only after the new app launched; if the launch fails, the backup is restored and reopened.
  - When the app or its folder is not writable, the swap runs through `osascript … with administrator privileges`; if the prompt is cancelled the old app is reopened unchanged.
  - Any failure before quitting leaves the installed app untouched and offers Try Again and Open Releases Page.
  - Under App Translocation (opened straight from Downloads) the update is refused with a prompt to move the app to Applications first.

## 14. Build and Release Scripts

- **.github/workflows/release.yml**: on a `v*` tag, runs unit tests, builds an ad-hoc signed Release and publishes `xFinder-<version>.zip`, `xFinder-<version>.dmg` and `SHA256SUMS.txt` to GitHub Releases. `workflow_dispatch` builds and uploads a workflow artifact only.
- **package_release.sh `<version>` `[build]`**: the build and packaging step used by the workflow; also works locally (output in `dist/`).
- **make_app_icon.swift**: draws the app icon in code and generates all sizes.
- Apple Silicon and macOS 15+ only.

## 15. Test Coverage

Tests/xFinderKitTests:

- **Unit tests**
  - Settings inheritance, accounts.
  - ssh command generation, including shell-injection cases.
  - Site library, validation, Open With.
  - Favorites and settings import/export.
  - Private key parsing (checked against `ssh-keygen` fingerprints) and RSA signing.
  - FTP, S3 and WebDAV parsing; S3 signing verified with the examples from the AWS documentation.
  - Transfer engine, askpass, update logic.
- **Online integration tests** (run only when environment variables are set): SFTP, FTP, FTPS, WebDAV, S3, and and the GitHub update check.
