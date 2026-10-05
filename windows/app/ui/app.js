"use strict";

/* League Vault — Windows. The renderer is the same one the macOS app and the
   published web page use; here it reads the vault live from the Rust core over
   Tauri commands, and the detail sheet and editor write back through them. */

const invoke = window.__TAURI__.core.invoke;

/* ------------------------------------------------------------------ *
 *  Constants
 * ------------------------------------------------------------------ */
const CD = "https://raw.communitydragon.org/latest";
const GD = CD + "/plugins/rcp-be-lol-game-data/global/default";
const CREST = t =>
  CD + "/plugins/rcp-fe-lol-static-assets/global/default/images/ranked-mini-crests/"
  + String(t || "unranked").toLowerCase() + ".svg";
const TIERS = ["UNRANKED","IRON","BRONZE","SILVER","GOLD","PLATINUM","EMERALD","DIAMOND","MASTER","GRANDMASTER","CHALLENGER"];
const DIVS  = ["I","II","III","IV"];
const APEX  = new Set(["MASTER","GRANDMASTER","CHALLENGER"]);
const tierVar = t => "var(--" + String(t || "unranked").toLowerCase() + ")";

const REGIONS = [
  ["na1","NA"],["br1","BR"],["la1","LAN"],["la2","LAS"],["euw1","EUW"],["eun1","EUNE"],
  ["tr1","TR"],["ru","RU"],["me1","ME"],["kr","KR"],["jp1","JP"],["oc1","OCE"],
  ["ph2","PH"],["sg2","SG"],["th2","TH"],["tw2","TW"],["vn2","VN"]
];

let VAULT = null;        // { accounts, publishedAt, origin, title }
let champById = {};      // 112 -> { name, alias }
let champByName = {};    // "Kai'Sa" -> { id, alias }

/* ------------------------------------------------------------------ *
 *  Helpers
 * ------------------------------------------------------------------ */
const $  = s => document.querySelector(s);
const el = (t, c, h) => { const n = document.createElement(t); if (c) n.className = c; if (h != null) n.innerHTML = h; return n; };
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const num = n => (n == null ? "—" : Number(n).toLocaleString("en-US"));

function toast(message, bad) {
  const prev = $(".toast");
  if (prev) prev.remove();
  const t = el("div", "toast" + (bad ? " bad" : ""), esc(message));
  document.body.append(t);
  setTimeout(() => t.remove(), bad ? 5000 : 2600);
}

function ladder(tier, div) {
  if (!tier || tier === "UNRANKED") return 0;
  const ti = TIERS.indexOf(tier);
  if (ti < 0) return 0;
  const di = APEX.has(tier) ? 4 : 4 - Math.max(0, DIVS.indexOf(div || "IV"));
  return ti * 10 + di;
}
function rankText(r) {
  if (!r || !r.tier || r.tier === "UNRANKED") return "Unranked";
  const t = r.tier[0] + r.tier.slice(1).toLowerCase();
  return APEX.has(r.tier) ? t : t + " " + r.div;
}
function peakText(r) {
  if (!r || !r.peakTier || r.peakTier === "UNRANKED") return null;
  const t = r.peakTier[0] + r.peakTier.slice(1).toLowerCase();
  return APEX.has(r.peakTier) ? t : t + " " + r.peakDiv;
}
function daysSince(iso) {
  if (!iso) return null;
  return Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86400000));
}
function ago(iso) {
  const d = daysSince(iso);
  if (d == null) return "never";
  if (d === 0) return "today";
  if (d === 1) return "yesterday";
  if (d < 30) return d + " days ago";
  if (d < 365) { const m = Math.round(d / 30); return m + (m === 1 ? " month ago" : " months ago"); }
  return (d / 365).toFixed(1) + " years ago";
}
function iconURL(id) { return CD + "/game/assets/ux/summonericons/profileicon" + (id == null ? 29 : id) + ".png"; }
function faceChampionId(a) {
  if (a.lastGame) {
    if (a.lastGame.championId != null) return a.lastGame.championId;
    const known = champByName[a.lastGame.champion];
    if (known) return known.id;
  }
  if (a.champions && a.champions.length) {
    let h = 0;
    for (const ch of a.id) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return a.champions[h % a.champions.length].id;
  }
  return null;
}
function splashURL(id) {
  const c = id == null ? null : champById[id];
  return c ? "https://ddragon.leagueoflegends.com/cdn/img/champion/splash/" + c.alias + "_0.jpg" : null;
}
function squareURL(id) { return id == null ? null : GD + "/v1/champion-icons/" + id + ".png"; }

/* ------------------------------------------------------------------ *
 *  Champion lookups (cached in this browser, never on the server)
 * ------------------------------------------------------------------ */
function indexChampions(list) {
  champById = {}; champByName = {};
  for (const c of list) {
    if (!c || c.id == null || c.id < 0 || !c.alias) continue;
    if (champByName[c.name] && c.id > 1000) continue;
    champById[c.id] = { name: c.name, alias: c.alias };
    champByName[c.name] = { id: c.id, alias: c.alias };
  }
}
async function loadChampions() {
  try {
    const cached = JSON.parse(localStorage.getItem("lv.champs") || "null");
    if (cached && Date.now() - cached.at < 7 * 86400000) { indexChampions(cached.list); return; }
  } catch (e) {}
  try {
    const list = await (await fetch(GD + "/v1/champion-summary.json")).json();
    indexChampions(list);
    const slim = list.map(c => ({ id: c.id, name: c.name, alias: c.alias }));
    try { localStorage.setItem("lv.champs", JSON.stringify({ at: Date.now(), list: slim })); } catch (e) {}
  } catch (e) {}
}

