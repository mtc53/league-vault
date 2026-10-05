//! Talking to the running League client (LCU) on Windows.
//!
//! The client writes a `lockfile` holding the loopback port and a one-time
//! password. We read it, then make authenticated HTTPS calls to
//! `https://127.0.0.1:<port>` (basic auth `riot:<password>`) and feed the
//! responses to the parsers in `leaguevault_core::lcu`, assembling a
//! `Snapshot` that `apply_snapshot` folds into an account.
//!
//! The client serves a self-signed certificate. Because every call is to
//! 127.0.0.1 and authenticated with the lockfile password, certificate
//! verification is disabled for this client only — it never reaches the network.

use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

use leaguevault_core::lcu as core_lcu;
use leaguevault_core::lcu::{BehaviourSnapshot, Snapshot, Summoner};
use leaguevault_core::models::{OwnedChampion, Region};

#[derive(Debug, thiserror::Error)]
pub enum LcuError {
    #[error("the League client does not appear to be running (no lockfile found)")]
    NotRunning,
    #[error("the lockfile is malformed: {0}")]
    BadLockfile(String),
    #[error("request to the client failed: {0}")]
    Http(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Port + password parsed from the client's lockfile.
#[derive(Debug, Clone)]
pub struct Lockfile {
    pub port: u16,
    pub password: String,
}

/// The lockfile is `name:pid:port:password:protocol`. Returns the first one found
/// among the standard install locations plus a `LEAGUE_LOCKFILE` override.
pub fn find_lockfile() -> Result<Lockfile, LcuError> {
    for path in candidate_lockfiles() {
        if let Ok(text) = std::fs::read_to_string(&path) {
            return parse_lockfile(&text);
        }
    }
    Err(LcuError::NotRunning)
}

fn parse_lockfile(text: &str) -> Result<Lockfile, LcuError> {
    let parts: Vec<&str> = text.trim().split(':').collect();
    if parts.len() < 5 {
        return Err(LcuError::BadLockfile(format!("{} fields", parts.len())));
    }
    let port = parts[2]
        .parse::<u16>()
        .map_err(|_| LcuError::BadLockfile(format!("port {:?}", parts[2])))?;
    Ok(Lockfile { port, password: parts[3].to_string() })
}

fn candidate_lockfiles() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(explicit) = std::env::var("LEAGUE_LOCKFILE") {
        if !explicit.is_empty() {
            out.push(PathBuf::from(explicit));
        }
    }
    // The usual Windows installs.
    let drives = ["C:", "D:"];
    let roots = [
        r"\Riot Games\League of Legends\lockfile",
        r"\Program Files\Riot Games\League of Legends\lockfile",
        r"\Program Files (x86)\Riot Games\League of Legends\lockfile",
        r"\Games\Riot Games\League of Legends\lockfile",
    ];
    for d in drives {
        for r in roots {
            out.push(PathBuf::from(format!("{d}{r}")));
        }
    }
    // LOCALAPPDATA is where the Riot Client records the install, and a fallback
    // copy of the lockfile sometimes lives under it.
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        out.push(PathBuf::from(local).join(r"Riot Games\League of Legends\lockfile"));
    }
    out
}

/// A client bound to one running League instance.
pub struct Client {
    base: String,
    http: reqwest::blocking::Client,
    password: String,
}

impl Client {
    pub fn connect() -> Result<Client, LcuError> {
        let lock = find_lockfile()?;
        Self::with_lockfile(&lock)
    }

