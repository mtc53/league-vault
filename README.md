# League Vault

A local macOS app for keeping track of your League of Legends accounts:
rank, last played game, server, account name, login, and active penalties.

Everything lives on this Mac. The only network traffic is to Riot's public API,
and only when you press Refresh.

## Running it

The built app is at `/Applications/League Vault.app`.

## Rebuilding after you change the code

```
./build.sh
```

Needs only Xcode Command Line Tools (`swiftc` + the macOS SDK) — no Xcode.
The script compiles `Sources/*.swift`, assembles the `.app` bundle, and ad-hoc
signs it. Copy the result over `/Applications/League Vault.app` to install it.

## What each field is for

### Adding an account

**A username and password is all you need.** The new-account form asks for nothing else:
sign in to the account in the League client, press Refresh, and the entry links itself
to whoever is signed in — Riot ID, server, rank, last game, champions, wallet, honor and
penalties all fill in, and the nickname takes the account's name.

Until it is linked, the entry shows its login as its name, and Refresh says so rather
than claiming the client is signed in to something else. **Edit** still exposes every
field for anything you want to set by hand.

| Field | Filled by |
|---|---|
| Username and password | you |
| Nickname, folder | you, or the account name on first link |
| Riot ID, server | first Refresh |
| Full access (FA / NFA) | you |
| Rank (Solo/Duo + Flex), LP, W/L | Refresh, or by hand |
| Last played game (champion, queue, result, KDA, length, time) | Refresh, or by hand |
| Summoner level, profile icon | Refresh |
| Days since the last game | Refresh |
| Who played that game (me / someone else) | you |
| Login username + password | you |
| Penalties | you — see below |

### Importing a combo list

**Add ▸ Import combo list…** (⌘O) takes a plain `.txt` with one account per line in the
form:

```
username;password
```

Only the first semicolon splits the line, so a password may contain more of them. Blank
lines and lines starting with `#` are ignored. A username already in the vault is
skipped, as is a username that repeats within the file, so re-importing a longer list
only adds what is new.

Before it commits, the sheet shows how many accounts are new, how many were skipped as
duplicates, and any lines that had no `;` — with their line numbers, so a malformed file
is easy to fix. You can drop the batch into a folder on the way in.

Passwords are encrypted as they are stored, exactly like a password typed by hand.
Everything else about each imported account fills itself in the first time it signs in to
the client and is refreshed.


## Idle time

Every account carries one number: **how many days since the last game anyone played on
it.** It is on the sidebar row, on the detail header, on the web dashboard's cards and
list, and it is a sort option (**Days idle**) in both.

The number comes from the last game the client reported, so it only moves when the
account is refreshed. An account with no game on record shows a dashed **never played**
rather than a fabricated zero.

Past three months untouched, the badge turns amber.

### Who played it

The client cannot tell a game you played from a game somebody else played — they look
identical — so you say which, in the account's **Last Played Game** card: **Me**,
**Someone else**, or leave it at **Not said**.

It changes what the idle number means. Marked as yours, the badge greys out and gets a
dot: you already know when you last played it, and that says nothing about whether anyone
else has been on the account. Marked as someone else's, the badge stays lit, because then
it is genuinely tracking how long the account has sat.

The note survives refreshes for as long as it is the same match. A genuinely new game
starts out unattributed again, because nothing about the new game tells League Vault who
was at the keyboard.

The web dashboard filters on it — **Last played by me / by someone else / not said** —
and its **Longest idle** headline leaves out the games you played yourself.

## Folders

Each account can be filed under a folder (Main, Smurfs, Duo accounts — whatever you
like). The sidebar groups by folder with an **Unfiled** section last; the *Folders*
checkbox at the bottom turns grouping off for one flat list.

- **Drag a row onto a folder header** to move it there. The header shows a dashed
  highlight as you hover, and the account stays selected after the drop.
- Or set a folder in the editor's **Account** tab, or right-click a row → **Move to**.
- Right-click a folder header to **Rename** it (updates every account in it) or
  **Empty** it (unfiles them; no account is deleted).

Dragging onto the **Unfiled** header removes an account from its folder.

