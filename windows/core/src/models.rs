//! The League Vault data model, ported from `Sources/Models.swift`.
//!
//! The JSON on-disk shape is kept identical to the macOS app's `accounts.json`
//! (camelCase keys, ISO-8601 dates, enum raw values unchanged), so a vault can
//! be carried across. Stored passwords are the one thing that cannot move: the
//! AES key lives in the Mac Keychain, so on Windows those are re-entered.

use chrono::{DateTime, Datelike, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// MARK: - Region

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Region {
    Na1,
    Br1,
    La1,
    La2,
    Euw1,
    Eun1,
    Tr1,
    Ru,
    Me1,
    Kr,
    Jp1,
    Oc1,
    Ph2,
    Sg2,
    Th2,
    Tw2,
    Vn2,
}

impl Default for Region {
    fn default() -> Self {
        Region::Na1
    }
}

impl Region {
    /// The raw value used on the wire and in Riot URLs (e.g. "na1").
    pub fn raw(self) -> &'static str {
        use Region::*;
        match self {
            Na1 => "na1", Br1 => "br1", La1 => "la1", La2 => "la2", Euw1 => "euw1",
            Eun1 => "eun1", Tr1 => "tr1", Ru => "ru", Me1 => "me1", Kr => "kr",
            Jp1 => "jp1", Oc1 => "oc1", Ph2 => "ph2", Sg2 => "sg2", Th2 => "th2",
            Tw2 => "tw2", Vn2 => "vn2",
        }
    }

    pub fn display(self) -> &'static str {
        use Region::*;
        match self {
            Na1 => "NA", Br1 => "BR", La1 => "LAN", La2 => "LAS", Euw1 => "EUW",
            Eun1 => "EUNE", Tr1 => "TR", Ru => "RU", Me1 => "ME", Kr => "KR",
            Jp1 => "JP", Oc1 => "OCE", Ph2 => "PH", Sg2 => "SG", Th2 => "TH",
            Tw2 => "TW", Vn2 => "VN",
        }
    }

    pub fn long_name(self) -> &'static str {
        use Region::*;
        match self {
            Na1 => "North America", Br1 => "Brazil", La1 => "Latin America North",
            La2 => "Latin America South", Euw1 => "Europe West",
            Eun1 => "Europe Nordic & East", Tr1 => "Türkiye", Ru => "Russia",
            Me1 => "Middle East", Kr => "Korea", Jp1 => "Japan", Oc1 => "Oceania",
            Ph2 => "Philippines", Sg2 => "Singapore", Th2 => "Thailand",
            Tw2 => "Taiwan", Vn2 => "Vietnam",
        }
    }
}

// MARK: - Rank

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Tier {
    #[serde(rename = "UNRANKED")]
    Unranked,
    #[serde(rename = "IRON")]
    Iron,
    #[serde(rename = "BRONZE")]
    Bronze,
    #[serde(rename = "SILVER")]
    Silver,
    #[serde(rename = "GOLD")]
    Gold,
    #[serde(rename = "PLATINUM")]
    Platinum,
    #[serde(rename = "EMERALD")]
    Emerald,
    #[serde(rename = "DIAMOND")]
    Diamond,
    #[serde(rename = "MASTER")]
    Master,
    #[serde(rename = "GRANDMASTER")]
    Grandmaster,
    #[serde(rename = "CHALLENGER")]
    Challenger,
}

impl Default for Tier {
    fn default() -> Self {
        Tier::Unranked
    }
}

impl Tier {
    /// Ladder order, Unranked = 0 … Challenger = 10. Matches the order of the
    /// Swift `allCases`, which several calculations index into.
    pub fn ladder_index(self) -> i64 {
        use Tier::*;
        match self {
            Unranked => 0, Iron => 1, Bronze => 2, Silver => 3, Gold => 4,
            Platinum => 5, Emerald => 6, Diamond => 7, Master => 8,
            Grandmaster => 9, Challenger => 10,
        }
    }

    pub fn display(self) -> String {
        // "IRON" -> "Iron"
        let raw = self.raw();
        let mut c = raw.chars();
        match c.next() {
            Some(first) => first.to_string() + &c.as_str().to_lowercase(),
            None => String::new(),
        }
    }

