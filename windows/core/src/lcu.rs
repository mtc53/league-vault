//! Parsing of League Client (LCU) responses, ported from `Sources/LCU.swift`.
//!
//! Only the pure parsing lives here — the part that turns the client's JSON into
//! vault types. It is testable without a running client. The transport
//! (discovering the client's port/password from its lockfile, the loopback
//! HTTPS calls) and process control are Windows-specific and live in the app
//! layer; the League Client API itself is identical across platforms, so these
//! parsers are reused unchanged.

use crate::models::{OwnedChampion, Penalty, PenaltyKind, PenaltySource};
use chrono::{TimeZone, Utc};
use serde::Deserialize;
use serde_json::Value;

// MARK: - Champion inventory

/// Owned champions, de-duplicated by id and name, sorted by name.
pub fn parse_owned_champions(data: &[u8]) -> Vec<OwnedChampion> {
    #[derive(Deserialize)]
    struct Ownership {
        owned: Option<bool>,
    }
    #[derive(Deserialize)]
    struct Dto {
        id: Option<i64>,
        name: Option<String>,
        alias: Option<String>,
        ownership: Option<Ownership>,
    }
    let list: Vec<Dto> = match serde_json::from_slice(data) {
        Ok(l) => l,
        Err(_) => return Vec::new(),
    };

    let mut seen_ids = std::collections::HashSet::new();
    let mut seen_names = std::collections::HashSet::new();
    let mut result = Vec::new();
    for champ in list {
        // id 0/-1 is the "None" placeholder the client includes.
        let id = match champ.id {
            Some(id) if id > 0 => id,
            _ => continue,
        };
        // Absent ownership means the endpoint already filtered to owned.
        if let Some(Ownership { owned: Some(false) }) = champ.ownership {
            continue;
        }
        let name = match champ.name {
            Some(n) if !n.is_empty() => n,
            _ => champ.alias.unwrap_or_else(|| format!("Champion {}", id)),
        };
        let key = name.to_lowercase();
        if seen_ids.contains(&id) || seen_names.contains(&key) {
            continue;
        }
        seen_ids.insert(id);
        seen_names.insert(key);
        result.push(OwnedChampion { id, name });
    }
    result.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    result
}

// MARK: - Wallet

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Wallet {
    pub blue_essence: Option<i64>,
    pub riot_points: Option<i64>,
}

const BLUE_ESSENCE_KEYS: &[&str] = &["lol_blue_essence", "blueEssence", "blue_essence", "ip", "IP"];
const RIOT_POINTS_KEYS: &[&str] = &["RP", "rp", "riotPoints", "riot_points", "lol_rp"];

fn as_int(v: &Value) -> Option<i64> {
    if let Some(n) = v.as_i64() {
        return Some(n);
    }
    if let Some(d) = v.as_f64() {
        return Some(d as i64);
    }
    if let Some(s) = v.as_str() {
        return s.parse::<i64>().ok();
    }
    None
}

/// Reads a wallet response. `path` is the endpoint hint used when the client
/// answers a per-currency endpoint with a bare number.
pub fn parse_wallet(data: &[u8], path: &str) -> Wallet {
    let root: Value = match serde_json::from_slice(data) {
        Ok(v) => v,
        Err(_) => return Wallet::default(),
    };

    // A per-currency endpoint answers with a bare number; the path says which.
    if !root.is_object() {
        if let Some(scalar) = as_int(&root) {
            let lower = path.to_lowercase();
            if lower.contains("blue_essence") {
                return Wallet { blue_essence: Some(scalar), riot_points: None };
            }
            if path.ends_with("/RP") {
                return Wallet { blue_essence: None, riot_points: Some(scalar) };
            }
            return Wallet::default();
        }
    }

    let object = match root.as_object() {
        Some(o) => o,
        None => return Wallet::default(),
    };

    let number = |keys: &[&str]| -> Option<i64> {
        for (key, value) in object {
            if keys.iter().any(|k| k.eq_ignore_ascii_case(key)) {
                if let Some(n) = as_int(value) {
                    return Some(n);
                }
            }
        }
        None
    };

    Wallet {
        blue_essence: number(BLUE_ESSENCE_KEYS),
        riot_points: number(RIOT_POINTS_KEYS),
    }
}