Folders exist wherever an account references them — there is no separate folder list
to keep in sync, so removing the last account from a folder makes the folder go away.

## Champions

Refresh pulls the account's owned-champion list from the client. The detail pane shows
the count, a filter box, and the names as a grid (first 24, with a *Show all*).

To find which accounts own a champion, click **Champion** at the bottom of the sidebar.
The picker lists every champion across the whole vault with the number of accounts that
own it; pick one and the sidebar narrows to those accounts, with a chip showing the
active filter until you clear it.

The filter matches the champion exactly, so filtering on **Vi** does not drag in Viktor
accounts — while the picker's own search box is a substring, so typing `vi` still finds
Viktor. The sidebar search scope also has a **Champion** mode for typing a name directly.

Only accounts you have refreshed at least once have a champion list.

## Blue essence and RP

Both come from the client's wallet on Refresh and show as chips in the account header.
They are also editable by hand in the editor's **Account** tab.

Riot has moved this endpoint and renamed its keys more than once, so Refresh tries five
shapes in order and merges what comes back:

1. `/lol-inventory/v1/wallet?currencyTypes=["lol_blue_essence","RP"]`
2. `/lol-inventory/v1/wallet`
3. `/lol-store/v1/wallet`
4. `/lol-inventory/v1/wallet/lol_blue_essence` (bare number)
5. `/lol-inventory/v1/wallet/RP` (bare number)

Keys are matched case-insensitively across `lol_blue_essence` / `blueEssence` /
`blue_essence` / `ip`, and `RP` / `riotPoints` / `riot_points` / `lol_rp`; values may be
numbers, doubles or strings. If every shape fails, the client sheet shows a **wallet
unavailable** chip rather than silently showing nothing.

## Quick prep

One button in the **League Client** sheet that makes an account look untouched. Each
step is a toggle, and the choices are remembered:

| Step | Default | Call |
|---|---|---|
| Set the profile icon | on, **6923** with a fallback to **29** | `PUT /lol-summoner/v1/current-summoner/icon` |
| Clear challenge badges, title and banner | on | `POST /lol-challenges/v1/update-player-preferences/` ×3 |
| Remove all friends | **off** | `DELETE /lol-chat/v1/friends/{pid}` per friend |

Quick prep offers exactly two icons:

- **6923** — the dark-elf icon with the red tear streaks, the default
- **29** — owned by every account, the fallback

Before setting 6923 it checks the account's inventory
(`/lol-inventory/v2/inventory`, with three older shapes as fallbacks). If the account
does not own it, **29** is set instead and the report says so — Riot resets an unowned
icon server-side, so setting one that is not owned does not stick.

If the inventory cannot be read at all, the preference is used as-is rather than being
second-guessed. To set any other icon, use **Change icon…** next to the Riot ID, which
still browses all ~5,000.

The challenge reset sends `challengeIds: []`, `title: ""` and `bannerAccent: ""` as three
separate calls, so one rejection does not sink the others — the report says which parts
went through.

Friend removal stays off by default and is the only irreversible step; when it is on the
confirmation button turns destructive and names the count. Everything else can be set
back by hand.

## Profile icons

The **League Client** sheet has **Change icon…** next to the Riot ID. It browses every
profile icon Data Dragon publishes — about 5,000, newest first — and applies one with
`PUT /lol-summoner/v1/current-summoner/icon`.

**Ownership is not checked.** This is the same call the client's own picker makes,
without the inventory filter in front of it, so any id works. Riot may reset an unowned
icon server-side; if it snaps back, that is Riot's doing.

Riot publishes no *names* for profile icons — Data Dragon and Community Dragon both
expose only ids and image paths — so the search box filters by id, not by champion.
Find an id on a community icon site and type it in, or scroll the grid.

## Signing in

The **Sign in** button on an account opens a sheet that gets the Riot Client to the
login screen and fills the form:

1. **Quit Riot Client** if it is running (it is signed in to someone else), or **Open**
   it if it is not
2. **Fill username & password** — focuses the client, counts down three seconds so you
   can click the username field, then types the username, tabs, and types the password
3. Copying either field by hand is still there as a fallback