/* ------------------------------------------------------------------ *
 *  Filter state
 * ------------------------------------------------------------------ */
const FILTER_KEYS = ["q", "folder", "region", "tier", "access", "status", "idle", "player", "champ"];
const state = {
  q: "", folder: "", region: "", tier: "", access: "", status: "", idle: "", player: "", champ: "",
  sort: localStorage.getItem("lv.sort") || "rank",
  view: localStorage.getItem("lv.view") || "grid"
};
const UNFILED = " unfiled";
function option(v, label) { const o = document.createElement("option"); o.value = v; o.textContent = label; return o; }

function fillSelects(accounts) {
  const uniq = arr => [...new Set(arr.filter(Boolean))].sort((a, b) => a.localeCompare(b));
  const folders = uniq(accounts.map(a => a.folder));
  $("#fFolder").replaceChildren(option("", "All folders"), ...folders.map(f => option(f, f)),
    ...(accounts.some(a => !a.folder) ? [option(UNFILED, "Unfiled")] : []));
  $("#fRegion").replaceChildren(option("", "All servers"),
    ...uniq(accounts.map(a => a.region.short)).map(r => option(r, r)));
  const present = TIERS.filter(t => accounts.some(a => a.ranks.solo.tier === t || a.ranks.flex.tier === t));
  $("#fTier").replaceChildren(option("", "Any rank"),
    ...present.map(t => option(t, t === "UNRANKED" ? "Unranked" : t[0] + t.slice(1).toLowerCase())),
    option("__ranked", "Ranked this split"));
  $("#fAccess").replaceChildren(option("", "FA / NFA — any"), option("FA", "FA — full access"),
    option("NFA", "NFA — no email"), option("__none", "Not recorded"));
  $("#fStatus").replaceChildren(option("", "Any status"), option("__clean", "Nothing wrong"),
    option("__any", "Has a penalty"), option("__crit", "Blocked from playing"),
    option("__delay", "Queue delay"), option("__dodge", "Dodge timer"),
    option("__ban", "Suspended or banned"));
  $("#fIdle").replaceChildren(option("", "Any idle time"),
    option("__7", "Idle under a week"), option("__30", "Idle over a month"),
    option("__90", "Idle over 3 months"), option("__365", "Idle over a year"),
    option("__never", "Never played"));
  $("#fPlayer").replaceChildren(option("", "Played by anyone"),
    option("ME", "Last played by me"), option("SOMEONE_ELSE", "Last played by someone else"),
    option("__unsaid", "Not said who played"));
  $("#fChamp").replaceChildren(option("", "Any champion"),
    ...uniq(accounts.flatMap(a => a.champions.map(c => c.name))).map(c => option(c, c)));
}

/* ------------------------------------------------------------------ *
 *  Filtering + sorting
 * ------------------------------------------------------------------ */
function matches(a) {
  const q = state.q.trim().toLowerCase();
  if (q) {
    const hay = [a.name, a.riotId, a.login, a.folder, a.region.short, a.region.long, a.notes,
                 rankText(a.ranks.solo), rankText(a.ranks.flex), a.access,
                 a.lastGame && a.lastGame.champion]
      .concat(a.champions.map(c => c.name)).filter(Boolean).join(" ").toLowerCase();
    if (!q.split(/\s+/).every(term => hay.includes(term))) return false;
  }
  if (state.folder) {
    if (state.folder === UNFILED) { if (a.folder) return false; }
    else if (a.folder !== state.folder) return false;
  }
  if (state.region && a.region.short !== state.region) return false;
  if (state.tier) {
    if (state.tier === "__ranked") {
      if (a.ranks.solo.tier === "UNRANKED" && a.ranks.flex.tier === "UNRANKED") return false;
    } else if (a.ranks.solo.tier !== state.tier && a.ranks.flex.tier !== state.tier) return false;
  }
  if (state.access) {
    if (state.access === "__none") { if (a.access) return false; }
    else if (a.access !== state.access) return false;
  }
  if (state.status) {
    const live = a.penalties.filter(p => p.active);
    if (state.status === "__clean" && live.length) return false;
    if (state.status === "__any"   && !live.length) return false;
    if (state.status === "__crit"  && !live.some(p => p.critical)) return false;
    if (state.status === "__delay" && !live.some(p => p.kind === "Queue delay")) return false;
    if (state.status === "__dodge" && !live.some(p => p.kind === "Dodge timer")) return false;
    if (state.status === "__ban"   && !live.some(p => p.kind === "Temporary suspension" || p.kind === "Permanent ban")) return false;
  }
  if (state.idle) {
    if (state.idle === "__never") { if (a.idleDays != null) return false; }
    else {
      if (a.idleDays == null) return false;
      const min = Number(state.idle.slice(2));
      if (min === 7 ? a.idleDays >= 7 : a.idleDays < min) return false;
    }
  }
  if (state.player) {
    const who = a.lastGame && a.lastGame.player;
    if (state.player === "__unsaid") { if (who) return false; }
    else if (who !== state.player) return false;
  }
  if (state.champ && !a.champions.some(c => c.name === state.champ)) return false;
  return true;
}
function bestLadder(a) {
  return Math.max(ladder(a.ranks.solo.tier, a.ranks.solo.div), ladder(a.ranks.flex.tier, a.ranks.flex.div));
}
function sortKey(a) {
  switch (state.sort) {
    case "level":  return -(a.level || 0);
    case "champs": return -a.champions.length;
    case "be":     return -(a.be || 0);
    case "rp":     return -(a.rp || 0);
    case "idle":   return -(a.idleDays == null ? -1 : a.idleDays);
    case "recent": return -(a.lastGame ? new Date(a.lastGame.playedAt).getTime() : 0);
    case "name":   return a.name.toLowerCase();
    case "folder": return (a.folder || "zzzz") + " " + a.name.toLowerCase();
    default:       return -(bestLadder(a) * 1e6 + (a.level || 0));
  }
}
function visible() {
  const rows = VAULT.accounts.filter(matches);
  rows.sort((x, y) => { const a = sortKey(x), b = sortKey(y); return typeof a === "string" ? a.localeCompare(b) : a - b; });
  return rows;
}