// MARK: - Honor

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct HonorProfile {
    pub level: Option<i64>,
    pub rewards_locked: bool,
    pub games_remaining: Option<i64>,
    pub games_required: Option<i64>,
}

pub fn parse_honor(data: &[u8]) -> Option<HonorProfile> {
    #[derive(Deserialize)]
    struct Redemption {
        remaining: Option<i64>,
        required: Option<i64>,
    }
    #[derive(Deserialize)]
    struct Dto {
        #[serde(rename = "honorLevel")]
        honor_level: Option<i64>,
        #[serde(rename = "rewardsLocked")]
        rewards_locked: Option<bool>,
        redemptions: Option<Vec<Redemption>>,
    }
    let dto: Dto = serde_json::from_slice(data).ok()?;
    let redemptions = dto.redemptions.unwrap_or_default();
    let redemption = redemptions
        .iter()
        .find(|r| r.remaining.unwrap_or(0) > 0)
        .or_else(|| redemptions.first());
    Some(HonorProfile {
        level: dto.honor_level,
        rewards_locked: dto.rewards_locked.unwrap_or(false),
        games_remaining: redemption.and_then(|r| r.remaining),
        games_required: redemption.and_then(|r| r.required),
    })
}

// MARK: - Behaviour restrictions → penalties

/// Parses the restriction-view into client-sourced penalties.
pub fn parse_restrictions(data: &[u8]) -> Vec<Penalty> {
    #[derive(Deserialize)]
    struct Redemption {
        #[serde(rename = "redemptionCountRemaining")]
        remaining: Option<i64>,
        #[serde(rename = "redemptionCountRequired")]
        required: Option<i64>,
    }
    #[derive(Deserialize)]
    struct Expiration {
        #[serde(rename = "expirationMillis")]
        expiration_millis: Option<f64>,
        redemptions: Option<Vec<Redemption>>,
    }
    #[derive(Deserialize)]
    struct Restriction {
        #[serde(rename = "restrictionType")]
        restriction_type: Option<String>,
        #[serde(rename = "restrictionReason")]
        restriction_reason: Option<String>,
        #[serde(rename = "restrictionsMillis")]
        restrictions_millis: Option<f64>,
        #[serde(rename = "expirationData")]
        expiration_data: Option<Expiration>,
    }
    #[derive(Deserialize)]
    struct Dto {
        restrictions: Option<Vec<Restriction>>,
    }

    let dto: Dto = match serde_json::from_slice(data) {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };
    let list = match dto.restrictions {
        Some(l) => l,
        None => return Vec::new(),
    };

    let mut result = Vec::new();
    for r in list {
        let rtype = r.restriction_type.clone().unwrap_or_default().to_uppercase();
        // REPUTATION_LIMIT is progress back to full honor, not a play restriction.
        if rtype.contains("REPUTATION") {
            continue;
        }
        let redemption = r.expiration_data.as_ref().and_then(|e| e.redemptions.as_ref()).and_then(|v| v.first());

        let mut parts: Vec<String> = Vec::new();
        if let Some(millis) = r.restrictions_millis {
            if millis > 0.0 {
                let minutes = (millis / 60_000.0).round() as i64;
                parts.push(format!("{} minute{}", minutes, if minutes == 1 { "" } else { "s" }));
            }
        }
        if let Some(rem) = redemption.and_then(|x| x.remaining) {
            if rem > 0 {
                match redemption.and_then(|x| x.required) {
                    Some(req) if req > 0 => parts.push(format!("{} of {} games remaining", rem, req)),
                    _ => parts.push(format!("{} games remaining", rem)),
                }
            }
        }
        if let Some(reason) = &r.restriction_reason {
            if !reason.is_empty() && reason != "NONE" {
                parts.push(humanise(reason));
            }
        }

        let remaining = redemption.and_then(|x| x.remaining).unwrap_or(0);
        let expiry = r.expiration_data.as_ref().and_then(|e| e.expiration_millis).unwrap_or(0.0);
        if remaining <= 0 && expiry <= 0.0 && r.restrictions_millis.unwrap_or(0.0) <= 0.0 {
            continue;
        }

        let expires_at = if expiry > 0.0 {
            Utc.timestamp_millis_opt(expiry as i64).single()
        } else {
            None
        };

        result.push(Penalty {
            id: uuid::Uuid::new_v4(),
            source: PenaltySource::Client,
            kind: kind_for_restriction_type(&rtype),
            detail: if parts.is_empty() { humanise(&rtype) } else { parts.join(" · ") },
            started_at: Utc::now(),
            expires_at,
            resolved: false,
        });
    }
    result
}

