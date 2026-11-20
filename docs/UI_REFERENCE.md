# xFinder UI reference

This document describes the intended look of xFinder, based on screenshots of
the original app. Host names, folder names and account names below are
examples only.

## 1. Main window

### Title bar and sidebar

- Unified title bar. Above the sidebar, after the traffic lights:
  - a vertical expand/collapse-all-folders button,
  - a `+` pull-down button (with a chevron),
  - the sidebar toggle.
- `+` menu, in order: **New Server…**, **New Folder…**, separator,
  **Import from ~/.ssh/config**, separator, **Import Favorites…**,
  **Export Favorites…**.
- Sidebar:
  - A rounded search field with a magnifier and the placeholder
    *Search name or address*.
  - Below it, a tree of favorite folders with disclosure chevrons and folder
    outline icons.
  - Server rows show a server (rack) icon and two lines: the name (for
    example `staging app - web01`) and a smaller secondary line
    `<PROTOCOL> · <host>` (for example `SFTP · web01.example.com`), truncated
    at the tail.
  - The selected row has a blue rounded highlight with white text.

### Toolbar (right of the sidebar)

- Back `<`, forward `>`, and up (parent folder).
- Title block: the bold server name, with the current path below it in small
  grey text (for example `/srv/app`).
- Buttons on the right, in order:
  1. open terminal (`>_` in a box),
  2. refresh,
  3. new folder,
  4. upload (tray with an up arrow),
  5. download (tray with a down arrow, disabled without a selection),
  6. go to path (circled right arrow),
  7. show hidden files (eye; shown as a filled blue circle with a white eye
     when on),
  8. disconnect (eject).

### Tabs

- Each tab has a close `x`, a green dot when connected, then the title.
- The active tab has a blue underline.
- `+` at the far right adds a tab.

### Bookmarks bar

- Starts with a bookmark icon, followed by chips.
- Globe chips (for example `logs`, `apps`) are global bookmarks, shown for
  all servers. Chips with a folder-with-badge icon (for example `scripts`,
  `conf`, `var`) are folder or server bookmarks.
- The chip matching the current directory has a light-blue rounded
  background.

#### Dragging a chip or folder over the bar

While a chip or a folder is dragged over the bar, it switches to grouped
drop zones:

- a purple-tinted group labeled **All Servers** (holding the globe chips),
- an orange-tinted group labeled with the favorite folder's name (for example
  `Example Folder`), for folder-level bookmarks,
- a blue-outlined zone at the end reading **This Server**, with a faint
  *Drop here* hint.

The dragged chip shows as a ghost under the cursor, and its original position
is dimmed.

### Breadcrumbs

A grey row below the bookmarks, for example `/ › srv › app`.

### File list (outline view)

- Columns: **Name** (with a sort chevron), **Size**, **Date Modified**,
  **Permissions**, **Owner**, **Group**.
- Folders:
  - have disclosure triangles and blue filled folder icons,
  - sort first while *Keep folders above files* is on (the default);
    otherwise they sort together with files,
  - show `--` as their size.
- Files use plain document outline icons.
- Formats:
  - sizes like `48 KB`, `18 bytes`, `66 MB`;
  - dates like `Nov 11, 2026 at 1:44 PM`;
  - permissions in monospace, like `drwxr-xr-x` and `-rw-------`.
- Rows have alternating backgrounds. The selected row is full-width blue with
  white text.
- Dotfiles are shown at normal weight, not dimmed.

### File context menu

1. Open
2. Open With ›
3. *separator*
4. Rename…
5. Copy
6. Duplicate
7. *separator*
8. Download to Downloads (named after the configured download folder)
9. Download To…
10. *separator*
11. Get Info
12. Change Permissions…
13. Copy Path
14. *separator*
15. Delete…

## 2. Menu bar

- **File**:
  - New Tab ⌘T
  - *separator*
  - Close Tab ⌘W
  - Close Window ⇧⌘W
  - *separator*
  - Import Favorites…
  - Export Favorites…
  - *separator*
  - Import Settings…
  - Export Settings…