**Return is never sent.** The form is filled; pressing enter is yours.

### Accessibility permission

Synthesising keystrokes into another application requires macOS Accessibility
permission, under Privacy & Security → Accessibility.

macOS ties that permission to the app's **code signature**. An ad-hoc signature changes
on every single build, so the app would silently lose permission each time it was
rebuilt — while still appearing ticked in the list, because the entry belonged to a
build that no longer existed.

`tools/make-signing-cert.sh` fixes that. It creates a local self-signed code-signing
certificate in your login keychain, and `build.sh` uses it whenever it is present, so
every build carries the same designated requirement:

```
designated => identifier "com.corbin.leaguevault" and certificate leaf = H"8351054e…"
```

Grant Accessibility once and it survives rebuilds. The certificate is local, is used for
nothing but this app, and can be removed with:

```
security delete-certificate -c "League Vault Local Signing"
```

**Switching from ad-hoc to the certificate changes the signature once**, so the first
time you will need to remove the stale League Vault entry from the Accessibility list
with the − button and add the app again. After that it stays.

The sheet's permission warning is advisory only — the Fill button always works, because
the check can be wrong and the keystrokes are the real test.

### How the filling works

Keystrokes go to whichever app is frontmost, one UTF-16 unit at a time with a small gap
— Electron-based clients drop input posted faster than they can consume it. The password
is read from the vault at the moment you press the button and never touches the
clipboard.

## Friends

The **League Client** sheet lists the signed-in account's friends and offers
**Remove All Friends…** — `DELETE /lol-chat/v1/friends/{pid}` for each, paced at
roughly eight per second so the chat service keeps up.

This is irreversible and hits your real account immediately, so it sits behind a
confirmation that names the account and the exact count. There is no undo in the
client; re-adding means sending every request again.

## Diagnostics

The **League Client** sheet has a collapsible *Diagnostics* section: type any LCU path,
press Send, and it shows the raw reply pretty-printed, with a Copy button. Numbered
shortcuts hit each wallet candidate above.

Use it when a field comes back empty — the endpoint that works on your client is
discoverable in a few clicks, and the response tells you which key names it uses.

## Peak rank

Riot exposes no peak-rank endpoint anywhere, so each queue has a **Peak tier**,
**Peak division** and a free-text **When** ("S13 split 2") that you fill in yourself.

A refresh never touches it — the client knows nothing about peak rank, so the recorded
value is carried across rather than overwritten with a blank one. The single exception
is upward: if the live rank is *above* the recorded peak, the peak is raised to match,
because it plainly is the new peak. Your note is kept either way, and the editor can
still correct a peak in any direction.

Peak rank is what an unranked account shows in the sidebar — `Unranked · peak Diamond II`
— tinted with the peak's colour instead of grey. Sorting by Rank puts unranked accounts
below every ranked one, but orders them among themselves by peak.

## FA / NFA

Each account records whether you hold its original registration email:

- **FA** — full access. You control the email, so the account can be recovered and the
  email changed.
- **NFA** — no email access. The registration email belongs to someone else; the account
  can be recalled and cannot be fully secured.
- **Not recorded** — the default.

Set it in the editor's **Account** tab. It shows as a green/orange badge in the sidebar
and a chip in the header, with the full explanation in the Login card.

Searching `fa` or `nfa` matches on this field — as whole words, so an account called
"Fabio" is not treated as FA. (Name matches still apply, so searching `fa` returns both
name hits and FA accounts.)

## u.gg

Every account with a full Riot ID gets a u.gg profile link
(`u.gg/lol/profile/<platform>/<Name>-<TAG>/overview`):

- **Copy u.gg** button in the detail header
- Right-click a row → **Copy u.gg Link** / **Open on u.gg**
- The overflow (•••) menu has both as well

## Quick prep

One button in the **League Client** sheet that makes an account look untouched. Each
step is a toggle, and the choices are remembered:

| Step | Default | Call |
|---|---|---|
| Set the profile icon | on, **6923** with a fallback to **29** | `PUT /lol-summoner/v1/current-summoner/icon` |
| Clear challenge badges, title and banner | on | `POST /lol-challenges/v1/update-player-preferences/` ×3 |
| Remove all friends | **off** | `DELETE /lol-chat/v1/friends/{pid}` per friend |

