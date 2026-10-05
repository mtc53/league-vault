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