- The other menus are Edit, View, Window and Help.

## 3. Settings window

The settings window uses toolbar-style tabs with icons, and the window title
is the tab name. Content uses the grouped form style (rounded inset
sections).

| Tab | Icon |
|---|---|
| General | gearshape |
| Keys | key |
| Accounts | person with a key |
| Terminal | terminal |
| Open With | square and pencil |
| Security | lock shield |

### General

Radio rows put the label on the left and the options at the trailing edge
of the row, like every other control in the form.

- **Double-clicking a favorite**: horizontal radio buttons, *Opens it in the
  browser* / *Opens it in a terminal*.
- **Hidden files (dotfiles)**: radio buttons, *Show by default* / *Hide by
  default*. Footnote: "Applies to all tabs. Each tab can still toggle hidden
  files with ⇧⌘. or the eye button in the toolbar."
- **Keep folders above files**: a switch, on by default. Footnote: "When
  off, folders and files are sorted together by the selected column." The
  change applies live to every tab, including expanded subfolders. (Not in
  the original app.)
- **Transfers** section:
  - *Simultaneous transfers: 5* with a stepper,
  - *When a file already exists* popup (*Ask every time*),
  - *Download folder* showing `~/Downloads` and a *Choose…* button.
- **Import / Export** section:
  - *Import Settings…* and *Export Settings…* buttons.
  - Footnote: "Includes these preferences, Open With rules, the key list
    (file paths only) and saved accounts. Passwords, favorites and trusted
    host keys are not included."
- **Updates** section further down.

### Keys

- *Global default key* popup, for example `id_rsa (ssh-rsa · AbCdEf12)`
  (the type and the first 8 characters of the SHA256 fingerprint).
- *Global auth order* popup, for example *Key first, then password*.
- Explanation: "Only the location of each key file is stored; private keys
  are never copied. Aliases are used only in this app. Servers and folders
  can only use keys added here — other keys in ~/.ssh are never tried
  automatically. Supported: Ed25519, RSA and ECDSA in OpenSSH format
  (passphrase-protected or not) and unencrypted PEM."
- Table columns: Alias, Type, Fingerprint (`SHA256:…`, truncated), Path
  (`~/.ssh/id_rsa`), Status (`OK`).
- Buttons:
  - *Add…*, *Change Location…* and *Forget Saved Passphrase* on the left,
  - *Delete…* on the right,
  - all except *Add…* disabled without a selection.

### Accounts

- Intro: "Saved sign-ins that servers and folders can use: a username with a
  key, a password, or both. Keys come from the Keys tab (or Add Key File… in
  the editor); passwords are kept in the Keychain. Changing an account
  updates every server that uses it."
- Table columns:
  - Name
  - Username
  - Signs in with (`saved password`, `key id_rsa`)
  - Used by (`1 server`, `2 servers`, `8 folders`, `1 folder`)
- Buttons: *Add…* and *Edit…* on the left, *Delete…* on the right.

### Terminal

- *Preferred terminal* popup (Terminal, iTerm2).
- Text: "Terminal mode uses the system ssh and only the key selected for the
  server in this app (IdentitiesOnly). A saved password (the server’s own or
  its account’s) is filled in automatically once; other prompts are answered
  in the terminal."
- Text: "The first time you use iTerm2, macOS asks for permission to let this
  app control iTerm2."

### Open With

- Intro: "Choose which app opens remote files. When you save, the file is
  uploaded back to the server automatically."
- Table columns: **Files** (`.sh`, `.xml`, `.log`) and **Open With** (app
  icon and name).
- Buttons: *Add…*, *Edit…* and *Remove* on the left; up/down reorder arrows
  on the right.
- Footnote: "Matching order: exact file name, then extension, then file type.
  Files without a matching rule open with the system default app; if there is
  none, you are asked to choose one."

### Security