Quick prep offers exactly two icons:

- **6923** — the dark-elf icon with the red tear streaks, the default
- **29** — owned by every account, the fallback

Before setting 6923 it checks the account's inventory
(`/lol-inventory/v2/inventory`, with three older shapes as fallbacks). If the account
does not own it, **29** is set instead and the report says so — Riot resets an unowned
icon server-side, so setting one that is not owned does not stick.

If the inventory cannot be read at all, the preference is used as-is rather than being
second-guessed. To set any other icon, use **Change icon…** next to the Riot ID, which
still browses all ~5,000.

The challenge reset sends `challengeIds: []`, `title: ""` and `bannerAccent: ""` as three
separate calls, so one rejection does not sink the others — the report says which parts
went through.

Friend removal stays off by default and is the only irreversible step; when it is on the
confirmation button turns destructive and names the count. Everything else can be set
back by hand.

## Profile icons

Refresh stores the account's `profileIconId`, and the image comes from Riot's
Data Dragon CDN (public static files, no API key). Icons are cached under
`~/Library/Caches/LeagueVault/profileicons`, and the patch version is looked up
once a day. Until an icon loads, the row shows tinted initials.

### Penalties: partly automatic

The client's Behaviour Standing panel shows active penalties, so some of this
*is* reachable over the LCU — the public web API is what never exposed it.

**Imported on Refresh.** `/lol-honor-v2/v1/profile` gives the honor level and the
recovery progress the panel labels "Honor Downgrade — n Games":

```json
{"honorLevel":2,"rewardsLocked":false,
 "redemptions":[{"eventType":"REPUTATION_ELIGIBLE_GAME_PLAYED","remaining":7,"required":10}]}
```

That becomes a **Honor downgrade** penalty reading "7 of 10 eligible games to
recover · currently Honor 2", tagged **from client**, plus an Honor chip on the
account.

**Still by hand.** Queue delay and team voice mute have not been located yet —
the client serves them from an endpoint the `/help` catalogue did not reveal.
Use **Scan for penalty endpoints** in the League Client sheet to hunt for it: it
reads the client's own API catalogue, filters for honor / behaviour / restriction
/ reputation / voice / dodge paths, reads each one, and reports which answered
with data, which answered empty, and whether `/help` worked at all.

**Manual records are never clobbered.** A refresh replaces only penalties tagged
`client`; anything you typed stays put. Either kind drives the sidebar warning
badge and the **Penalties only** filter.

## Renaming an account

The **League Client** button in the toolbar opens a sheet that:

- finds the running client (`LeagueClientUx`) and reads `--app-port` and
  `--remoting-auth-token` from its command line, authenticating as `riot:<token>`;
- shows who is signed in — Riot ID, region, level, profile icon;
- **changes the Riot ID** via `POST /lol-summoner/v1/save-alias` with
  `{"gameName", "tagLine"}`, behind a confirmation that spells out old → new;
- **imports the signed-in account into the vault**, or updates the matching entry,
  with rank and last game included — no Riot API key needed at all.

Things worth knowing:

- It renames *whichever account is signed in to the client right now*, not an arbitrary
  entry in your vault. The sheet shows you which that is before you touch anything.
- Riot enforces name availability and the change cooldown server-side. The client's own
  error message is passed straight through.
- Nothing leaves the machine: the connection is loopback, the certificate is the
  client's self-signed one (accepted only for `127.0.0.1`), and the token dies with the
  client.


**Refresh also keeps up with renames done elsewhere.** Accounts are matched by PUUID,
which is stable across renames, so Refresh pulls the current Riot ID and reports
`Old#TAG → New#TAG` in the banner.

## Your server

One SSH connection, used for one thing: putting the web dashboard on your Windows
machine. Settings → **Your server**.

SSH rather than a Windows file share, because the server is remote — SMB over the open
internet is a bad idea, while OpenSSH ships with Windows 10 and authenticates with a key
instead of a password.