    pub fn raw(self) -> &'static str {
        use Tier::*;
        match self {
            Unranked => "UNRANKED", Iron => "IRON", Bronze => "BRONZE",
            Silver => "SILVER", Gold => "GOLD", Platinum => "PLATINUM",
            Emerald => "EMERALD", Diamond => "DIAMOND", Master => "MASTER",
            Grandmaster => "GRANDMASTER", Challenger => "CHALLENGER",
        }
    }

    /// Master and above have no divisions.
    pub fn is_apex(self) -> bool {
        matches!(self, Tier::Master | Tier::Grandmaster | Tier::Challenger)
    }

    pub fn from_raw(raw: Option<&str>) -> Tier {
        match raw {
            None => Tier::Unranked,
            Some(r) => match r.to_uppercase().as_str() {
                "IRON" => Tier::Iron, "BRONZE" => Tier::Bronze, "SILVER" => Tier::Silver,
                "GOLD" => Tier::Gold, "PLATINUM" => Tier::Platinum, "EMERALD" => Tier::Emerald,
                "DIAMOND" => Tier::Diamond, "MASTER" => Tier::Master,
                "GRANDMASTER" => Tier::Grandmaster, "CHALLENGER" => Tier::Challenger,
                _ => Tier::Unranked,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Division {
    #[serde(rename = "I")]
    I,
    #[serde(rename = "II")]
    Ii,
    #[serde(rename = "III")]
    Iii,
    #[serde(rename = "IV")]
    Iv,
}

impl Default for Division {
    fn default() -> Self {
        Division::Iv
    }
}

impl Division {
    pub fn raw(self) -> &'static str {
        match self {
            Division::I => "I", Division::Ii => "II", Division::Iii => "III", Division::Iv => "IV",
        }
    }
    /// Index in the Swift `allCases` order [I, II, III, IV].
    pub fn index(self) -> i64 {
        match self {
            Division::I => 0, Division::Ii => 1, Division::Iii => 2, Division::Iv => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RankedQueue {
    #[serde(rename = "RANKED_SOLO_5x5")]
    Solo,
    #[serde(rename = "RANKED_FLEX_SR")]
    Flex,
}

impl RankedQueue {
    pub fn display(self) -> &'static str {
        match self {
            RankedQueue::Solo => "Solo/Duo",
            RankedQueue::Flex => "Flex",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RankEntry {
    pub queue: RankedQueue,
    #[serde(default)]
    pub tier: Tier,
    #[serde(default)]
    pub division: Division,
    #[serde(default)]
    pub lp: i64,
    #[serde(default)]
    pub wins: i64,
    #[serde(default)]
    pub losses: i64,
    #[serde(default, rename = "peakTier")]
    pub peak_tier: Tier,
    #[serde(default, rename = "peakDivision")]
    pub peak_division: Division,
    #[serde(default, rename = "peakNote")]
    pub peak_note: String,
}

impl RankEntry {
    pub fn new(queue: RankedQueue) -> Self {
        RankEntry {
            queue,
            tier: Tier::Unranked,
            division: Division::Iv,
            lp: 0,
            wins: 0,
            losses: 0,
            peak_tier: Tier::Unranked,
            peak_division: Division::Iv,
            peak_note: String::new(),
        }
    }

    pub fn games(&self) -> i64 {
        self.wins + self.losses
    }

    pub fn winrate(&self) -> f64 {
        if self.games() == 0 {
            0.0
        } else {
            self.wins as f64 / self.games() as f64 * 100.0
        }
    }

    pub fn short_display(&self) -> String {
        if self.tier == Tier::Unranked {
            return "Unranked".to_string();
        }
        if self.tier.is_apex() {
            format!("{} {} LP", self.tier.display(), self.lp)
        } else {
            format!("{} {} · {} LP", self.tier.display(), self.division.raw(), self.lp)
        }
    }

    pub fn has_peak(&self) -> bool {
        self.peak_tier != Tier::Unranked
    }

    /// Orders tier+division on the ladder. Apex tiers have no divisions, so they
    /// sit at the top of their tier.
    pub fn ladder_position(tier: Tier, division: Division) -> i64 {
        if tier == Tier::Unranked {
            return 0;
        }
        let tier_index = tier.ladder_index();
        let division_index = if tier.is_apex() { 4 } else { 4 - division.index() };
        tier_index * 10 + division_index
    }

    /// Orders accounts in a list: ladder position with LP as the tiebreak. An
    /// unranked account is placed by its peak, always beneath anyone ranked.
    pub fn sort_weight(&self) -> i64 {
        if self.tier == Tier::Unranked {
            return self.peak_tier.ladder_index() * 100;
        }
        RankEntry::ladder_position(self.tier, self.division) * 1_000 + self.lp
    }

    pub fn peak_display(&self) -> Option<String> {
        if !self.has_peak() {
            return None;
        }
        Some(if self.peak_tier.is_apex() {
            self.peak_tier.display()
        } else {
            format!("{} {}", self.peak_tier.display(), self.peak_division.raw())
        })
    }

    pub fn display_with_fallback(&self) -> String {
        if self.tier != Tier::Unranked {
            return self.short_display();
        }
        match self.peak_display() {
            Some(peak) => format!("Unranked · peak {}", peak),
            None => "Unranked".to_string(),
        }
    }

    /// Colour to tint by: the live tier, or the peak when unranked.
    pub fn effective_tier(&self) -> Tier {
        if self.tier == Tier::Unranked {
            self.peak_tier
        } else {
            self.tier
        }
    }
}

// MARK: - Queues

/// Human names for Riot queue ids.
pub fn queue_name(id: Option<i64>, fallback: Option<&str>) -> String {
    const NAMES: &[(i64, &str)] = &[
        (400, "Normal Draft"), (420, "Ranked Solo/Duo"), (430, "Normal Blind"),
        (440, "Ranked Flex"), (450, "ARAM"), (490, "Quickplay"),
        (700, "Clash"), (720, "ARAM Clash"),
        (830, "Co-op vs AI (Intro)"), (840, "Co-op vs AI (Beginner)"),
        (850, "Co-op vs AI (Intermediate)"), (870, "Co-op vs AI (Intro)"),
        (880, "Co-op vs AI (Beginner)"), (890, "Co-op vs AI (Intermediate)"),
        (900, "ARURF"), (1020, "One for All"), (1300, "Nexus Blitz"),
        (1400, "Ultimate Spellbook"), (1700, "Arena"), (1710, "Arena"), (1900, "URF"),
        (2000, "Tutorial"), (2010, "Tutorial"), (2020, "Tutorial"),
    ];
    if let Some(id) = id {
        if let Some((_, name)) = NAMES.iter().find(|(k, _)| *k == id) {
            return name.to_string();
        }
    }
    if let Some(fb) = fallback {
        if !fb.is_empty() {
            // Swift uses .capitalized (title-case each word).
            return fb
                .split_whitespace()
                .map(|w| {
                    let mut ch = w.chars();
                    match ch.next() {
                        Some(f) => f.to_uppercase().collect::<String>() + &ch.as_str().to_lowercase(),
                        None => String::new(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" ");
        }
    }
    match id {
        Some(id) => format!("Queue {}", id),
        None => "Custom".to_string(),
    }
}

// MARK: - Last game

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GameResult {
    #[serde(rename = "Victory")]
    Victory,
    #[serde(rename = "Defeat")]
    Defeat,
    #[serde(rename = "Remake")]
    Remake,
}

impl Default for GameResult {
    fn default() -> Self {
        GameResult::Victory
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LastGamePlayer {
    #[serde(rename = "UNKNOWN")]
    Unknown,
    #[serde(rename = "ME")]
    Me,
    #[serde(rename = "SOMEONE_ELSE")]
    SomeoneElse,
}

impl Default for LastGamePlayer {
    fn default() -> Self {
        LastGamePlayer::Unknown
    }
}

impl LastGamePlayer {
    pub fn display(self) -> &'static str {
        match self {
            LastGamePlayer::Unknown => "Not said",
            LastGamePlayer::Me => "Me",
            LastGamePlayer::SomeoneElse => "Someone else",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LastGame {
    #[serde(default)]
    pub champion: String,
    #[serde(default)]
    pub queue: String,
    #[serde(default)]
    pub result: GameResult,
    #[serde(default)]
    pub kills: i64,
    #[serde(default)]
    pub deaths: i64,
    #[serde(default)]
    pub assists: i64,
    #[serde(default, rename = "durationSeconds")]
    pub duration_seconds: i64,
    #[serde(default = "Utc::now", rename = "playedAt")]
    pub played_at: DateTime<Utc>,
    #[serde(default, rename = "matchId")]
    pub match_id: String,
    #[serde(default)]
    pub player: LastGamePlayer,
}

impl Default for LastGame {
    fn default() -> Self {
        LastGame {
            champion: String::new(),
            queue: String::new(),
            result: GameResult::Victory,
            kills: 0,
            deaths: 0,
            assists: 0,
            duration_seconds: 0,
            played_at: Utc::now(),
            match_id: String::new(),
            player: LastGamePlayer::Unknown,
        }
    }
}

impl LastGame {
    pub fn kda(&self) -> String {
        format!("{}/{}/{}", self.kills, self.deaths, self.assists)
    }

    pub fn kda_ratio(&self) -> f64 {
        if self.deaths == 0 {
            (self.kills + self.assists) as f64
        } else {
            (self.kills + self.assists) as f64 / self.deaths as f64
        }
    }

    pub fn duration_display(&self) -> String {
        if self.duration_seconds <= 0 {
            return "—".to_string();
        }
        format!("{}:{:02}", self.duration_seconds / 60, self.duration_seconds % 60)
    }
}

// MARK: - Penalties

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PenaltyKind {
    #[serde(rename = "Chat restriction")]
    ChatRestriction,
    #[serde(rename = "Team voice muted")]
    VoiceMuted,
    #[serde(rename = "Ranked restriction")]
    RankedRestriction,
    #[serde(rename = "Low priority queue")]
    LowPriorityQueue,
    #[serde(rename = "Queue delay")]
    QueueDelay,
    #[serde(rename = "Dodge timer")]
    DodgeTimer,
    #[serde(rename = "Honor downgrade")]
    HonorDowngrade,
    #[serde(rename = "Temporary suspension")]
    Suspension,
    #[serde(rename = "Permanent ban")]
    PermanentBan,
    #[serde(rename = "Honor level lock")]
    HonorLock,
    #[serde(rename = "Other")]
    Other,
}

impl Default for PenaltyKind {
    fn default() -> Self {
        PenaltyKind::Other
    }
}

impl PenaltyKind {
    pub fn is_permanent_by_nature(self) -> bool {
        self == PenaltyKind::PermanentBan
    }

    /// Penalties that stop you playing normally right now (red, not amber).
    pub fn is_critical(self) -> bool {
        matches!(
            self,
            PenaltyKind::QueueDelay
                | PenaltyKind::DodgeTimer
                | PenaltyKind::LowPriorityQueue
                | PenaltyKind::Suspension
                | PenaltyKind::PermanentBan
        )
    }

    /// Queue delay leads the list — the one that costs you time every game.
    pub fn severity_rank(self) -> i64 {
        use PenaltyKind::*;
        match self {
            QueueDelay => 0,
            DodgeTimer => 1,
            Suspension | PermanentBan => 2,
            LowPriorityQueue => 3,
            RankedRestriction => 4,
            ChatRestriction | VoiceMuted => 5,
            HonorDowngrade => 6,
            HonorLock | Other => 7,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PenaltySource {
    Manual,
    Client,
}

impl Default for PenaltySource {
    fn default() -> Self {
        PenaltySource::Manual
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Penalty {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub source: PenaltySource,
    #[serde(default)]
    pub kind: PenaltyKind,
    #[serde(default)]
    pub detail: String,
    #[serde(default = "Utc::now", rename = "startedAt")]
    pub started_at: DateTime<Utc>,
    #[serde(default, rename = "expiresAt")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub resolved: bool,
}

impl Penalty {
    pub fn is_active_at(&self, now: DateTime<Utc>) -> bool {
        if self.resolved {
            return false;
        }
        if self.kind.is_permanent_by_nature() {
            return true;
        }
        match self.expires_at {
            None => true,
            Some(exp) => exp > now,
        }
    }

    pub fn is_active(&self) -> bool {
        self.is_active_at(Utc::now())
    }

    /// Human status line, matching the macOS `statusDisplay`.
    pub fn status_display_at(&self, now: DateTime<Utc>) -> String {
        if self.resolved {
            return "Served".to_string();
        }
        if self.kind.is_permanent_by_nature() {
            return "Permanent".to_string();
        }
        let expires = match self.expires_at {
            None => return "Active — no end date".to_string(),
            Some(e) => e,
        };
        if expires <= now {
            return "Expired".to_string();
        }
        let remaining = expires - now;
        let days = remaining.num_days();
        if days >= 1 {
            return format!("Active — {} day{} left", days, if days == 1 { "" } else { "s" });
        }
        let hours = remaining.num_hours();
        let minutes = remaining.num_minutes() - hours * 60;
        if hours >= 1 {
            return format!("Active — {}h {}m left", hours, minutes);
        }
        let shown = remaining.num_minutes().max(1);
        format!("Active — {} minute{} left", shown, if shown == 1 { "" } else { "s" })
    }

    pub fn status_display(&self) -> String {
        self.status_display_at(Utc::now())
    }

    /// A dodge timer is a fixed-hours wait, recorded by hand.
    pub fn dodge_timer(hours: i64, note: &str) -> Penalty {
        let now = Utc::now();
        Penalty {
            id: Uuid::new_v4(),
            source: PenaltySource::Manual,
            kind: PenaltyKind::DodgeTimer,
            detail: if note.is_empty() {
                format!("{}-hour dodge timer", hours)
            } else {
                note.to_string()
            },
            started_at: now,
            expires_at: Some(now + chrono::Duration::hours(hours)),
            resolved: false,
        }
    }
}

// MARK: - Champions

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnedChampion {
    pub id: i64,
    pub name: String,
}

// MARK: - Access level

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccessLevel {
    #[serde(rename = "UNKNOWN")]
    Unknown,
    #[serde(rename = "FA")]
    FullAccess,
    #[serde(rename = "NFA")]
    NotFullAccess,
}

impl Default for AccessLevel {
    fn default() -> Self {
        AccessLevel::Unknown
    }
}

impl AccessLevel {
    pub fn raw(self) -> &'static str {
        match self {
            AccessLevel::Unknown => "UNKNOWN",
            AccessLevel::FullAccess => "FA",
            AccessLevel::NotFullAccess => "NFA",
        }
    }
    pub fn short(self) -> &'static str {
        match self {
            AccessLevel::Unknown => "—",
            AccessLevel::FullAccess => "FA",
            AccessLevel::NotFullAccess => "NFA",
        }
    }
}

// MARK: - Account

pub const RECENT_WINDOW_DAYS: i64 = 90;
pub const DORMANT_DAYS: i64 = 90;
pub const FLAG_AFTER_FAILURES: i64 = 2;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Account {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub folder: String,
    #[serde(default)]
    pub access: AccessLevel,
    #[serde(default, rename = "gameName")]
    pub game_name: String,
    #[serde(default, rename = "tagLine")]
    pub tag_line: String,
    #[serde(default)]
    pub region: Region,

    #[serde(default, rename = "loginUsername")]
    pub login_username: String,
    /// AES-GCM sealed, base64. Never plaintext on disk.
    #[serde(default, rename = "encryptedPassword")]
    pub encrypted_password: Option<String>,

    #[serde(default)]
    pub ranks: Vec<RankEntry>,
    #[serde(default, rename = "lastGame")]
    pub last_game: Option<LastGame>,
    #[serde(default)]
    pub penalties: Vec<Penalty>,
    #[serde(default)]
    pub notes: String,

    #[serde(default, rename = "ownedChampions")]
    pub owned_champions: Vec<OwnedChampion>,
    #[serde(default, rename = "blueEssence")]
    pub blue_essence: Option<i64>,
    #[serde(default, rename = "riotPoints")]
    pub riot_points: Option<i64>,

    #[serde(default, rename = "honorLevel")]
    pub honor_level: Option<i64>,
    #[serde(default, rename = "recentGames")]
    pub recent_games: Option<i64>,
    #[serde(default, rename = "recentGamesAsOf")]
    pub recent_games_as_of: Option<DateTime<Utc>>,

    #[serde(default, rename = "cycleFailures")]
    pub cycle_failures: i64,
    #[serde(default, rename = "lastCycleFailure")]
    pub last_cycle_failure: String,
    #[serde(default, rename = "lastCycleFailureAt")]
    pub last_cycle_failure_at: Option<DateTime<Utc>>,

    #[serde(default)]
    pub puuid: Option<String>,
    #[serde(default, rename = "summonerLevel")]
    pub summoner_level: Option<i64>,
    #[serde(default, rename = "profileIconId")]
    pub profile_icon_id: Option<i64>,
    #[serde(default, rename = "lastRefreshed")]
    pub last_refreshed: Option<DateTime<Utc>>,
    #[serde(default = "Utc::now", rename = "createdAt")]
    pub created_at: DateTime<Utc>,
}

impl Default for Account {
    fn default() -> Self {
        Account {
            id: Uuid::new_v4(),
            label: String::new(),
            folder: String::new(),
            access: AccessLevel::Unknown,
            game_name: String::new(),
            tag_line: String::new(),
            region: Region::Na1,
            login_username: String::new(),
            encrypted_password: None,
            ranks: vec![RankEntry::new(RankedQueue::Solo), RankEntry::new(RankedQueue::Flex)],
            last_game: None,
            penalties: Vec::new(),
            notes: String::new(),
            owned_champions: Vec::new(),
            blue_essence: None,
            riot_points: None,
            honor_level: None,
            recent_games: None,
            recent_games_as_of: None,
            cycle_failures: 0,
            last_cycle_failure: String::new(),
            last_cycle_failure_at: None,
            puuid: None,
            summoner_level: None,
            profile_icon_id: None,
            last_refreshed: None,
            created_at: Utc::now(),
        }
    }
}

impl Account {
    pub fn new() -> Self {
        Account::default()
    }

    pub fn riot_id(&self) -> String {
        if self.tag_line.is_empty() {
            self.game_name.clone()
        } else {
            format!("{}#{}", self.game_name, self.tag_line)
        }
    }

    pub fn display_name(&self) -> String {
        if !self.label.is_empty() {
            return self.label.clone();
        }
        if !self.game_name.is_empty() {
            return self.riot_id();
        }
        if !self.login_username.is_empty() {
            return self.login_username.clone();
        }
        "Untitled account".to_string()
    }

    /// Added by hand with only a login: no Riot ID and no PUUID yet.
    pub fn is_unidentified(&self) -> bool {
        self.game_name.is_empty() && self.puuid.as_deref().unwrap_or("").is_empty()
    }

    pub fn ugg_url(&self) -> Option<String> {
        if self.game_name.is_empty() || self.tag_line.is_empty() {
            return None;
        }
        let slug = format!("{}-{}", self.game_name, self.tag_line);
        let encoded = url_path_encode(&slug);
        Some(format!(
            "https://u.gg/lol/profile/{}/{}/overview",
            self.region.raw(),
            encoded
        ))
    }

    pub fn solo_rank(&self) -> RankEntry {
        self.ranks
            .iter()
            .find(|r| r.queue == RankedQueue::Solo)
            .cloned()
            .unwrap_or_else(|| RankEntry::new(RankedQueue::Solo))
    }

    pub fn flex_rank(&self) -> RankEntry {
        self.ranks
            .iter()
            .find(|r| r.queue == RankedQueue::Flex)
            .cloned()
            .unwrap_or_else(|| RankEntry::new(RankedQueue::Flex))
    }

    pub fn owns_champion_matching(&self, query: &str) -> bool {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return false;
        }
        self.owned_champions
            .iter()
            .any(|c| c.name.to_lowercase().contains(&q))
    }

    pub fn active_penalties_at(&self, now: DateTime<Utc>) -> Vec<&Penalty> {
        self.penalties.iter().filter(|p| p.is_active_at(now)).collect()
    }

    pub fn worst_active_penalty_at(&self, now: DateTime<Utc>) -> Option<&Penalty> {
        self.active_penalties_at(now)
            .into_iter()
            .min_by_key(|p| p.kind.severity_rank())
    }

    pub fn has_critical_penalty_at(&self, now: DateTime<Utc>) -> bool {
        self.active_penalties_at(now).iter().any(|p| p.kind.is_critical())
    }

    /// Whole days since the last recorded game, or None when no game is on record.
    pub fn days_since_last_game_at(&self, now: DateTime<Utc>) -> Option<i64> {
        let played = self.last_game.as_ref()?.played_at;
        Some((now.date_naive() - played.date_naive()).num_days().max(0))
    }

    pub fn idle_label_at(&self, now: DateTime<Utc>) -> Option<String> {
        let days = self.days_since_last_game_at(now)?;
        Some(if days == 0 {
            "today".to_string()
        } else if days < 365 {
            format!("{}d idle", days)
        } else {
            format!("{:.1}y idle", days as f64 / 365.0)
        })
    }

    pub fn last_game_player(&self) -> LastGamePlayer {
        self.last_game.as_ref().map(|g| g.player).unwrap_or(LastGamePlayer::Unknown)
    }

    pub fn idle_is_self_inflicted(&self) -> bool {
        self.last_game_player() == LastGamePlayer::Me
    }

    pub fn is_dormant_at(&self, now: DateTime<Utc>) -> bool {
        self.days_since_last_game_at(now).unwrap_or(i64::MAX) >= DORMANT_DAYS
    }

    pub fn is_flagged(&self) -> bool {
        self.cycle_failures >= FLAG_AFTER_FAILURES
    }

    pub fn record_cycle_failure(&mut self, reason: &str) {
        self.cycle_failures += 1;
        self.last_cycle_failure = reason.to_string();
        self.last_cycle_failure_at = Some(Utc::now());
    }

    pub fn clear_cycle_failures(&mut self) {
        self.cycle_failures = 0;
        self.last_cycle_failure = String::new();
        self.last_cycle_failure_at = None;
    }

    /// Replaces any running dodge timer rather than stacking a second one.
    pub fn start_dodge_timer(&mut self, hours: i64) {
        let now = Utc::now();
        self.penalties
            .retain(|p| !(p.kind == PenaltyKind::DodgeTimer && p.is_active_at(now)));
        self.penalties.push(Penalty::dodge_timer(hours, ""));
    }

    /// Applies a last game read from the client, carrying the hand-entered
    /// "who played it" across while it is the same match.
    pub fn apply_live_last_game(&mut self, game: LastGame) {
        let mut merged = game;
        if let Some(existing) = &self.last_game {
            if !existing.match_id.is_empty() && existing.match_id == merged.match_id {
                merged.player = existing.player;
            }
        }
        self.last_game = Some(merged);
    }

    /// Applies a new Riot ID; the nickname follows only when it was mirroring the
    /// old game name.
    pub fn apply_riot_id(&mut self, new_name: &str, new_tag: &str) {
        let nickname_mirrored_old =
            self.label.is_empty() || self.label.eq_ignore_ascii_case(&self.game_name);
        if nickname_mirrored_old && !new_name.is_empty() {
            self.label = new_name.to_string();
        }
        self.game_name = new_name.to_string();
        self.tag_line = new_tag.to_string();
    }

    pub fn set_rank(&mut self, entry: RankEntry) {
        if let Some(idx) = self.ranks.iter().position(|r| r.queue == entry.queue) {
            self.ranks[idx] = entry;
        } else {
            self.ranks.push(entry);
        }
    }

    /// Applies a rank read from the client, preserving the hand-entered peak and
    /// raising it when the live rank is higher.
    pub fn apply_live_rank(&mut self, entry: RankEntry) {
        let idx = match self.ranks.iter().position(|r| r.queue == entry.queue) {
            Some(i) => i,
            None => {
                self.ranks.push(entry);
                return;
            }
        };
        let mut merged = entry.clone();
        merged.peak_tier = self.ranks[idx].peak_tier;
        merged.peak_division = self.ranks[idx].peak_division;
        merged.peak_note = self.ranks[idx].peak_note.clone();

        if RankEntry::ladder_position(entry.tier, entry.division)
            > RankEntry::ladder_position(merged.peak_tier, merged.peak_division)
        {
            merged.peak_tier = entry.tier;
            merged.peak_division = entry.division;
        }
        self.ranks[idx] = merged;
    }

    /// Replaces penalties the client reported, leaving hand-entered ones untouched.
    pub fn replace_client_penalties(&mut self, detected: Vec<Penalty>) {
        self.penalties.retain(|p| p.source != PenaltySource::Client);
        self.penalties.extend(detected);
    }

    /// Ensures both ranked queues exist and solo sorts first.
    pub fn normalize(&mut self) {
        for queue in [RankedQueue::Solo, RankedQueue::Flex] {
            if !self.ranks.iter().any(|r| r.queue == queue) {
                self.ranks.push(RankEntry::new(queue));
            }
        }
        self.ranks.sort_by_key(|r| if r.queue == RankedQueue::Solo { 0 } else { 1 });
    }
}

/// Percent-encodes for a URL path segment, matching Swift's `.urlPathAllowed`
/// closely enough for u.gg slugs (spaces become %20).
fn url_path_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric()
            || matches!(b, b'-' | b'_' | b'.' | b'~' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')'
                | b'*' | b'+' | b',' | b';' | b'=' | b':' | b'@');
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

/// Which day is "today" vs a date for idle maths (used only in Swift's wording).
pub fn years_since(days: i64) -> f64 {
    days as f64 / 365.0
}

#[allow(dead_code)]
fn _assert_datelike(d: DateTime<Utc>) -> i32 {
    d.year()
}