/* ------------------------------------------------------------------ *
 *  Rendering (cards / rows)
 * ------------------------------------------------------------------ */
function rankPill(r) {
  if (!r) return "";
  const t = r.tier || "UNRANKED";
  const lp = t !== "UNRANKED" ? '<span class="lp">' + r.lp + ' LP</span>' : "";
  return '<span class="rank" style="color:' + tierVar(t) + '">'
       + '<img src="' + CREST(t) + '" alt="" loading="lazy" onerror="this.style.display=\'none\'">'
       + esc(rankText(r)) + lp + '</span>';
}
function statusPills(a) {
  const live = a.penalties.filter(p => p.active);
  if (!live.length) return '<span class="pill live"><span class="dot"></span>Clear</span>';
  const out = [];
  for (const p of live.filter(p => p.critical).slice(0, 2))
    out.push('<span class="pill bad"><span class="dot"></span>' + esc(p.kind) + '</span>');
  for (const p of live.filter(p => !p.critical).slice(0, 2))
    out.push('<span class="pill warn">' + esc(p.kind) + '</span>');
  return out.join("");
}
function accessPill(a) {
  if (a.access === "FA")  return '<span class="pill fa">FA</span>';
  if (a.access === "NFA") return '<span class="pill nfa">NFA</span>';
  return "";
}
function idlePill(a) {
  if (a.idleDays == null) return '<span class="pill dormant">Never played</span>';
  const mine = a.lastGame && a.lastGame.player === "ME";
  const label = a.idleDays === 0 ? "Played today"
              : a.idleDays === 1 ? "1 day idle"
              : a.idleDays < 365 ? a.idleDays + " days idle"
              : (a.idleDays / 365).toFixed(1) + " years idle";
  const cls = mine ? "dormant" : (a.idleDays >= 90 ? "warn" : "ghost");
  return '<span class="pill ' + cls + '">' + (mine ? "● " : "") + esc(label) + '</span>';
}

function card(a) {
  const art = splashURL(faceChampionId(a));
  const crit = a.penalties.find(p => p.active && p.critical);
  const node = el("div", "card" + (crit ? " critical" : ""));
  node.dataset.id = a.id;
  node.innerHTML =
    '<div class="art">'
    + (art ? '<img src="' + art + '" alt="" loading="lazy" onerror="this.remove()">' : "")
    + (crit ? '<div class="alarm"><svg viewBox="0 0 24 24"><path d="M12 2L1 21h22L12 2zm0 6l.9 7h-1.8L12 8zm0 9.6a1.2 1.2 0 110 2.4 1.2 1.2 0 010-2.4z"/></svg>'
              + esc(crit.kind) + ' · ' + esc(crit.status) + '</div>' : "")
    + '<div class="tl">' + (a.folder ? '<span class="folder">' + esc(a.folder) + '</span>' : "") + '</div>'
    + '<div class="tr">' + (a.level ? '<span class="lvl">LVL ' + a.level + '</span>' : "") + '</div>'
    + '<div class="bl">' + rankPill(a.ranks.solo)
    + (a.ranks.flex.tier !== "UNRANKED" ? rankPill(a.ranks.flex) : "") + '</div>'
    + '</div>'
    + '<div class="body">'
    + '<div class="namerow">'
    + '<img class="pfp" src="' + iconURL(a.iconId) + '" alt="" loading="lazy">'
    + '<div class="names"><div class="nm">' + esc(a.name) + '</div>'
    + '<div class="rid">' + esc(a.riotId || a.login || "not signed in yet") + '</div></div>'
    + '</div>'
    + '<div class="stats">'
    + '<span><b>' + a.champions.length + '</b> champs</span>'
    + '<span><b>' + num(a.be) + '</b> BE</span>'
    + '<span><b>' + num(a.rp) + '</b> RP</span>'
    + (a.lastGame ? '<span><b>' + esc(a.lastGame.champion) + '</b> ' + esc(ago(a.lastGame.playedAt))
                    + (a.lastGame.player === "ME" ? " · you"
                       : a.lastGame.player === "SOMEONE_ELSE" ? " · someone else" : "") + '</span>'
                  : '<span>no game recorded</span>')
    + '</div>'
    + '<div class="meta"><span class="pill region">' + esc(a.region.short) + '</span>'
    + accessPill(a) + idlePill(a) + statusPills(a) + '</div>'
    + '</div>';
  node.addEventListener("click", () => openSheet(a.id));
  return node;
}

