# League Vault for Windows

A Windows port of League Vault that keeps the same features and the same look.

## Why this shape

The macOS app already ships a complete HTML/CSS dashboard (`Resources/dashboard.html`)
that the native window was built to mirror — same layout, same palette. The
Windows port reuses that HTML as the actual UI inside a **Tauri** shell, with a
**Rust** backend doing the logic. That gets a genuinely identical interface and
a native `.exe`, without rebuilding the whole UI from scratch.

```
windows/
  core/        platform-independent heart — model, storage, scoring, Riot API
               (no GUI or OS deps; builds and `cargo test`s anywhere)
  app/         the Tauri shell: wires core to the HTML UI and to Windows
               automation (built on Windows, with WebView2)
```

## Status

This is a staged port. What's done and what's next:

- [x] **Core data model** (`core/src/models.rs`) — accounts, ranks, last game,
      penalties, champions, wallet, access level, all the display/sort/idle
      logic. JSON shape matches the macOS `accounts.json`, so a vault carries
      across (see Migrating below).
- [x] **Storage + password crypto** (`core/src/store.rs`) — load/save
      `accounts.json`, and AES-256-GCM sealing in the same format CryptoKit
      used, so the encryption is compatible.
- [~] **Client (LCU) refresh** — the parsing of the League client's responses
      (champions, wallet, honor, behaviour restrictions → penalties) is ported
      and tested in `core/src/lcu.rs`. Rank/last-game parsing and the loopback
      transport (lockfile discovery + HTTPS) are next; the transport is
      Windows-specific.
- [ ] **Tauri shell + UI** — the dashboard HTML wired to the core via Tauri
      commands; the account editor, detail sheet, filters.
- [ ] **League client integration (Windows)** — the live features. On macOS
      these use Accessibility + input injection; on Windows they become
      UIAutomation + SendInput, talking to the LCU (League Client API):
      auto-detect sign-in, autofill login, the account cycle, appear-offline.
      These need a Windows machine with League installed to test.
- [ ] **Hub publishing** — the counts-only snapshot to myprojects.cc (already
      designed for the Mac app in the companion PR).

## Building

**Core (any platform):**

```
cd windows
cargo test -p leaguevault-core
```

**The app (Windows):** once the `app/` Tauri crate lands, it builds with the
Tauri CLI and the WebView2 runtime (bundled on Windows 11, a small installer on
Windows 10). Instructions will be here as that stage lands.

## Migrating your vault from the Mac

Copy `~/Library/Application Support/LeagueVault/accounts.json` to
`%APPDATA%\LeagueVault\accounts.json`. Everything loads — labels, ranks, last
games, penalties, champions, notes.

**Passwords are the exception:** they're encrypted with a key kept in the Mac
Keychain, which can't move to Windows. So stored passwords are re-entered once
on Windows; everything else comes straight across.

## The macOS app is untouched

This all lives under `windows/`. The Swift app in `Sources/` is unchanged and
still builds with `build.sh`.