    pub fn with_lockfile(lock: &Lockfile) -> Result<Client, LcuError> {
        let http = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(true) // loopback, lockfile-authenticated
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|e| LcuError::Http(e.to_string()))?;
        Ok(Client {
            base: format!("https://127.0.0.1:{}", lock.port),
            http,
            password: lock.password.clone(),
        })
    }

    /// GET an endpoint, returning the raw body. A non-2xx status is still returned
    /// (the parsers tolerate empty or error bodies), but transport errors bubble up.
    fn get(&self, path: &str) -> Result<Vec<u8>, LcuError> {
        let resp = self
            .http
            .get(format!("{}{}", self.base, path))
            .basic_auth("riot", Some(&self.password))
            .send()
            .map_err(|e| LcuError::Http(e.to_string()))?;
        let mut buf = Vec::new();
        resp.bytes()
            .map_err(|e| LcuError::Http(e.to_string()))?
            .as_ref()
            .read_to_end(&mut buf)?;
        Ok(buf)
    }

    /// GET and ignore any transport error, returning an empty body instead. Used for
    /// the optional behaviour endpoints, which are often absent.
    fn get_soft(&self, path: &str) -> Vec<u8> {
        self.get(path).unwrap_or_default()
    }

    /// Reads everything the dashboard shows for the signed-in account.
    pub fn capture_snapshot(&self) -> Result<Snapshot, LcuError> {
        let summoner = self.current_summoner()?;
        let region = self.region();

        let champions = core_lcu::parse_owned_champions(
            &self.get_soft("/lol-champions/v1/owned-champions-minimal"),
        );
        let ranks =
            core_lcu::parse_ranked_stats(&self.get_soft("/lol-ranked/v1/current-ranked-stats"));

        let wallet_body = self.get_soft("/lol-inventory/v1/wallet");
        let mut wallet = core_lcu::parse_wallet(&wallet_body, "/lol-inventory/v1/wallet");
        if wallet.blue_essence.is_none() {
            let be = self.get_soft("/lol-inventory/v1/wallet/lol_blue_essence");
            let w = core_lcu::parse_wallet(&be, "/lol-inventory/v1/wallet/lol_blue_essence");
            if w.blue_essence.is_some() {
                wallet.blue_essence = w.blue_essence;
            }
        }

        let honor = core_lcu::parse_honor(&self.get_soft("/lol-honor-v2/v1/profile"));

        let champ_names: std::collections::HashMap<i64, String> =
            champions.iter().map(|c| (c.id, c.name.clone())).collect();
        let last_game = core_lcu::parse_last_game(
            &self.get_soft(
                "/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=1",
            ),
            &summoner.puuid,
            &champ_names,
        );

        let behaviour = self.behaviour(honor.clone());

        Ok(Snapshot {
            summoner,
            region,
            ranks,
            last_game,
            champions: dedupe_champions(champions),
            blue_essence: wallet.blue_essence,
            riot_points: wallet.riot_points,
            honor,
            behaviour,
            recent_games: None,
        })
    }

    fn current_summoner(&self) -> Result<Summoner, LcuError> {
        let body = self.get("/lol-summoner/v1/current-summoner")?;
        let v: serde_json::Value =
            serde_json::from_slice(&body).map_err(|e| LcuError::Http(e.to_string()))?;
        let puuid = v.get("puuid").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if puuid.is_empty() {
            return Err(LcuError::Http("no summoner is signed in".into()));
        }
        Ok(Summoner {
            puuid,
            game_name: v
                .get("gameName")
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .or_else(|| v.get("displayName").and_then(|x| x.as_str()))
                .unwrap_or("")
                .to_string(),
            tag_line: v.get("tagLine").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            summoner_id: v.get("summonerId").and_then(|x| x.as_i64()),
            summoner_level: v.get("summonerLevel").and_then(|x| x.as_i64()),
            profile_icon_id: v.get("profileIconId").and_then(|x| x.as_i64()),
        })
    }

    fn region(&self) -> Option<Region> {
        let body = self.get_soft("/riotclient/region-locale");
        let v: serde_json::Value = serde_json::from_slice(&body).ok()?;
        let raw = v
            .get("region")
            .and_then(|x| x.as_str())
            .map(|s| s.to_lowercase())?;
        region_from_platform(&raw)
    }

    /// Assembles the behaviour snapshot from the endpoints that map cleanly. The
    /// fuller behaviour fold (low-priority seconds, punished games) needs a live
    /// client to validate and is filled in as that stage lands.
    fn behaviour(&self, honor: Option<core_lcu::HonorProfile>) -> Option<BehaviourSnapshot> {
        honor.as_ref()?;
        let restrictions =
            core_lcu::parse_restrictions(&self.get_soft("/lol-player-behavior/v1/restrictions"));
        let lockout_expiry = self.lockout_expiry();
        Some(BehaviourSnapshot {
            honor,
            low_priority_penalty_seconds: None,
            punished_games_remaining: None,
            lockout_expiry,
            has_active_penalty: !restrictions.is_empty() || lockout_expiry.is_some(),
            reform_card: None,
            restrictions,
        })
    }

    fn lockout_expiry(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        let body = self.get_soft("/lol-leaver-buster/v1/queue-lockout");
        let v: serde_json::Value = serde_json::from_slice(&body).ok()?;
        // The client reports the remaining penalty time in seconds.
        let secs = v
            .get("penaltyTime")
            .and_then(|x| x.as_f64())
            .or_else(|| v.get("penaltyTimeRemaining").and_then(|x| x.as_f64()))?;
        if secs <= 0.0 {
            return None;
        }
        Some(chrono::Utc::now() + chrono::Duration::seconds(secs as i64))
    }
}

/// Riot platform id (e.g. "na1") → our `Region`.
fn region_from_platform(raw: &str) -> Option<Region> {
    use Region::*;
    Some(match raw {
        "na" | "na1" => Na1,
        "br" | "br1" => Br1,
        "la1" | "lan" => La1,
        "la2" | "las" => La2,
        "euw" | "euw1" => Euw1,
        "eune" | "eun1" => Eun1,
        "tr" | "tr1" => Tr1,
        "ru" => Ru,
        "me" | "me1" => Me1,
        "kr" => Kr,
        "jp" | "jp1" => Jp1,
        "oce" | "oc1" => Oc1,
        "ph" | "ph2" => Ph2,
        "sg" | "sg2" => Sg2,
        "th" | "th2" => Th2,
        "tw" | "tw2" => Tw2,
        "vn" | "vn2" => Vn2,
        _ => return None,
    })
}

/// The owned-champions endpoint occasionally lists a champion twice; keep one each.
fn dedupe_champions(mut champs: Vec<OwnedChampion>) -> Vec<OwnedChampion> {
    champs.sort_by_key(|c| c.id);
    champs.dedup_by_key(|c| c.id);
    champs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_lockfile() {
        let lock = parse_lockfile("LeagueClient:4242:51777:abcdEFGH:https").unwrap();
        assert_eq!(lock.port, 51777);
        assert_eq!(lock.password, "abcdEFGH");
    }

    #[test]
    fn rejects_a_short_lockfile() {
        assert!(parse_lockfile("LeagueClient:4242:51777").is_err());
    }

    #[test]
    fn maps_platform_regions() {
        assert_eq!(region_from_platform("na1"), Some(Region::Na1));
        assert_eq!(region_from_platform("euw1"), Some(Region::Euw1));
        assert_eq!(region_from_platform("kr"), Some(Region::Kr));
        assert_eq!(region_from_platform("nonsense"), None);
    }
}