function row(a) {
  const crit = a.penalties.find(p => p.active && p.critical);
  const node = el("div", "row" + (crit ? " critical" : ""));
  node.dataset.id = a.id;
  node.innerHTML =
    '<div class="who"><img src="' + iconURL(a.iconId) + '" alt="" loading="lazy">'
    + '<div><div class="nm">' + esc(a.name) + '</div>'
    + '<div class="rid">' + esc(a.riotId || a.login || "—") + '</div></div></div>'
    + '<div>' + rankPill(a.ranks.solo) + '</div>'
    + '<div class="num"><b>' + (a.level || "—") + '</b></div>'
    + '<div class="num"><b>' + a.champions.length + '</b> champs</div>'
    + '<div class="num"><b>' + num(a.be) + '</b> BE</div>'
    + '<div class="num"><b>' + num(a.rp) + '</b> RP</div>'
    + '<div class="num">' + (a.idleDays == null ? "—"
        : '<b>' + a.idleDays + '</b> days'
          + (a.lastGame && a.lastGame.player === "ME" ? ' <span style="opacity:.6">you</span>' : "")) + '</div>'
    + '<div>' + (crit ? '<span class="pill bad"><span class="dot"></span>' + esc(crit.kind) + '</span>'
                      : (a.penalties.some(p => p.active) ? '<span class="pill warn">Penalty</span>'
                                                         : '<span class="pill live">Clear</span>')) + '</div>'
    + '<div style="display:flex;gap:5px;justify-content:flex-end">'
    + '<span class="pill region">' + esc(a.region.short) + '</span>' + accessPill(a) + '</div>';
  node.addEventListener("click", () => openSheet(a.id));
  return node;
}

function render() {
  const rows = visible();
  const host = $("#results");
  host.replaceChildren();
  if (!rows.length) {
    host.append(el("div", "empty",
      VAULT.accounts.length ? "<b>Nothing matches</b>Loosen a filter, or clear the search."
                            : "<b>No accounts yet</b>Add one, or open the League client and hit “Refresh current”."));
  } else if (state.view === "list") {
    const scroller = el("div", "scroller");
    const list = el("div", "list");
    list.append(el("div", "hdr",
      '<div>Account</div><div>Solo/Duo</div><div class="num">Level</div><div class="num">Champions</div>'
      + '<div class="num">Blue essence</div><div class="num">RP</div><div class="num">Idle</div>'
      + '<div>Status</div><div style="text-align:right">Server</div>'));
    for (const a of rows) list.append(row(a));
    scroller.append(list);
    host.append(scroller);
  } else {
    const grid = el("div", "grid");
    for (const a of rows) grid.append(card(a));
    host.append(grid);
  }
  renderChips();
}

const CHIP_LABEL = { q: "Search", folder: "Folder", region: "Server", tier: "Rank",
  access: "Access", status: "Status", idle: "Idle", player: "Last played by", champ: "Champion" };
const CHIP_VALUE = {
  "__ranked": "Ranked", "__none": "Not recorded", "__clean": "Nothing wrong",
  "__any": "Has a penalty", "__crit": "Blocked", "__delay": "Queue delay",
  "__dodge": "Dodge timer", "__ban": "Suspended",
  "__7": "Under a week", "__30": "Over a month", "__90": "Over 3 months",
  "__365": "Over a year", "__never": "Never played",
  "ME": "Me", "SOMEONE_ELSE": "Someone else", "__unsaid": "Not said" };
CHIP_VALUE[UNFILED] = "Unfiled";

function renderChips() {
  const box = $("#chips");
  box.replaceChildren();
  let any = false;
  for (const k of FILTER_KEYS) {
    if (!state[k]) continue;
    any = true;
    const chip = el("span", "fchip",
      esc(CHIP_LABEL[k]) + ": " + esc(CHIP_VALUE[state[k]] || state[k]) + ' <button type="button" aria-label="Remove">&times;</button>');
    chip.querySelector("button").addEventListener("click", () => {
      state[k] = ""; if (k === "q") $("#q").value = ""; syncSelects(); render();
    });
    box.append(chip);
  }
  if (any) {
    const clear = el("button", "clearall", "Clear everything");
    clear.addEventListener("click", () => {
      for (const k of FILTER_KEYS) state[k] = ""; $("#q").value = ""; syncSelects(); render();
    });
    box.append(clear);
  }
}
function syncSelects() {
  $("#fFolder").value = state.folder; $("#fRegion").value = state.region;
  $("#fTier").value = state.tier;     $("#fAccess").value = state.access;
  $("#fStatus").value = state.status; $("#fIdle").value = state.idle;
  $("#fPlayer").value = state.player; $("#fChamp").value = state.champ;
  $("#sort").value = state.sort;
}

