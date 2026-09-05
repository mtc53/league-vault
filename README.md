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

| Field | Filled by |
|---|---|
| Nickname, folder, Riot ID, server | you |
| Full access (FA / NFA) | you |
| Rank (Solo/Duo + Flex), LP, W/L | Refresh, or by hand |
| Last played game (champion, queue, result, KDA, length, time) | Refresh, or by hand |
| Summoner level, profile icon | Refresh |
| Login username + password | you |
| Penalties | you — see below |

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

To find which account owns a champion, switch the sidebar search scope from **All
fields** to **Champion** and type a champion name — the list narrows to accounts that
own it. Only accounts you have refreshed at least once have a champion list.

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
| Set the profile icon | on, icon **6923** | `PUT /lol-summoner/v1/current-summoner/icon` |
| Clear challenge badges, title and banner | on | `POST /lol-challenges/v1/update-player-preferences/` ×3 |
| Remove all friends | **off** | `DELETE /lol-chat/v1/friends/{pid}` per friend |

Icon 6923 is the dark-elf icon with the red tear streaks. Change it in the field or
with **Pick…**, and quick prep remembers the new one.

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
| Set the profile icon | on, icon **6923** | `PUT /lol-summoner/v1/current-summoner/icon` |
| Clear challenge badges, title and banner | on | `POST /lol-challenges/v1/update-player-preferences/` ×3 |
| Remove all friends | **off** | `DELETE /lol-chat/v1/friends/{pid}` per friend |

Icon 6923 is the dark-elf icon with the red tear streaks. Change it in the field or
with **Pick…**, and quick prep remembers the new one.

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

### Penalties are manual on purpose

Riot publishes no API for bans, chat restrictions, ranked restrictions or
low-priority queue. Nothing can fetch them, so you record them in an account's
**Penalties** tab. The app computes whether one is still active from its end
date, shows a warning badge in the sidebar, and the **Penalties only** filter
at the bottom of the sidebar narrows the list to accounts currently serving one.

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

## Rebuilding the icon

```
swift tools/makeicon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```