pub fn kind_for_restriction_type(t: &str) -> PenaltyKind {
    if t.contains("QUEUE_DELAY") {
        PenaltyKind::QueueDelay
    } else if t.contains("REPUTATION") {
        PenaltyKind::HonorDowngrade
    } else if t.contains("LOW_PRIORITY") || t.contains("LEAVER") {
        PenaltyKind::LowPriorityQueue
    } else if t.contains("VOICE") {
        PenaltyKind::VoiceMuted
    } else if t.contains("CHAT") || t.contains("COMMUNICATION") {
        PenaltyKind::ChatRestriction
    } else if t.contains("RANKED") {
        PenaltyKind::RankedRestriction
    } else if t.contains("PERMANENT") {
        PenaltyKind::PermanentBan
    } else if t.contains("BAN") || t.contains("SUSPEN") {
        PenaltyKind::Suspension
    } else {
        PenaltyKind::Other
    }
}

/// "AWAY_FROM_KEYBOARD" -> "Away from keyboard".
pub fn humanise(raw: &str) -> String {
    let words = raw.replace('_', " ").to_lowercase();
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::PenaltyKind;

    #[test]
    fn champions_dedupe_filter_sort() {
        let json = br#"[
            {"id": 0, "name": "None"},
            {"id": 103, "name": "Ahri", "ownership": {"owned": true}},
            {"id": 103, "name": "Ahri", "ownership": {"owned": true}},
            {"id": 1, "name": "Annie", "ownership": {"owned": true}},
            {"id": 7, "name": "LeBlanc", "ownership": {"owned": false}}
        ]"#;
        let champs = parse_owned_champions(json);
        let names: Vec<_> = champs.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["Ahri", "Annie"]); // sorted, deduped, unowned & None dropped
    }

    #[test]
    fn wallet_object_and_scalar() {
        let obj = br#"{"lol_blue_essence": 12345, "RP": 400}"#;
        let w = parse_wallet(obj, "/lol-inventory/v1/wallet");
        assert_eq!(w.blue_essence, Some(12345));
        assert_eq!(w.riot_points, Some(400));

        let be = parse_wallet(b"777", "/lol-inventory/v1/wallet/lol_blue_essence");
        assert_eq!(be.blue_essence, Some(777));
        assert_eq!(be.riot_points, None);

        let rp = parse_wallet(b"25", "/lol-inventory/v1/wallet/RP");
        assert_eq!(rp.riot_points, Some(25));
    }

    #[test]
    fn honor_picks_active_redemption() {
        let json = br#"{"honorLevel": 2, "rewardsLocked": true,
            "redemptions": [{"remaining": 0, "required": 5},
                            {"remaining": 3, "required": 5}]}"#;
        let h = parse_honor(json).unwrap();
        assert_eq!(h.level, Some(2));
        assert!(h.rewards_locked);
        assert_eq!(h.games_remaining, Some(3));
        assert_eq!(h.games_required, Some(5));
    }

    #[test]
    fn restrictions_to_penalties() {
        let json = br#"{"restrictions":[
            {"restrictionType":"QUEUE_DELAY","restrictionReason":"AWAY_FROM_KEYBOARD",
             "restrictionsMillis":600000,
             "expirationData":{"expirationMillis":0,
               "redemptions":[{"redemptionCountRemaining":3,"redemptionCountRequired":5,
                               "redemptionEventType":"MATCHMADE_GAME_PLAYED"}]}},
            {"restrictionType":"REPUTATION_LIMIT","restrictionsMillis":0,
             "expirationData":{"expirationMillis":0,"redemptions":[]}}
        ]}"#;
        let pens = parse_restrictions(json);
        assert_eq!(pens.len(), 1); // reputation dropped
        assert_eq!(pens[0].kind, PenaltyKind::QueueDelay);
        assert_eq!(pens[0].source, PenaltySource::Client);
        assert!(pens[0].detail.contains("10 minutes"));
        assert!(pens[0].detail.contains("3 of 5 games remaining"));
        assert!(pens[0].detail.contains("Away from keyboard"));
    }

    #[test]
    fn restriction_kind_mapping() {
        assert_eq!(kind_for_restriction_type("TIME_BASED_QUEUE_DELAY"), PenaltyKind::QueueDelay);
        assert_eq!(kind_for_restriction_type("RANKED_RESTRICTION"), PenaltyKind::RankedRestriction);
        assert_eq!(kind_for_restriction_type("PERMANENT_BAN"), PenaltyKind::PermanentBan);
        assert_eq!(kind_for_restriction_type("TEXT_CHAT_RESTRICTED"), PenaltyKind::ChatRestriction);
        assert_eq!(kind_for_restriction_type("MYSTERY"), PenaltyKind::Other);
    }

    #[test]
    fn humanise_snake_case() {
        assert_eq!(humanise("AWAY_FROM_KEYBOARD"), "Away from keyboard");
    }
}