**On this Mac:** fill in the address, the Windows username and the port (22 unless you
moved it), then press **Create key**. That writes `~/.ssh/leaguevault_ed25519`. Press
**Copy public key**.

**On the Windows server**, in PowerShell **as Administrator**:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

```powershell
Start-Service sshd; Set-Service -Name sshd -StartupType Automatic
```

```powershell
New-NetFirewallRule -DisplayName "OpenSSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
```

Then paste the public key in. An **administrator** account on Windows does not read
`~/.ssh/authorized_keys` — it reads one shared file instead, which catches everybody out:

```powershell
Add-Content C:\ProgramData\ssh\administrators_authorized_keys "PASTE-THE-KEY-HERE"
```

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

(For a non-administrator account it is `C:\Users\<you>\.ssh\authorized_keys` and no
`icacls` is needed.)

Forward port 22 on the router if the machine is not on the same network as the Mac.

Back on the Mac, press **Test connection**.

### Paths on Windows

Windows' SFTP subsystem exposes drives beneath a single root, so `C:\LeagueVaultWeb`
travels as `/C:/LeagueVaultWeb`. League Vault adds that leading slash for you — type the
path the ordinary way. A path with no drive letter is taken relative to the folder an SSH
session starts in, which is `C:\Users\<you>`.

## Refreshing by itself

Settings → **Refresh by itself**, on by default.

League Vault watches for the League client and refreshes the matching entry the moment
somebody signs in — rank, LP, last game, champions, wallet, penalties, profile icon.
Switching accounts inside the client refreshes the new one too, and closing and reopening
the client refreshes again even for the same account.

If the web dashboard is set to republish on change, the page is pushed out immediately
after, rather than waiting for the usual delay: signing in and seeing the page update is
one motion.

### How it finds the entry

By PUUID first, then by Riot ID. Failing both, an entry you added with only a username
and password has no identity yet and is waiting to adopt one — so it does, **but only
when it is the only such entry**. With two of them waiting League Vault will not guess
which is which; it says so and leaves them alone until you refresh one by hand.

If nothing matches at all you get a note naming the account that signed in, not a silent
no-op.

### What it costs

There is nothing to subscribe to — the client publishes its port and token on its own
command line and nothing else — so this polls. Every 15 seconds while no client is
running, every 5 while one is up but nobody has signed in, every 20 once the current
sign-in has been dealt with. Each poll is one `ps`, and reading the account is a handful
of requests to `127.0.0.1`.

## Publishing a web dashboard

Settings → **Publish a web dashboard** turns the vault into a single browsable web page
and drops it on your Windows server. It is a shop-style catalogue
of your own accounts: splash-art cards, rank crests, champion pools, wallets, penalties,
and a filter bar over the top.

It is one file. `index.html` carries the page and the data together — no database, no
PHP, nothing running server-side, nothing to keep patched. Republishing overwrites that
one file.

### What is on it

Grid view gives each account a card fronted by the splash art of whatever it last played
(or a stable pick from its pool when it has never been refreshed), with the folder,
level, both ranks, champion count, blue essence, RP, server, FA/NFA, how long it has sat
idle, and a red banner across the top of the card for anything blocking play — a queue
delay, a dodge timer, a suspension.

List view is the same accounts as a dense table, sortable by rank, level, champions,
essence, RP or days idle.

Clicking either opens the full account: solo and flex with win rates and peak, the
wallet, the last game, every penalty with its countdown, the whole champion pool with
portraits, your notes, and buttons for u.gg and copying the Riot ID.

The filter bar covers folder, server, rank, FA/NFA, penalty status, idle time, who
played last and champion, plus a search box that matches names, logins, folders, notes
and champions —
typing `viktor` leaves only the accounts that own him. `/` focuses the search.

Art comes straight from Riot's CDNs to whoever is looking at the page, so your server
only ever serves the one HTML file.

### Passwords are never on it

Not encrypted, not hashed, not present. The page has no field for them.

Login *names* are only included when the page is locked, and only when you tick
**Include login names on the page**.

### The lock

On by default, and worth leaving on: the page is going somewhere anyone can reach.

