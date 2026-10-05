//! Platform-independent core of League Vault (Windows port).
//!
//! Everything here is free of GUI and OS dependencies so it builds and tests on
//! any platform. The Tauri shell in `../app` and the Windows automation layer
//! build on top of it.

pub mod models;
pub mod store;
pub mod lcu;

pub use models::*;

#[cfg(test)]
mod tests {
    use super::models::*;
    use chrono::{Duration, TimeZone, Utc};

    #[test]
    fn account_json_roundtrips() {
        let mut a = Account::new();
        a.label = "Main".into();
        a.game_name = "Faker".into();
        a.tag_line = "KR1".into();
        a.region = Region::Kr;
        a.login_username = "faker_login".into();
        a.set_rank(RankEntry {
            queue: RankedQueue::Solo,
            tier: Tier::Challenger,
            division: Division::I,
            lp: 1200,
            wins: 400,
            losses: 100,
            peak_tier: Tier::Challenger,
            peak_division: Division::I,
            peak_note: "S14".into(),
        });
        a.normalize();

        let json = serde_json::to_string_pretty(&a).unwrap();
        let back: Account = serde_json::from_str(&json).unwrap();
        assert_eq!(a, back);
    }

    #[test]
    fn camel_case_keys_match_swift() {
        let a = Account::new();
        let v: serde_json::Value = serde_json::to_value(&a).unwrap();
        // These are the exact keys the macOS app writes.
        for key in ["loginUsername", "gameName", "tagLine", "createdAt", "ownedChampions"] {
            assert!(v.get(key).is_some(), "missing key {key}");
        }
        // Enum raw values are preserved.
        assert_eq!(v.get("region").unwrap(), "na1");
        assert_eq!(v.get("access").unwrap(), "UNKNOWN");
    }

    #[test]
    fn reads_a_mac_written_account() {
        // A trimmed accounts.json entry as the Swift app encodes it.
        let json = r#"{
            "id": "7B2D4E6F-0A1B-2C3D-4E5F-60718293A4B5",
            "label": "Smurf",
            "gameName": "Hide on bush",
            "tagLine": "KR1",
            "region": "kr",
            "access": "FA",
            "loginUsername": "hob",
            "ranks": [
              {"queue":"RANKED_SOLO_5x5","tier":"DIAMOND","division":"II","lp":44,"wins":30,"losses":20,
               "peakTier":"MASTER","peakDivision":"IV","peakNote":""}
            ],
            "penalties": [],
            "ownedChampions": [{"id":1,"name":"Annie"}],
            "createdAt": "2026-01-02T03:04:05Z"
        }"#;
        let a: Account = serde_json::from_str(json).unwrap();
        assert_eq!(a.game_name, "Hide on bush");
        assert_eq!(a.access, AccessLevel::FullAccess);
        assert_eq!(a.solo_rank().tier, Tier::Diamond);
        assert_eq!(a.solo_rank().peak_tier, Tier::Master);
        assert_eq!(a.owned_champions.len(), 1);
    }

    #[test]
    fn ladder_and_sort_weight() {
        // Challenger I outranks Diamond IV.
        let chall = RankEntry::ladder_position(Tier::Challenger, Division::I);
        let dia4 = RankEntry::ladder_position(Tier::Diamond, Division::Iv);
        assert!(chall > dia4);

        // Any live rank sorts above any unranked (even peak Challenger).
        let mut live = RankEntry::new(RankedQueue::Solo);
        live.tier = Tier::Iron;
        live.division = Division::Iv;
        let mut unranked = RankEntry::new(RankedQueue::Solo);
        unranked.peak_tier = Tier::Challenger;
        assert!(live.sort_weight() > unranked.sort_weight());

        // LP breaks ties within the same tier+division.
        let mut a = RankEntry::new(RankedQueue::Solo);
        a.tier = Tier::Gold;
        a.division = Division::Ii;
        a.lp = 10;
        let mut b = a.clone();
        b.lp = 90;
        assert!(b.sort_weight() > a.sort_weight());
    }

    #[test]
    fn penalty_active_window() {
        let now = Utc.with_ymd_and_hms(2026, 10, 5, 0, 0, 0).unwrap();
        let mut p = Penalty {
            id: uuid::Uuid::new_v4(),
            source: PenaltySource::Manual,
            kind: PenaltyKind::ChatRestriction,
            detail: String::new(),
            started_at: now - Duration::days(1),
            expires_at: Some(now + Duration::hours(2)),
            resolved: false,
        };
        assert!(p.is_active_at(now));
        p.expires_at = Some(now - Duration::hours(1));
        assert!(!p.is_active_at(now));
        // Permanent ban is always active.
        p.kind = PenaltyKind::PermanentBan;
        p.expires_at = None;
        assert!(p.is_active_at(now));
        // Resolved beats everything.
        p.resolved = true;
        assert!(!p.is_active_at(now));
    }

    #[test]
    fn idle_and_dormant() {
        let now = Utc.with_ymd_and_hms(2026, 10, 5, 12, 0, 0).unwrap();
        let mut a = Account::new();
        assert_eq!(a.days_since_last_game_at(now), None);
        let mut g = LastGame::default();
        g.played_at = now - Duration::days(100);
        a.last_game = Some(g);
        assert_eq!(a.days_since_last_game_at(now), Some(100));
        assert!(a.is_dormant_at(now));
        assert_eq!(a.idle_label_at(now), Some("100d idle".to_string()));
    }

    #[test]
    fn apply_live_rank_preserves_peak() {
        let mut a = Account::new();
        a.set_rank(RankEntry {
            queue: RankedQueue::Solo,
            tier: Tier::Gold,
            division: Division::I,
            lp: 50,
            wins: 0,
            losses: 0,
            peak_tier: Tier::Diamond,
            peak_division: Division::Iv,
            peak_note: "last split".into(),
        });
        // A live read with a lower rank must not lower the recorded peak.
        let mut live = RankEntry::new(RankedQueue::Solo);
        live.tier = Tier::Silver;
        live.division = Division::Ii;
        a.apply_live_rank(live);
        assert_eq!(a.solo_rank().tier, Tier::Silver);
        assert_eq!(a.solo_rank().peak_tier, Tier::Diamond);
        assert_eq!(a.solo_rank().peak_note, "last split");

        // A live read above the peak raises it.
        let mut higher = RankEntry::new(RankedQueue::Solo);
        higher.tier = Tier::Master;
        a.apply_live_rank(higher);
        assert_eq!(a.solo_rank().peak_tier, Tier::Master);
    }

    #[test]
    fn normalize_adds_both_queues_solo_first() {
        let mut a = Account { ranks: vec![RankEntry::new(RankedQueue::Flex)], ..Account::new() };
        a.normalize();
        assert_eq!(a.ranks.len(), 2);
        assert_eq!(a.ranks[0].queue, RankedQueue::Solo);
    }

    #[test]
    fn apply_riot_id_follows_mirrored_nickname() {
        let mut a = Account::new();
        a.game_name = "OldName".into();
        a.label = "oldname".into(); // mirrored (case-insensitive)
        a.apply_riot_id("NewName", "NA1");
        assert_eq!(a.label, "NewName");

        let mut b = Account::new();
        b.game_name = "OldName".into();
        b.label = "Main".into(); // a chosen nickname is left alone
        b.apply_riot_id("NewName", "NA1");
        assert_eq!(b.label, "Main");
    }
}