// MARK: - Ranked stats

use crate::models::{Account, Division, LastGame, GameResult, RankEntry, RankedQueue, Region, Tier};
use std::collections::HashMap;

/// Parses /lol-ranked/v1/current-ranked-stats into solo+flex entries.
pub fn parse_ranked_stats(data: &[u8]) -> Vec<RankEntry> {
    #[derive(Deserialize)]
    struct Entry {
        #[serde(rename = "queueType")]
        queue_type: Option<String>,
        tier: Option<String>,
        division: Option<String>,
        #[serde(rename = "leaguePoints")]
        league_points: Option<i64>,
        wins: Option<i64>,
        losses: Option<i64>,
    }
    #[derive(Deserialize)]
    struct Dto {
        #[serde(rename = "queueMap")]
        queue_map: Option<HashMap<String, Entry>>,
    }

    let mut ranks = vec![RankEntry::new(RankedQueue::Solo), RankEntry::new(RankedQueue::Flex)];
    let dto: Dto = match serde_json::from_slice(data) {
        Ok(d) => d,
        Err(_) => return ranks,
    };
    let map = match dto.queue_map {
        Some(m) => m,
        None => return ranks,
    };

    for (key, entry) in map {
        let qraw = entry.queue_type.clone().unwrap_or_else(|| key.clone());
        let queue = match qraw.as_str() {
            "RANKED_SOLO_5x5" => RankedQueue::Solo,
            "RANKED_FLEX_SR" => RankedQueue::Flex,
            _ => continue,
        };
        if let Some(idx) = ranks.iter().position(|r| r.queue == queue) {
            ranks[idx].tier = Tier::from_raw(entry.tier.as_deref());
            // The client sends "NA" for apex tiers and unranked players.
            ranks[idx].division = match entry.division.as_deref().map(|s| s.to_uppercase()).as_deref() {
                Some("I") => Division::I,
                Some("II") => Division::Ii,
                Some("III") => Division::Iii,
                _ => Division::Iv,
            };
            ranks[idx].lp = entry.league_points.unwrap_or(0);
            ranks[idx].wins = entry.wins.unwrap_or(0);
            ranks[idx].losses = entry.losses.unwrap_or(0);
        }
    }
    ranks
}

// MARK: - Last game

