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
- [x] **Client (LCU) refresh — parsing** — champions, wallet, honor, ranked
      stats, last game and behaviour restrictions → penalties are all ported and
      tested in `core/src/lcu.rs`, folded into an account by `apply_snapshot`.
- [x] **Dashboard view-model** (`core/src/view.rs`) — the same `SitePayload`
      shape the HTML renderer reads, built from accounts and tested on Linux.
- [x] **Tauri shell + UI** (`app/`) — the dashboard HTML, made interactive and
      wired to the core via Tauri commands: list, add/edit/delete, the detail
      sheet, filters, and per-account actions. The vault key is sealed with
      Windows DPAPI (replacing the Mac Keychain).
- [~] **League client integration (Windows)** — the live features. The LCU
      transport (lockfile discovery + loopback HTTPS) and the sign-in autofill
      (process control + SendInput) are written in `app/src/lcu.rs` and
      `app/src/automation.rs`. They need a Windows machine with League installed
      to exercise and tune (UIAutomation field targeting, the fuller behaviour
      fold, the account cycle and appear-offline land as that happens).
- [ ] **Hub publishing** — the counts-only snapshot to myprojects.cc (already
      designed for the Mac app in the companion PR).

## Building

**Core (any platform):**

```
cd windows
cargo test -p leaguevault-core
```

**The app (Windows):** builds with the Tauri CLI and the WebView2 runtime
(bundled on Windows 11, a small installer on Windows 10):

```
cd windows\app
cargo install tauri-cli --version "^2"   # once
cargo tauri dev                          # run it
cargo tauri build                        # build an installer
```

See `app/README.md` for the full command surface and what still needs a live
League client to exercise.

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