/* ------------------------------------------------------------------ *
 *  Detail sheet
 * ------------------------------------------------------------------ */
function rankCard(label, r) {
  const t = r.tier || "UNRANKED";
  const games = (r.wins || 0) + (r.losses || 0);
  const wr = games ? Math.round((r.wins / games) * 100) : null;
  const pk = peakText(r);
  return '<div class="rankcard"><div class="q">' + esc(label) + '</div>'
    + '<div class="big" style="color:' + tierVar(t) + '">'
    + '<img src="' + CREST(t) + '" alt="" onerror="this.style.display=\'none\'">'
    + '<span>' + esc(rankText(r)) + '</span>'
    + (t !== "UNRANKED" ? '<span style="color:var(--muted);font:600 12px var(--mono)">' + r.lp + ' LP</span>' : "")
    + '</div>'
    + (games ? '<div class="wl">' + r.wins + 'W ' + r.losses + 'L · ' + wr + '% over ' + games + ' games</div>'
               + '<div class="bar"><i style="width:' + wr + '%"></i></div>'
             : '<div class="wl">no games this split</div>')
    + (pk ? '<div class="peak">Peak ' + esc(pk) + (r.peakNote ? " · " + esc(r.peakNote) : "") + '</div>' : "")
    + '</div>';
}

function modal(innerHTML) {
  const back = el("div", "backdrop");
  back.innerHTML = innerHTML;
  const close = () => { back.remove(); document.removeEventListener("keydown", onKey); };
  const onKey = e => { if (e.key === "Escape") close(); };
  back.addEventListener("click", e => { if (e.target === back) close(); });
  document.addEventListener("keydown", onKey);
  document.body.append(back);
  back.close = close;
  const x = back.querySelector(".close");
  if (x) x.addEventListener("click", close);
  return back;
}