/// Parses the legacy match-history shape into a LastGame. `champions` maps
/// champion id → name (from the client's champion summary).
pub fn parse_last_game(data: &[u8], puuid: &str, champions: &HashMap<i64, String>) -> Option<LastGame> {
    #[derive(Deserialize)]
    struct Stats {
        kills: Option<i64>,
        deaths: Option<i64>,
        assists: Option<i64>,
        win: Option<bool>,
        #[serde(rename = "gameEndedInEarlySurrender")]
        early_surrender: Option<bool>,
    }
    #[derive(Deserialize)]
    struct Participant {
        #[serde(rename = "participantId")]
        participant_id: Option<i64>,
        #[serde(rename = "championId")]
        champion_id: Option<i64>,
        stats: Option<Stats>,
    }
    #[derive(Deserialize)]
    struct Player {
        puuid: Option<String>,
    }
    #[derive(Deserialize)]
    struct Identity {
        #[serde(rename = "participantId")]
        participant_id: Option<i64>,
        player: Option<Player>,
    }
    #[derive(Deserialize)]
    struct Game {
        #[serde(rename = "gameId")]
        game_id: Option<f64>,
        #[serde(rename = "gameCreation")]
        game_creation: Option<f64>,
        #[serde(rename = "gameDuration")]
        game_duration: Option<f64>,
        #[serde(rename = "queueId")]
        queue_id: Option<i64>,
        #[serde(rename = "gameMode")]
        game_mode: Option<String>,
        #[serde(rename = "platformId")]
        platform_id: Option<String>,
        participants: Option<Vec<Participant>>,
        #[serde(rename = "participantIdentities")]
        identities: Option<Vec<Identity>>,
    }
    #[derive(Deserialize)]
    struct Wrapper {
        games: Option<Vec<Game>>,
    }
    #[derive(Deserialize)]
    struct Dto {
        games: Option<Wrapper>,
    }

    let dto: Dto = serde_json::from_slice(data).ok()?;
    let game = dto.games?.games?.into_iter().next()?;

    let my_pid = game
        .identities
        .as_ref()
        .and_then(|ids| ids.iter().find(|i| i.player.as_ref().and_then(|p| p.puuid.as_deref()) == Some(puuid)))
        .and_then(|i| i.participant_id);
    let participants = game.participants.unwrap_or_default();
    let me = participants
        .iter()
        .find(|p| p.participant_id == my_pid)
        .or_else(|| participants.first())?;

    let mut duration = game.game_duration.unwrap_or(0.0) as i64;
    if duration > 60 * 60 * 6 {
        duration /= 1000;
    }

    let played_at = {
        if let Some(millis) = game.game_creation {
            if millis > 0.0 {
                Utc.timestamp_millis_opt((millis + duration as f64 * 1000.0) as i64)
                    .single()
                    .unwrap_or_else(Utc::now)
            } else {
                Utc::now()
            }
        } else {
            Utc::now()
        }
    };

    let remake = me.stats.as_ref().and_then(|s| s.early_surrender) == Some(true);
    let champion = match me.champion_id {
        Some(id) if id > 0 => champions.get(&id).cloned().unwrap_or_else(|| format!("Champion {}", id)),
        _ => "Unknown".to_string(),
    };

    let match_id = match game.game_id {
        Some(id) if id > 0.0 => format!("{}_{:.0}", game.platform_id.unwrap_or_default(), id),
        _ => String::new(),
    };

    let result = if remake {
        GameResult::Remake
    } else if me.stats.as_ref().and_then(|s| s.win) == Some(true) {
        GameResult::Victory
    } else {
        GameResult::Defeat
    };

    Some(LastGame {
        champion,
        queue: crate::models::queue_name(game.queue_id, game.game_mode.as_deref()),
        result,
        kills: me.stats.as_ref().and_then(|s| s.kills).unwrap_or(0),
        deaths: me.stats.as_ref().and_then(|s| s.deaths).unwrap_or(0),
        assists: me.stats.as_ref().and_then(|s| s.assists).unwrap_or(0),
        duration_seconds: duration,
        played_at,
        match_id,
        player: crate::models::LastGamePlayer::Unknown,
    })
}

// MARK: - Behaviour snapshot → penalties

#[derive(Debug, Default, Clone)]
pub struct BehaviourSnapshot {
    pub honor: Option<HonorProfile>,
    pub low_priority_penalty_seconds: Option<f64>,
    pub punished_games_remaining: Option<i64>,
    pub lockout_expiry: Option<chrono::DateTime<Utc>>,
    pub has_active_penalty: bool,
    pub reform_card: Option<String>,
    pub restrictions: Vec<Penalty>,
}

