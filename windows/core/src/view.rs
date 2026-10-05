//! The view-model the dashboard UI consumes, ported from `WebDashboard.swift`.
//!
//! The macOS app and the published web page share one HTML/JS renderer
//! (`Resources/dashboard.html`), which reads a `SitePayload`. The Windows app
//! reuses that same renderer inside the Tauri window, so the core produces the
//! exact same shape here. Keeping it in `core` means it is testable on any
//! platform and identical whether it feeds the live window or a published file.

use crate::models::*;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteRegion {
    pub code: String,
    pub short: String,
    pub long: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteRank {
    pub tier: String,
    pub div: String,
    pub lp: i64,
    pub wins: i64,
    pub losses: i64,
    #[serde(rename = "peakTier")]
    pub peak_tier: String,
    #[serde(rename = "peakDiv")]
    pub peak_div: String,
    #[serde(rename = "peakNote")]
    pub peak_note: String,
}

impl SiteRank {
    fn from(r: &RankEntry) -> Self {
        SiteRank {
            tier: r.tier.raw().to_string(),
            div: r.division.raw().to_string(),
            lp: r.lp,
            wins: r.wins,
            losses: r.losses,
            peak_tier: r.peak_tier.raw().to_string(),
            peak_div: r.peak_division.raw().to_string(),
            peak_note: r.peak_note.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteGame {
    pub champion: String,
    #[serde(rename = "championId", skip_serializing_if = "Option::is_none")]
    pub champion_id: Option<i64>,
    pub queue: String,
    pub result: String,
    pub kda: String,
    pub duration: String,
    #[serde(rename = "playedAt")]
    pub played_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub player: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SitePenalty {
    pub kind: String,
    pub detail: String,
    pub status: String,
    pub source: String,
    pub active: bool,
    pub critical: bool,
    #[serde(rename = "startedAt")]
    pub started_at: DateTime<Utc>,
    #[serde(rename = "expiresAt", skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteChampion {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteAccount {
    pub id: String,
    pub name: String,
    #[serde(rename = "riotId")]
    pub riot_id: String,
    pub folder: String,
    pub notes: String,
    /// Only carried when the page is locked — a login on an open page is a giveaway.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
    pub region: SiteRegion,
    /// "FA", "NFA", or absent when it was never recorded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<i64>,
    #[serde(rename = "iconId", skip_serializing_if = "Option::is_none")]
    pub icon_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub be: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rp: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub honor: Option<i64>,
    /// Keyed "solo" and "flex" so the page can read them by name.
    pub ranks: std::collections::HashMap<String, SiteRank>,
    #[serde(rename = "lastGame", skip_serializing_if = "Option::is_none")]
    pub last_game: Option<SiteGame>,
    pub penalties: Vec<SitePenalty>,
    pub champions: Vec<SiteChampion>,
    /// Whole days since the last recorded game; absent when no game is on record.
    #[serde(rename = "idleDays", skip_serializing_if = "Option::is_none")]
    pub idle_days: Option<i64>,
    #[serde(rename = "lastRefreshed", skip_serializing_if = "Option::is_none")]
    pub last_refreshed: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ugg: Option<String>,
}

impl SiteAccount {
    pub fn from_account(a: &Account, include_login: bool, now: DateTime<Utc>) -> Self {
        let last_game = a.last_game.as_ref().map(|g| {
            let champion_id = a
                .owned_champions
                .iter()
                .find(|c| c.name.eq_ignore_ascii_case(&g.champion))
                .map(|c| c.id);
            SiteGame {
                champion: g.champion.clone(),
                champion_id,
                queue: g.queue.clone(),
                result: match g.result {
                    GameResult::Victory => "Victory",
                    GameResult::Defeat => "Defeat",
                    GameResult::Remake => "Remake",
                }
                .to_string(),
                kda: g.kda(),
                duration: g.duration_display(),
                played_at: g.played_at,
                player: match g.player {
                    LastGamePlayer::Unknown => None,
                    LastGamePlayer::Me => Some("ME".to_string()),
                    LastGamePlayer::SomeoneElse => Some("SOMEONE_ELSE".to_string()),
                },
            }
        });

        // Worst first, so the page can show the leading badge without re-sorting.
        let mut penalties: Vec<&Penalty> = a.penalties.iter().collect();
        penalties.sort_by_key(|p| p.kind.severity_rank());
        let penalties = penalties
            .into_iter()
            .map(|p| SitePenalty {
                kind: penalty_kind_raw(p.kind).to_string(),
                detail: p.detail.clone(),
                status: p.status_display_at(now),
                source: match p.source {
                    PenaltySource::Manual => "manual",
                    PenaltySource::Client => "client",
                }
                .to_string(),
                active: p.is_active_at(now),
                critical: p.kind.is_critical(),
                started_at: p.started_at,
                expires_at: p.expires_at,
            })
            .collect();

        let mut champions: Vec<SiteChampion> = a
            .owned_champions
            .iter()
            .map(|c| SiteChampion { id: c.id, name: c.name.clone() })
            .collect();
        champions.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

        let mut ranks = std::collections::HashMap::new();
        ranks.insert("solo".to_string(), SiteRank::from(&a.solo_rank()));
        ranks.insert("flex".to_string(), SiteRank::from(&a.flex_rank()));

        SiteAccount {
            id: a.id.to_string(),
            name: a.display_name(),
            riot_id: a.riot_id(),
            folder: a.folder.clone(),
            notes: a.notes.clone(),
            login: if include_login && !a.login_username.is_empty() {
                Some(a.login_username.clone())
            } else {
                None
            },
            region: SiteRegion {
                code: a.region.raw().to_string(),
                short: a.region.display().to_string(),
                long: a.region.long_name().to_string(),
            },
            access: if a.access == AccessLevel::Unknown {
                None
            } else {
                Some(a.access.raw().to_string())
            },
            level: a.summoner_level,
            icon_id: a.profile_icon_id,
            be: a.blue_essence,
            rp: a.riot_points,
            honor: a.honor_level,
            ranks,
            last_game,
            penalties,
            champions,
            idle_days: a.days_since_last_game_at(now),
            last_refreshed: a.last_refreshed,
            ugg: a.ugg_url(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SitePayload {
    pub title: String,
    pub origin: String,
    #[serde(rename = "publishedAt")]
    pub published_at: DateTime<Utc>,
    pub accounts: Vec<SiteAccount>,
}

/// Builds the payload the dashboard renderer reads.
pub fn build_payload(
    accounts: &[Account],
    title: &str,
    origin: &str,
    include_logins: bool,
    now: DateTime<Utc>,
) -> SitePayload {
    SitePayload {
        title: title.to_string(),
        origin: origin.to_string(),
        published_at: now,
        accounts: accounts
            .iter()
            .map(|a| SiteAccount::from_account(a, include_logins, now))
            .collect(),
    }
}

/// The penalty-kind raw string the dashboard matches on (same as the Swift rawValue).
fn penalty_kind_raw(kind: PenaltyKind) -> &'static str {
    use PenaltyKind::*;
    match kind {
        ChatRestriction => "Chat restriction",
        VoiceMuted => "Team voice muted",
        RankedRestriction => "Ranked restriction",
        LowPriorityQueue => "Low priority queue",
        QueueDelay => "Queue delay",
        DodgeTimer => "Dodge timer",
        HonorDowngrade => "Honor downgrade",
        Suspension => "Temporary suspension",
        PermanentBan => "Permanent ban",
        HonorLock => "Honor level lock",
        Other => "Other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn sample() -> Account {
        let mut a = Account::new();
        a.label = "Main".into();
        a.game_name = "Faker".into();
        a.tag_line = "KR1".into();
        a.region = Region::Kr;
        a.access = AccessLevel::FullAccess;
        a.summoner_level = Some(430);
        a.blue_essence = Some(12345);
        a.owned_champions = vec![
            OwnedChampion { id: 157, name: "Yasuo".into() },
            OwnedChampion { id: 1, name: "Annie".into() },
        ];
        a.set_rank(RankEntry {
            queue: RankedQueue::Solo,
            tier: Tier::Diamond,
            division: Division::Ii,
            lp: 44,
            wins: 30,
            losses: 20,
            peak_tier: Tier::Master,
            peak_division: Division::Iv,
            peak_note: "S14".into(),
        });
        a.normalize();
        a
    }

    #[test]
    fn payload_shape_matches_dashboard() {
        let now = Utc.with_ymd_and_hms(2026, 10, 5, 0, 0, 0).unwrap();
        let p = build_payload(&[sample()], "League Vault", "DESKTOP-PC", false, now);
        let v: serde_json::Value = serde_json::to_value(&p).unwrap();
        let acct = &v["accounts"][0];

        assert_eq!(acct["name"], "Main");
        assert_eq!(acct["riotId"], "Faker#KR1");
        assert_eq!(acct["region"]["short"], "KR");
        assert_eq!(acct["region"]["long"], "Korea");
        assert_eq!(acct["access"], "FA");
        assert_eq!(acct["level"], 430);
        assert_eq!(acct["ranks"]["solo"]["tier"], "DIAMOND");
        assert_eq!(acct["ranks"]["solo"]["div"], "II");
        assert_eq!(acct["ranks"]["solo"]["peakTier"], "MASTER");
        assert_eq!(acct["ranks"]["flex"]["tier"], "UNRANKED");
        // Champions sorted case-insensitively by name: Annie before Yasuo.
        assert_eq!(acct["champions"][0]["name"], "Annie");
        assert_eq!(acct["champions"][1]["name"], "Yasuo");
        // A login is withheld unless the page is locked.
        assert!(acct.get("login").is_none());
    }

    #[test]
    fn login_included_only_when_requested() {
        let now = Utc::now();
        let mut a = sample();
        a.login_username = "faker_login".into();
        let open = build_payload(std::slice::from_ref(&a), "LV", "PC", false, now);
        assert!(open.accounts[0].login.is_none());
        let locked = build_payload(std::slice::from_ref(&a), "LV", "PC", true, now);
        assert_eq!(locked.accounts[0].login.as_deref(), Some("faker_login"));
    }

    #[test]
    fn penalties_sorted_worst_first_with_status() {
        let now = Utc.with_ymd_and_hms(2026, 10, 5, 0, 0, 0).unwrap();
        let mut a = sample();
        a.penalties = vec![
            Penalty {
                id: uuid::Uuid::new_v4(),
                source: PenaltySource::Manual,
                kind: PenaltyKind::ChatRestriction,
                detail: String::new(),
                started_at: now - Duration::days(1),
                expires_at: Some(now + Duration::days(2)),
                resolved: false,
            },
            Penalty {
                id: uuid::Uuid::new_v4(),
                source: PenaltySource::Client,
                kind: PenaltyKind::QueueDelay,
                detail: "low priority".into(),
                started_at: now - Duration::hours(1),
                expires_at: Some(now + Duration::minutes(45)),
                resolved: false,
            },
        ];
        let p = build_payload(&[a], "LV", "PC", false, now);
        let pens = &p.accounts[0].penalties;
        // Queue delay (severity 0) leads chat restriction (severity 5).
        assert_eq!(pens[0].kind, "Queue delay");
        assert!(pens[0].critical);
        assert_eq!(pens[0].status, "Active — 45 minutes left");
        assert_eq!(pens[0].source, "client");
        assert_eq!(pens[1].kind, "Chat restriction");
        assert_eq!(pens[1].status, "Active — 2 days left");
    }
}