function openSheet(id) {
  const a = VAULT.accounts.find(x => x.id === id);
  if (!a) return;
  const art = splashURL(faceChampionId(a));
  const live = a.penalties.filter(p => p.active);
  const done = a.penalties.filter(p => !p.active);

  const back = modal('<div class="sheet" role="dialog" aria-modal="true">'
    + '<div class="banner">'
    + (art ? '<img src="' + art + '" alt="" onerror="this.remove()">' : "")
    + '<button class="close" type="button" aria-label="Close">&times;</button></div>'
    + '<div class="head"><img class="big" src="' + iconURL(a.iconId) + '" alt="">'
    + '<div><h2>' + esc(a.name) + '</h2>'
    + '<div class="rid">' + esc(a.riotId || a.login || "not signed in yet") + '</div></div></div>'
    + '<div class="pills">'
    + '<span class="pill region">' + esc(a.region.short) + ' · ' + esc(a.region.long) + '</span>'
    + (a.folder ? '<span class="pill ghost">' + esc(a.folder) + '</span>' : "")
    + accessPill(a) + idlePill(a)
    + (a.level ? '<span class="pill ghost">Level ' + a.level + '</span>' : "")
    + (a.honor != null ? '<span class="pill ghost">Honor ' + a.honor + '</span>' : "")
    + '</div>'
    + '<div class="sect"><h3>Ranked</h3><div class="ranks">'
    + rankCard("Solo / Duo", a.ranks.solo) + rankCard("Flex", a.ranks.flex) + '</div></div>'
    + '<div class="sect"><h3>Account</h3><div class="kv">'
    + '<div><span>Blue essence</span><b>' + num(a.be) + '</b></div>'
    + '<div><span>Riot points</span><b>' + num(a.rp) + '</b></div>'
    + '<div><span>Champions</span><b>' + a.champions.length + '</b></div>'
    + '<div><span>Days idle</span><b>' + (a.idleDays == null ? "—" : a.idleDays) + '</b></div>'
    + '<div><span>Last game</span><b>' + (a.lastGame ? esc(ago(a.lastGame.playedAt)) : "—") + '</b></div>'
    + '<div><span>Last refreshed</span><b>' + (a.lastRefreshed ? esc(ago(a.lastRefreshed)) : "never") + '</b></div>'
    + '</div></div>'
    + (a.lastGame ? '<div class="sect"><h3>Last game</h3><div class="kv">'
        + '<div><span>Champion</span><b>' + esc(a.lastGame.champion || "—") + '</b></div>'
        + '<div><span>Queue</span><b>' + esc(a.lastGame.queue || "—") + '</b></div>'
        + '<div><span>Result</span><b style="color:'
          + (a.lastGame.result === "Victory" ? "var(--good)" : a.lastGame.result === "Defeat" ? "var(--bad)" : "var(--muted)")
          + '">' + esc(a.lastGame.result) + '</b></div>'
        + '<div><span>KDA</span><b>' + esc(a.lastGame.kda) + '</b></div>'
        + '<div><span>Length</span><b>' + esc(a.lastGame.duration) + '</b></div>'
        + '<div><span>Played</span><b>' + esc(ago(a.lastGame.playedAt)) + '</b></div>'
        + '</div></div>' : "")
    + '<div class="sect"><h3>Penalties</h3>'
    + (live.length || done.length ? "" : '<div style="color:var(--dim);font-size:12.5px">Nothing on record. This account is clear.</div>')
    + live.map(p => '<div class="pen ' + (p.critical ? "crit" : "") + '"><div style="flex:1">'
        + '<div class="k" style="color:' + (p.critical ? "var(--bad)" : "var(--warn)") + '">' + esc(p.kind) + '</div>'
        + (p.detail ? '<div class="d">' + esc(p.detail) + '</div>' : "")
        + '<div class="s">' + esc(p.status) + (p.source === "client" ? " · read from the client" : "") + '</div>'
        + '</div></div>').join("")
    + (done.length ? '<div style="color:var(--dim);font-size:11.5px;margin-top:11px">Served: '
        + done.map(p => esc(p.kind)).join(", ") + '</div>' : "")
    + '</div>'
    + (a.champions.length ? '<div class="sect"><h3>Champion pool — ' + a.champions.length + '</h3><div class="champs">'
        + a.champions.map(c => {
            const sq = squareURL(c.id);
            return '<span class="champ">' + (sq ? '<img src="' + sq + '" alt="" loading="lazy" onerror="this.remove()">' : "") + esc(c.name) + '</span>';
          }).join("") + '</div></div>' : "")
    + (a.notes ? '<div class="sect"><h3>Notes</h3><div class="notes">' + esc(a.notes) + '</div></div>' : "")
    + '<div class="acts">'
    + '<button class="btn primary" data-act="signin" type="button">Sign in</button>'
    + '<button class="btn" data-act="launch" type="button">Launch League</button>'
    + '<button class="btn" data-act="refresh" type="button">Refresh from client</button>'
    + '<button class="btn" data-act="edit" type="button">Edit</button>'
    + (a.ugg ? '<a class="btn" href="' + esc(a.ugg) + '" target="_blank" rel="noreferrer noopener">u.gg</a>' : "")
    + (a.riotId ? '<button class="btn" data-copy="' + esc(a.riotId) + '" type="button">Copy Riot ID</button>' : "")
    + (a.login ? '<button class="btn" data-copy="' + esc(a.login) + '" type="button">Copy login</button>' : "")
    + '<button class="btn" data-act="copypass" type="button">Copy password</button>'
    + '<button class="btn danger" data-act="delete" type="button">Delete</button>'
    + '</div></div>');

  back.querySelectorAll("[data-copy]").forEach(b => b.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(b.dataset.copy); const t = b.textContent; b.textContent = "Copied"; setTimeout(() => { b.textContent = t; }, 1200); } catch (e) {}
  }));
  back.querySelector('[data-act="signin"]').addEventListener("click", () => act(back, () => invoke("sign_in", { id }), "Signing in…"));
  back.querySelector('[data-act="launch"]').addEventListener("click", () => act(back, () => invoke("launch_league"), "Launching League…"));
  back.querySelector('[data-act="refresh"]').addEventListener("click", () => act(back, async () => { VAULT = await invoke("refresh_account", { id }); afterData(); toast("Refreshed from the client."); }, "Reading the client…", true));
  back.querySelector('[data-act="edit"]').addEventListener("click", () => { back.close(); openEditor(id); });
  back.querySelector('[data-act="copypass"]').addEventListener("click", async () => {
    try { const pw = await invoke("copy_password", { id }); await navigator.clipboard.writeText(pw); toast("Password copied to the clipboard."); }
    catch (e) { toast(String(e), true); }
  });
  back.querySelector('[data-act="delete"]').addEventListener("click", async () => {
    if (!confirm("Delete " + a.name + " from the vault? This cannot be undone.")) return;
    try { await invoke("delete_account", { id }); back.close(); await reload(); toast("Account deleted."); }
    catch (e) { toast(String(e), true); }
  });
}

async function act(back, fn, busyLabel, keepOpen) {
  const buttons = back.querySelectorAll(".acts button, .acts a");
  buttons.forEach(b => b.disabled = true);
  toast(busyLabel);
  try { await fn(); if (!keepOpen) back.close(); }
  catch (e) { toast(String(e), true); buttons.forEach(b => b.disabled = false); }
}

/* ------------------------------------------------------------------ *
 *  Editor
 * ------------------------------------------------------------------ */
function rankFields(prefix, r) {
  const tierOpts = TIERS.map(t => '<option value="' + t + '">' + (t === "UNRANKED" ? "Unranked" : t[0] + t.slice(1).toLowerCase()) + '</option>').join("");
  const divOpts = DIVS.map(d => '<option value="' + d + '">' + d + '</option>').join("");
  return '<div class="grid2">'
    + '<div class="field"><label>' + prefix + ' tier</label><select id="' + prefix + '_tier">' + tierOpts + '</select></div>'
    + '<div class="field"><label>Division</label><select id="' + prefix + '_div">' + divOpts + '</select></div>'
    + '</div><div class="grid2">'
    + '<div class="field"><label>LP</label><input id="' + prefix + '_lp" type="number" min="0" max="2000"></div>'
    + '<div class="field"><label>Wins / Losses</label><div class="grid2"><input id="' + prefix + '_w" type="number" min="0" placeholder="W"><input id="' + prefix + '_l" type="number" min="0" placeholder="L"></div></div>'
    + '</div>';
}