- Heading: "Trusted server host keys (kept by this app, separate from
  ~/.ssh/known_hosts)".
- Each row shows `[host]:port`, then `ssh-ed25519  SHA256:…` in small grey
  monospace.
- *Remove* at the bottom right.

## 4. Folder editor sheet

- A modal sheet in the grouped form style.
- Footer: a divider, then *Cancel* and the blue default *Save* at the bottom
  right. The sheet is fairly tall, with empty space above the footer.
- **Name** row with a right-aligned field; the name is selected on open.
- Section header **Defaults for servers in this folder**:
  - **Account** popup (*None* or an account name).
  - With an account selected, only the Account row is shown: username, key
    and auth order come from the account.
  - With *None*, three more rows appear:
    - **Username**, with the placeholder *Not set (each server decides)*,
    - **Key**, a popup showing *Inherit from global (id_rsa)*,
    - **Auth order**, a popup showing *Inherit from global (Key first, then
      password)*.
- Footnote under the section: "Settings made on a server override these.
  The account is used by servers that have no account or username of their
  own."

## 5. Server editor and New Server sheets

Both use the same sheet style, with a pinned *Cancel* / *Save* footer. New
Server says *Add* instead of *Save*. The content scrolls.

### General

- **Name**: right-aligned and selected on open; placeholder *e.g.
  Production*.
- **Protocol** popup, in order: *SFTP*, *SCP (shell)*, *FTP*, *FTPS
  (explicit)*, *FTPS (implicit)*, *WebDAV (http)*, *WebDAV (https)*, *S3*.
  *SCP (shell)* is not in the original app; it shows the same Key and Auth
  order rows as SFTP.
- **Address**: placeholder *Hostname, IPv4 or IPv6*.
- **Port**: right-aligned; shows the protocol's default port (for example
  `22`).
- **Folder** popup. New Server preselects the folder the user was in.

### Authentication

- **Account** popup:
  - First item: *None (username and password below)*.
  - If the server has no account or username of its own and its folder has
    an account, the first item reads *Inherit from folder Example Folder
    (deploy)* instead.
  - Then a separator and all saved accounts, sorted alphabetically.
- **Summary line**: small grey text under an effective account, computed
  from the resolved settings and naming the source when inherited:
  - "Signs in as deploy with key id_rsa (from folder Example Folder)."
  - "Signs in as ftp_user with the account’s password." (account chosen on
    the server)
- **Inherited folder account**: only a **Username** row follows, with the
  placeholder *Inherit from folder Example Folder: deploy*.
- **Account chosen on the server**: the Username row is hidden.
- **No account**:
  - **Username**: placeholder *Default: <effective username>*, or *Inherit
    from folder X: <username>* when the folder sets one.
  - **Key** popup:
    - *Inherit from global (id_rsa)*, or *Inherit from folder X (…)* when the
      folder sets a key,
    - *No key*,
    - a separator,
    - each key as `alias (type · fingerprint prefix)`.
  - **Auth order** popup: *Inherit from global (Key first, then password)*,
    *Key first, then password*, *Password first, then key*.
  - **Password**: secure field with the placeholder *Optional, asked when
    connecting*.

### Folder

- **Initial folder**: placeholder *Empty = home folder; ~/... supported*.
- A right-aligned *Test* button in the row below.

### Footer

- On the left, an inline red validation message with a warning triangle, for
  example "⚠ Invalid address (expected a hostname, IPv4 or IPv6)".
- *Add* or *Save* is disabled while validation fails. An empty address shows
  the same error.

Popups are standard macOS menu-style pickers, with a checkmark on the
selected item and separators as described.

## 6. Connection failure overlay (not in the original app)

When a tab cannot connect, the browser shows a warning triangle, *Could not
connect*, the reason, and the buttons *Edit Server…* (for saved servers) and
*Try Again*. When the server signed the user in but refused SFTP, the reason
explains this and an extra default button *Use SCP (shell)* switches the
server's protocol to SCP (shell) and connects again.