/// Combines the behaviour snapshot into a list of client penalties, matching
/// `LCU.penalties(from:)`.
pub fn penalties_from(snapshot: &BehaviourSnapshot) -> Vec<Penalty> {
    let now = Utc::now();
    let mut result: Vec<Penalty> = snapshot.restrictions.clone();

    if let Some(seconds) = snapshot.low_priority_penalty_seconds {
        if seconds > 0.0 {
            let minutes = (seconds / 60.0).round() as i64;
            result.push(Penalty {
                id: uuid::Uuid::new_v4(),
                source: PenaltySource::Client,
                kind: PenaltyKind::QueueDelay,
                detail: format!("{} minute{} added to each queue", minutes, if minutes == 1 { "" } else { "s" }),
                started_at: now,
                expires_at: Some(now + chrono::Duration::seconds(seconds as i64)),
                resolved: false,
            });
        }
    }

    if let Some(games) = snapshot.punished_games_remaining {
        if games > 0 {
            result.push(Penalty {
                id: uuid::Uuid::new_v4(),
                source: PenaltySource::Client,
                kind: PenaltyKind::LowPriorityQueue,
                detail: format!("{} game{} remaining", games, if games == 1 { "" } else { "s" }),
                started_at: now,
                expires_at: None,
                resolved: false,
            });
        }
    }

    if let Some(lockout) = snapshot.lockout_expiry {
        if lockout > now {
            result.push(Penalty {
                id: uuid::Uuid::new_v4(),
                source: PenaltySource::Client,
                kind: PenaltyKind::QueueDelay,
                detail: "Queue lockout".to_string(),
                started_at: now,
                expires_at: Some(lockout),
                resolved: false,
            });
        }
    }

    if let Some(card) = &snapshot.reform_card {
        result.push(Penalty {
            id: uuid::Uuid::new_v4(),
            source: PenaltySource::Client,
            kind: PenaltyKind::ChatRestriction,
            detail: card.clone(),
            started_at: now,
            expires_at: None,
            resolved: false,
        });
    }

    result
}

// MARK: - Refresh snapshot

#[derive(Debug, Clone)]
pub struct Summoner {
    pub puuid: String,
    pub game_name: String,
    pub tag_line: String,
    pub summoner_id: Option<i64>,
    pub summoner_level: Option<i64>,
    pub profile_icon_id: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub summoner: Summoner,
    pub region: Option<Region>,
    pub ranks: Vec<RankEntry>,
    pub last_game: Option<LastGame>,
    pub champions: Vec<OwnedChampion>,
    pub blue_essence: Option<i64>,
    pub riot_points: Option<i64>,
    pub honor: Option<HonorProfile>,
    pub behaviour: Option<BehaviourSnapshot>,
    pub recent_games: Option<i64>,
}