With it on, what actually sits on the server is ciphertext — AES-256-GCM under a key
derived from your page passphrase with PBKDF2-HMAC-SHA256, 210,000 iterations, exactly
the way an encrypted archive is. The browser asks for the passphrase and decrypts it locally
with WebCrypto. Someone who finds the address gets a lock screen and a blob.

With it off, everyone who reaches the address can read every account name, rank, server
and penalty.

The page passphrase is stored in your login Keychain under `web-passphrase`, so an
automatic publish can run without asking.

### Setting up the Windows side

You need the SSH part working first — see **Your server** above.

**If you already run a web server on that machine,** you are done: point League Vault's
*Folder the web server serves* at that server's web root (`C:/inetpub/wwwroot/vault`, or
wherever) and skip the rest.

**If you do not,** the shortest path is Caddy — one .exe, no installer. In PowerShell
**as Administrator** on the Windows server:

```powershell
mkdir C:\LeagueVaultWeb
```

```powershell
Invoke-WebRequest "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile C:\LeagueVaultWeb\caddy.exe
```

```powershell
New-NetFirewallRule -DisplayName "League Vault web" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

```powershell
schtasks /create /tn "LeagueVaultWeb" /tr "C:\LeagueVaultWeb\caddy.exe file-server --root C:\LeagueVaultWeb --listen :8080" /sc onstart /ru SYSTEM /rl HIGHEST /f
```

```powershell
schtasks /run /tn "LeagueVaultWeb"
```

That last one starts it now; the task restarts it on every boot. Check it is up with
`Invoke-WebRequest http://localhost:8080` — a 404 is a fine answer at this point, because
nothing has been published yet. A refused connection is not.

Then forward port **8080** to that machine on your router, so `4098.duckdns.org:8080`
reaches it from outside. (Reaching it only over the LAN or through Windows App needs no
forwarding — use the machine's local address instead.)

Finally, in League Vault → Settings → Publish a web dashboard:

- **Folder the web server serves** — `C:/LeagueVaultWeb`
- **Address to open** — `http://4098.duckdns.org:8080`
- Set a page passphrase and press **Save passphrase**
- Press **Publish now**

**Preview on this Mac** renders the same page to
`~/Library/Application Support/LeagueVault/web/index.html` and opens it, with no server
involved — worth doing first to see what you are about to publish.

### Keeping it current

**Republish whenever the vault changes** publishes 30 seconds after any change, so a
burst of edits is one publish rather than twenty. An automatic refresh skips that wait and
publishes at once. Leave the setting off to publish only when you press the button.

Publishing writes `index.html.part`, deletes the old `index.html`, then renames — so a
dropped connection never leaves a half-written page being served.

## Where the data is

`~/Library/Application Support/LeagueVault/accounts.json`, mode 600.

Passwords in that file are AES-256-GCM ciphertext. The encryption key is a
random 32 bytes stored in your login Keychain under the service
`com.corbin.leaguevault`, item `vault-key`. Delete that Keychain item and the stored
passwords become unrecoverable — the rest of the data still reads fine.

Earlier versions also stored a Riot web API key at `riot-api-key` in the same service.
That feature is gone; if you ever saved a key, the leftover item can be deleted with:

```
security delete-generic-password -s com.corbin.leaguevault -a riot-api-key
```

Copying a password puts it on the clipboard for 45 seconds, then clears it
(unless you have copied something else in the meantime).

Settings → Export writes a plain JSON copy. Passwords are excluded unless you
tick the box; if you tick it, the exported file contains them in the clear.

This is a vault, not an autologin tool. It never signs in anywhere for you.

## Rebuilding the app icon

The app icon is profile icon **6923** — the same one quick prep prefers — masked into
the Big Sur rounded square with a small margin so it sits correctly beside other Dock
icons:

```
curl -o build/icon6923.png \
  https://ddragon.leagueoflegends.com/cdn/16.17.1/img/profileicon/6923.png
swift tools/makeicon-from-image.swift build/icon6923.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Any square PNG works as the source. `tools/makeicon.swift` still draws the original
shield-and-keyhole icon if you want it back.

macOS caches app icons aggressively; after replacing the bundle, `touch` it and
`killall Dock` to see the change.