async function openEditor(id) {
  let acct = null;
  if (id) {
    try { acct = await invoke("get_account", { id }); } catch (e) { toast(String(e), true); return; }
  }
  const solo = acct ? (acct.ranks || []).find(r => r.queue === "RANKED_SOLO_5x5") : null;
  const flex = acct ? (acct.ranks || []).find(r => r.queue === "RANKED_FLEX_SR") : null;
  const regionOpts = REGIONS.map(([v, l]) => '<option value="' + v + '">' + l + '</option>').join("");

  const back = modal('<div class="sheet" role="dialog" aria-modal="true">'
    + '<div class="head" style="margin-top:22px"><div><h2>' + (id ? "Edit account" : "Add account") + '</h2>'
    + '<div class="rid">' + (id ? esc(acct ? (acct.label || acct.gameName || "account") : "") : "A new entry in the vault") + '</div></div>'
    + '<button class="close" type="button" style="top:16px">&times;</button></div>'
    + '<form class="form" id="editForm">'
    + '<div class="grid2">'
    + '<div class="field"><label>Nickname</label><input id="f_label" placeholder="What you call it"></div>'
    + '<div class="field"><label>Folder</label><input id="f_folder" placeholder="e.g. Smurfs"></div>'
    + '</div>'
    + '<div class="grid2">'
    + '<div class="field"><label>Riot ID — name</label><input id="f_game" placeholder="GameName"></div>'
    + '<div class="field"><label>Riot ID — tag</label><input id="f_tag" placeholder="NA1"></div>'
    + '</div>'
    + '<div class="grid2">'
    + '<div class="field"><label>Server</label><select id="f_region">' + regionOpts + '</select></div>'
    + '<div class="field"><label>Access</label><select id="f_access"><option value="UNKNOWN">Not recorded</option><option value="FA">FA — full access</option><option value="NFA">NFA — no email</option></select></div>'
    + '</div>'
    + '<div class="grid2">'
    + '<div class="field"><label>Login username</label><input id="f_login" autocomplete="off" placeholder="Riot login"></div>'
    + '<div class="field"><label>Password</label><input id="f_pass" type="password" autocomplete="off" placeholder="' + (id ? "leave blank to keep" : "optional") + '"><div class="hint">Stored encrypted on this PC with DPAPI.</div></div>'
    + '</div>'
    + '<div class="field"><label>Notes</label><textarea id="f_notes" placeholder="Anything worth remembering"></textarea></div>'
    + '<div class="sect" style="margin:6px -24px 0;padding:18px 24px"><h3>Solo / Duo rank</h3>' + rankFields("solo", solo) + '</div>'
    + '<div class="sect" style="margin:0 -24px;padding:18px 24px"><h3>Flex rank</h3>' + rankFields("flex", flex) + '</div>'
    + '</form>'
    + '<div class="acts"><button class="btn primary" id="saveBtn" type="button">' + (id ? "Save changes" : "Add to vault") + '</button>'
    + '<button class="btn" id="cancelBtn" type="button">Cancel</button></div>'
    + '</div>');

  const setV = (sel, v) => { const n = back.querySelector(sel); if (n != null && v != null) n.value = v; };
  if (acct) {
    setV("#f_label", acct.label); setV("#f_folder", acct.folder);
    setV("#f_game", acct.gameName); setV("#f_tag", acct.tagLine);
    setV("#f_region", acct.region); setV("#f_access", acct.access || "UNKNOWN");
    setV("#f_login", acct.loginUsername); setV("#f_notes", acct.notes);
  }
  const fillRank = (prefix, r) => {
    setV("#" + prefix + "_tier", r ? r.tier : "UNRANKED");
    setV("#" + prefix + "_div", r ? r.division : "IV");
    setV("#" + prefix + "_lp", r ? r.lp : 0);
    setV("#" + prefix + "_w", r ? r.wins : 0);
    setV("#" + prefix + "_l", r ? r.losses : 0);
  };
  fillRank("solo", solo); fillRank("flex", flex);

  back.querySelector("#cancelBtn").addEventListener("click", back.close);
  back.querySelector("#saveBtn").addEventListener("click", async () => {
    const v = sel => back.querySelector(sel).value;
    const nInt = sel => { const n = parseInt(v(sel), 10); return isNaN(n) ? 0 : n; };
    const buildRank = (queue, prefix, prev) => ({
      queue,
      tier: v("#" + prefix + "_tier"),
      division: v("#" + prefix + "_div"),
      lp: nInt("#" + prefix + "_lp"),
      wins: nInt("#" + prefix + "_w"),
      losses: nInt("#" + prefix + "_l"),
      peakTier: prev ? prev.peakTier : v("#" + prefix + "_tier"),
      peakDivision: prev ? prev.peakDivision : v("#" + prefix + "_div"),
      peakNote: prev ? prev.peakNote : ""
    });
    const account = Object.assign({}, acct || {}, {
      label: v("#f_label").trim(),
      folder: v("#f_folder").trim(),
      gameName: v("#f_game").trim(),
      tagLine: v("#f_tag").trim().replace(/^#/, ""),
      region: v("#f_region"),
      access: v("#f_access"),
      loginUsername: v("#f_login").trim(),
      notes: v("#f_notes"),
      ranks: [buildRank("RANKED_SOLO_5x5", "solo", solo), buildRank("RANKED_FLEX_SR", "flex", flex)]
    });
    const pass = v("#f_pass");
    try {
      const savedId = await invoke("save_account", { account });
      if (pass) await invoke("set_password", { id: savedId, password: pass });
      back.close();
      await reload();
      toast(id ? "Saved." : "Account added.");
    } catch (e) { toast(String(e), true); }
  });
}

/* ------------------------------------------------------------------ *
 *  Totals + client status + boot
 * ------------------------------------------------------------------ */
function renderTotals() {
  const A = VAULT.accounts;
  const sum = k => A.reduce((n, a) => n + (a[k] || 0), 0);
  let best = null, bestP = -1;
  for (const a of A) { const p = bestLadder(a); if (p > bestP) { bestP = p; best = a; } }
  const bestRank = best
    ? rankText(ladder(best.ranks.solo.tier, best.ranks.solo.div) >= ladder(best.ranks.flex.tier, best.ranks.flex.div) ? best.ranks.solo : best.ranks.flex)
    : "—";
  const blocked = A.filter(a => a.penalties.some(p => p.active && p.critical)).length;
  const pool = new Set(A.flatMap(a => a.champions.map(c => c.name))).size;
  const idle = A.filter(a => a.idleDays != null && !(a.lastGame && a.lastGame.player === "ME")).map(a => a.idleDays);
  const longest = idle.length ? Math.max(...idle) : null;
  const items = [
    ["Accounts", A.length, false],
    ["Best rank", bestRank, false],
    ["Blue essence", num(sum("be")), false],
    ["Riot points", num(sum("rp")), false],
    ["Champions seen", pool, false],
    ["Longest idle", longest == null ? "—" : longest + "d", false],
    ["Blocked right now", blocked, blocked > 0]
  ];
  $("#totals").replaceChildren(...items.map(([k, v, alarm]) => {
    const d = el("div", "total");
    d.innerHTML = "<b" + (alarm ? ' style="color:var(--bad)"' : "") + ">" + esc(v) + "</b><span>" + esc(k) + "</span>";
    return d;
  }));
}

async function pollClient() {
  try {
    const s = await invoke("client_status");
    const chip = $("#cstat"), text = $("#cstatText"), refresh = $("#refreshBtn");
    if (s.client_connected) { chip.classList.add("on"); text.textContent = "Client connected"; refresh.disabled = false; }
    else if (s.league_running) { chip.classList.remove("on"); text.textContent = "League starting…"; refresh.disabled = true; }
    else if (!s.installed) { chip.classList.remove("on"); text.textContent = "League not found"; refresh.disabled = true; }
    else { chip.classList.remove("on"); text.textContent = "Client closed"; refresh.disabled = true; }
  } catch (e) {}
}

function afterData() {
  fillSelects(VAULT.accounts);
  syncSelects();
  renderTotals();
  render();
  const when = VAULT.publishedAt ? new Date(VAULT.publishedAt) : new Date();
  $("#foot").textContent = VAULT.accounts.length + " accounts · " + (VAULT.origin || "this PC")
    + " · League Vault for Windows · passwords stay encrypted on this machine";
}

async function reload() {
  VAULT = await invoke("list_accounts");
  afterData();
}

function wire() {
  $("#q").addEventListener("input", e => { state.q = e.target.value; render(); });
  const bind = (sel, key) => $(sel).addEventListener("change", e => { state[key] = e.target.value; render(); });
  bind("#fFolder", "folder"); bind("#fRegion", "region"); bind("#fTier", "tier");
  bind("#fAccess", "access"); bind("#fStatus", "status"); bind("#fIdle", "idle");
  bind("#fPlayer", "player"); bind("#fChamp", "champ");
  $("#sort").addEventListener("change", e => { state.sort = e.target.value; try { localStorage.setItem("lv.sort", state.sort); } catch (err) {} render(); });
  const setView = v => {
    state.view = v; try { localStorage.setItem("lv.view", v); } catch (err) {}
    $("#vGrid").classList.toggle("on", v === "grid");
    $("#vList").classList.toggle("on", v === "list");
    render();
  };
  $("#vGrid").addEventListener("click", () => setView("grid"));
  $("#vList").addEventListener("click", () => setView("list"));
  $("#vGrid").classList.toggle("on", state.view === "grid");
  $("#vList").classList.toggle("on", state.view === "list");
  $("#addBtn").addEventListener("click", () => openEditor(null));
  $("#refreshBtn").addEventListener("click", async () => {
    toast("Reading the signed-in account…");
    try { VAULT = await invoke("refresh_current"); afterData(); toast("Refreshed from the client."); }
    catch (e) { toast(String(e), true); }
  });
  document.addEventListener("keydown", e => {
    if (e.key === "/" && document.activeElement !== $("#q")) { e.preventDefault(); $("#q").focus(); }
  });
}

(async function boot() {
  wire();
  try { VAULT = await invoke("list_accounts"); }
  catch (e) { VAULT = { accounts: [], origin: "this PC" }; toast("Could not open the vault: " + e, true); }
  afterData();
  pollClient();
  setInterval(pollClient, 5000);
  await loadChampions();
  render();
})();