/// Folds a refresh snapshot into an account — identity, ranks (peak preserved),
/// last game (attribution preserved), champions, wallet, honor and the
/// client-reported penalties. Matches `Account.applySnapshot`.
pub fn apply_snapshot(account: &mut Account, snap: &Snapshot) {
    let me = &snap.summoner;
    account.puuid = Some(me.puuid.clone());
    account.apply_riot_id(&me.game_name, &me.tag_line);
    account.summoner_level = me.summoner_level;
    if let Some(icon) = me.profile_icon_id {
        account.profile_icon_id = Some(icon);
    }
    if let Some(region) = snap.region {
        account.region = region;
    }
    for entry in &snap.ranks {
        account.apply_live_rank(entry.clone());
    }
    if let Some(game) = &snap.last_game {
        account.apply_live_last_game(game.clone());
    }
    if !snap.champions.is_empty() {
        account.owned_champions = snap.champions.clone();
    }
    if let Some(be) = snap.blue_essence {
        account.blue_essence = Some(be);
    }
    if let Some(rp) = snap.riot_points {
        account.riot_points = Some(rp);
    }
    if let Some(count) = snap.recent_games {
        account.recent_games = Some(count);
        account.recent_games_as_of = Some(Utc::now());
    }
    if let Some(honor) = &snap.honor {
        account.honor_level = honor.level;
        let behaviour = snap.behaviour.clone().unwrap_or(BehaviourSnapshot {
            honor: Some(honor.clone()),
            ..Default::default()
        });
        account.replace_client_penalties(penalties_from(&behaviour));
    }
    account.last_refreshed = Some(Utc::now());
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;
    use crate::models::{Account, Division, PenaltyKind, RankedQueue, Tier};

    #[test]
    fn ranked_stats_parse() {
        let json = br#"{"queueMap":{
            "RANKED_SOLO_5x5":{"queueType":"RANKED_SOLO_5x5","tier":"DIAMOND","division":"II","leaguePoints":44,"wins":30,"losses":20},
            "RANKED_FLEX_SR":{"queueType":"RANKED_FLEX_SR","tier":"GOLD","division":"NA","leaguePoints":0,"wins":1,"losses":2}
        }}"#;
        let ranks = parse_ranked_stats(json);
        let solo = ranks.iter().find(|r| r.queue == RankedQueue::Solo).unwrap();
        assert_eq!(solo.tier, Tier::Diamond);
        assert_eq!(solo.division, Division::Ii);
        assert_eq!(solo.lp, 44);
        let flex = ranks.iter().find(|r| r.queue == RankedQueue::Flex).unwrap();
        assert_eq!(flex.tier, Tier::Gold);
        assert_eq!(flex.division, Division::Iv); // "NA" falls back to IV
    }

    #[test]
    fn last_game_parse_victory() {
        let mut champions = HashMap::new();
        champions.insert(103, "Ahri".to_string());
        let json = br#"{"games":{"games":[{
            "gameId": 123, "platformId":"NA1", "gameCreation": 1700000000000, "gameDuration": 1800,
            "queueId": 420, "gameMode":"CLASSIC",
            "participants":[{"participantId":1,"championId":103,
                "stats":{"kills":10,"deaths":2,"assists":8,"win":true}}],
            "participantIdentities":[{"participantId":1,"player":{"puuid":"ME"}}]
        }]}}"#;
        let g = parse_last_game(json, "ME", &champions).unwrap();
        assert_eq!(g.champion, "Ahri");
        assert_eq!(g.result, GameResult::Victory);
        assert_eq!(g.kda(), "10/2/8");
        assert_eq!(g.duration_seconds, 1800);
        assert_eq!(g.match_id, "NA1_123");
        assert_eq!(g.queue, "Ranked Solo/Duo");
    }

    #[test]
    fn apply_snapshot_updates_identity_and_preserves_peak() {
        let mut a = Account::new();
        a.set_rank(RankEntry {
            queue: RankedQueue::Solo,
            tier: Tier::Gold,
            division: Division::I,
            lp: 0, wins: 0, losses: 0,
            peak_tier: Tier::Diamond,
            peak_division: Division::Iv,
            peak_note: "kept".into(),
        });
        let mut live = RankEntry::new(RankedQueue::Solo);
        live.tier = Tier::Silver;
        let snap = Snapshot {
            summoner: Summoner {
                puuid: "P".into(), game_name: "New".into(), tag_line: "NA1".into(),
                summoner_id: Some(5), summoner_level: Some(321), profile_icon_id: Some(29),
            },
            region: Some(Region::Euw1),
            ranks: vec![live],
            last_game: None,
            champions: vec![OwnedChampion { id: 1, name: "Annie".into() }],
            blue_essence: Some(5000),
            riot_points: Some(10),
            honor: Some(HonorProfile { level: Some(3), rewards_locked: false, games_remaining: None, games_required: None }),
            behaviour: None,
            recent_games: Some(7),
        };
        apply_snapshot(&mut a, &snap);
        assert_eq!(a.game_name, "New");
        assert_eq!(a.region, Region::Euw1);
        assert_eq!(a.summoner_level, Some(321));
        assert_eq!(a.solo_rank().tier, Tier::Silver);
        assert_eq!(a.solo_rank().peak_tier, Tier::Diamond); // preserved
        assert_eq!(a.solo_rank().peak_note, "kept");
        assert_eq!(a.blue_essence, Some(5000));
        assert_eq!(a.honor_level, Some(3));
        assert_eq!(a.recent_games, Some(7));
        assert!(a.last_refreshed.is_some());
    }

    #[test]
    fn penalties_from_combines_sources() {
        let b = BehaviourSnapshot {
            honor: None,
            low_priority_penalty_seconds: Some(300.0),
            punished_games_remaining: Some(3),
            lockout_expiry: None,
            has_active_penalty: true,
            reform_card: None,
            restrictions: vec![],
        };
        let pens = penalties_from(&b);
        assert_eq!(pens.len(), 2);
        assert!(pens.iter().any(|p| p.kind == PenaltyKind::QueueDelay));
        assert!(pens.iter().any(|p| p.kind == PenaltyKind::LowPriorityQueue));
    }
}
