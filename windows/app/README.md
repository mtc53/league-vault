# League Vault — the Windows app (Tauri shell)

This crate is the native Windows app: a [Tauri](https://tauri.app) window whose
backend is Rust (reusing `../core`) and whose UI is the same HTML dashboard the
macOS app and the published page use, made interactive and wired to the core
over Tauri commands.

Because it needs WebView2, it builds on Windows. It is deliberately excluded
from the `windows/` cargo workspace so the portable core still tests on any
machine.

## What's here

```
app/
  Cargo.toml            the Tauri crate (path-depends on ../core)
  tauri.conf.json       window, bundle and CSP config
  build.rs              tauri-build
  icons/                app icon set
  src/
    main.rs             Tauri builder + command registration
    state.rs            in-memory vault, %APPDATA%\LeagueVault\accounts.json
    secret.rs           the AES vault key, sealed with Windows DPAPI
    commands.rs         the invoke surface the UI calls
    lcu.rs              lockfile discovery + loopback HTTPS to the League client
    automation.rs       process control + SendInput login autofill
  ui/
    index.html          the dashboard shell (same look as the Mac app)
    app.js              the renderer + editor + per-account actions
```

## The command surface

The UI calls these through `window.__TAURI__.core.invoke`:

- `list_accounts` → the whole vault in the dashboard's view-model shape
- `get_account(id)` / `save_account(account)` / `delete_account(id)`
- `set_password(id, password)` / `has_password(id)` / `copy_password(id)`
- `client_status()` → is League installed / running / connectable
- `refresh_account(id)` / `refresh_current()` → read live data from the client
- `launch_league()` / `open_launcher()` / `kill_league()`
- `sign_in(id)` → open the launcher and type the stored credentials

## Building it

Prerequisites on Windows:

1. [Rust](https://rustup.rs) (stable).
2. The **WebView2 runtime** — already on Windows 11; a small installer on
   Windows 10 (Tauri can also bootstrap it).
3. The Tauri CLI: `cargo install tauri-cli --version "^2"`.

Then, from this folder:

```
cargo tauri dev      # run it, with hot-reload of the UI
cargo tauri build    # produce an installer (.msi / NSIS .exe)
```

The first `dev` run compiles the dependency tree (Tauri, the `windows` crate,
reqwest) and takes a few minutes; later runs are fast.

## Status — what's wired and what needs the live client

Everything compiles and runs offline: the vault loads, accounts list, the
editor adds/edits/deletes, passwords seal with DPAPI, and the dashboard renders
identically to the Mac app.

These talk to a running League client and need it installed to exercise:

- **Refresh** (`lcu.rs`) reads summoner, ranks, champions, wallet, honor, last
  game and behaviour restrictions over the lockfile-authenticated loopback API.
  The behaviour fold currently maps restrictions and queue lockout; low-priority
  seconds and punished-game counts are filled in as they're validated against a
  live client.
- **Sign-in autofill** (`automation.rs`) opens the Riot Client and types the
  stored credentials with `SendInput`. Precise field targeting (UIAutomation)
  is tuned against the real client window; the mechanism — focus the window,
  type username, Tab, password — mirrors what the Mac app did.

These are the pieces to exercise together on a Windows machine with League
installed.
