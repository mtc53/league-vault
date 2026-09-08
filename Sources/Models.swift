import Foundation

// MARK: - Region

enum Region: String, Codable, CaseIterable, Identifiable {
    case na1, br1, la1, la2, euw1, eun1, tr1, ru, me1, kr, jp1, oc1, ph2, sg2, th2, tw2, vn2

    var id: String { rawValue }

    var display: String {
        switch self {
        case .na1: return "NA"
        case .br1: return "BR"
        case .la1: return "LAN"
        case .la2: return "LAS"
        case .euw1: return "EUW"
        case .eun1: return "EUNE"
        case .tr1: return "TR"
        case .ru:  return "RU"
        case .me1: return "ME"
        case .kr:  return "KR"
        case .jp1: return "JP"
        case .oc1: return "OCE"
        case .ph2: return "PH"
        case .sg2: return "SG"
        case .th2: return "TH"
        case .tw2: return "TW"
        case .vn2: return "VN"
        }
    }

    var longName: String {
        switch self {
        case .na1: return "North America"
        case .br1: return "Brazil"
        case .la1: return "Latin America North"
        case .la2: return "Latin America South"
        case .euw1: return "Europe West"
        case .eun1: return "Europe Nordic & East"
        case .tr1: return "Türkiye"
        case .ru:  return "Russia"
        case .me1: return "Middle East"
        case .kr:  return "Korea"
        case .jp1: return "Japan"
        case .oc1: return "Oceania"
        case .ph2: return "Philippines"
        case .sg2: return "Singapore"
        case .th2: return "Thailand"
        case .tw2: return "Taiwan"
        case .vn2: return "Vietnam"
        }
    }

}

// MARK: - Rank

enum Tier: String, Codable, CaseIterable, Identifiable {
    case unranked = "UNRANKED"
    case iron = "IRON"
    case bronze = "BRONZE"
    case silver = "SILVER"
    case gold = "GOLD"
    case platinum = "PLATINUM"
    case emerald = "EMERALD"
    case diamond = "DIAMOND"
    case master = "MASTER"
    case grandmaster = "GRANDMASTER"
    case challenger = "CHALLENGER"

    var id: String { rawValue }

    var display: String {
        rawValue.prefix(1) + rawValue.dropFirst().lowercased()
    }

    /// Master and above have no divisions.
    var isApex: Bool { self == .master || self == .grandmaster || self == .challenger }

    static func from(_ raw: String?) -> Tier {
        guard let raw else { return .unranked }
        return Tier(rawValue: raw.uppercased()) ?? .unranked
    }
}

enum Division: String, Codable, CaseIterable, Identifiable {
    case i = "I", ii = "II", iii = "III", iv = "IV"
    var id: String { rawValue }
}

enum RankedQueue: String, Codable, CaseIterable, Identifiable {
    case solo = "RANKED_SOLO_5x5"
    case flex = "RANKED_FLEX_SR"

    var id: String { rawValue }
    var display: String { self == .solo ? "Solo/Duo" : "Flex" }
}

struct RankEntry: Codable, Hashable, Identifiable {
    var queue: RankedQueue
    var tier: Tier = .unranked
    var division: Division = .iv
    var lp: Int = 0
    var wins: Int = 0
    var losses: Int = 0
    /// Highest rank ever reached, entered by hand. Riot exposes no peak-rank endpoint.
    var peakTier: Tier = .unranked
    var peakDivision: Division = .iv
    /// Free text for when it was reached, e.g. "S13 split 2".
    var peakNote: String = ""

    var id: String { queue.rawValue }

    init(queue: RankedQueue, tier: Tier = .unranked, division: Division = .iv,
         lp: Int = 0, wins: Int = 0, losses: Int = 0,
         peakTier: Tier = .unranked, peakDivision: Division = .iv, peakNote: String = "") {
        self.queue = queue; self.tier = tier; self.division = division
        self.lp = lp; self.wins = wins; self.losses = losses
        self.peakTier = peakTier; self.peakDivision = peakDivision; self.peakNote = peakNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queue = (try? c.decode(RankedQueue.self, forKey: .queue)) ?? .solo
        tier = (try? c.decodeIfPresent(Tier.self, forKey: .tier)) .flatMap { $0 } ?? .unranked
        division = (try? c.decodeIfPresent(Division.self, forKey: .division)).flatMap { $0 } ?? .iv
        lp = (try? c.decodeIfPresent(Int.self, forKey: .lp)).flatMap { $0 } ?? 0
        wins = (try? c.decodeIfPresent(Int.self, forKey: .wins)).flatMap { $0 } ?? 0
        losses = (try? c.decodeIfPresent(Int.self, forKey: .losses)).flatMap { $0 } ?? 0
        peakTier = (try? c.decodeIfPresent(Tier.self, forKey: .peakTier)).flatMap { $0 } ?? .unranked
        peakDivision = (try? c.decodeIfPresent(Division.self, forKey: .peakDivision)).flatMap { $0 } ?? .iv
        peakNote = (try? c.decodeIfPresent(String.self, forKey: .peakNote)).flatMap { $0 } ?? ""
    }

    var games: Int { wins + losses }
    var winrate: Double { games == 0 ? 0 : Double(wins) / Double(games) * 100 }

    var shortDisplay: String {
        guard tier != .unranked else { return "Unranked" }
        return tier.isApex
            ? "\(tier.display) \(lp) LP"
            : "\(tier.display) \(division.rawValue) · \(lp) LP"
    }

    var hasPeak: Bool { peakTier != .unranked }

    /// Orders tier+division on the ladder. Apex tiers have no divisions, so they sit at
    /// the top of their tier.
    static func ladderPosition(tier: Tier, division: Division) -> Int {
        guard tier != .unranked else { return 0 }
        let tierIndex = Tier.allCases.firstIndex(of: tier) ?? 0
        let divisionIndex = tier.isApex ? 4 : (4 - (Division.allCases.firstIndex(of: division) ?? 0))
        return tierIndex * 10 + divisionIndex
    }

    /// Orders accounts in a list: ladder position with LP as the tiebreak. An unranked
    /// account is placed by its peak, always beneath anyone currently ranked — the highest
    /// possible peak scores 1,000 against a floor of 11,000 for the lowest live rank.
    var sortWeight: Int {
        guard tier != .unranked else {
            return (Tier.allCases.firstIndex(of: peakTier) ?? 0) * 100
        }
        return RankEntry.ladderPosition(tier: tier, division: division) * 1_000 + lp
    }

    /// "Gold II", or just "Master" for apex tiers. nil when no peak was entered.
    var peakDisplay: String? {
        guard hasPeak else { return nil }
        return peakTier.isApex ? peakTier.display : "\(peakTier.display) \(peakDivision.rawValue)"
    }

    /// The rank worth showing when the account is currently unranked.
    var displayWithFallback: String {
        if tier != .unranked { return shortDisplay }
        if let peak = peakDisplay { return "Unranked · peak \(peak)" }
        return "Unranked"
    }

    /// Colour to tint by: the live tier, or the peak when unranked.
    var effectiveTier: Tier { tier == .unranked ? peakTier : tier }
}

// MARK: - Queues

enum LoLQueues {
    static let names: [Int: String] = [
        400: "Normal Draft", 420: "Ranked Solo/Duo", 430: "Normal Blind",
        440: "Ranked Flex", 450: "ARAM", 490: "Quickplay",
        700: "Clash", 720: "ARAM Clash",
        830: "Co-op vs AI (Intro)", 840: "Co-op vs AI (Beginner)", 850: "Co-op vs AI (Intermediate)",
        870: "Co-op vs AI (Intro)", 880: "Co-op vs AI (Beginner)", 890: "Co-op vs AI (Intermediate)",
        900: "ARURF", 1020: "One for All", 1300: "Nexus Blitz",
        1400: "Ultimate Spellbook", 1700: "Arena", 1710: "Arena", 1900: "URF",
        2000: "Tutorial", 2010: "Tutorial", 2020: "Tutorial"
    ]

    static func name(for id: Int?, fallback: String? = nil) -> String {
        if let id, let known = names[id] { return known }
        if let fallback, !fallback.isEmpty { return fallback.capitalized }
        if let id { return "Queue \(id)" }
        return "Custom"
    }
}

// MARK: - Last game

struct LastGame: Codable, Hashable {
    enum Result: String, Codable, CaseIterable, Identifiable {
        case victory = "Victory"
        case defeat = "Defeat"
        case remake = "Remake"
        var id: String { rawValue }
    }

    /// Who actually played the last game. Nothing in the client can tell you this —
    /// a game you played yourself and a game someone else played look identical — so
    /// it is recorded by hand. It changes what the idle counter means: an account you
    /// played yesterday is not "in use", it is just an account you used.
    enum Player: String, Codable, CaseIterable, Identifiable {
        case unknown = "UNKNOWN"
        case me = "ME"
        case someoneElse = "SOMEONE_ELSE"

        var id: String { rawValue }

        var display: String {
            switch self {
            case .unknown:     return "Not said"
            case .me:          return "Me"
            case .someoneElse: return "Someone else"
            }
        }

        var symbol: String {
            switch self {
            case .unknown:     return "questionmark.circle"
            case .me:          return "person.fill"
            case .someoneElse: return "person.2.fill"
            }
        }
    }

    var champion: String = ""
    var queue: String = ""
    var result: Result = .victory
    var kills: Int = 0
    var deaths: Int = 0
    var assists: Int = 0
    var durationSeconds: Int = 0
    var playedAt: Date = Date()
    var matchId: String = ""
    /// Recorded by hand; carried across refreshes for as long as it is the same match.
    var player: Player = .unknown

    init(champion: String = "", queue: String = "", result: Result = .victory,
         kills: Int = 0, deaths: Int = 0, assists: Int = 0,
         durationSeconds: Int = 0, playedAt: Date = Date(), matchId: String = "",
         player: Player = .unknown) {
        self.champion = champion; self.queue = queue; self.result = result
        self.kills = kills; self.deaths = deaths; self.assists = assists
        self.durationSeconds = durationSeconds; self.playedAt = playedAt; self.matchId = matchId
        self.player = player
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        champion = (try? c.decodeIfPresent(String.self, forKey: .champion)).flatMap { $0 } ?? ""
        queue = (try? c.decodeIfPresent(String.self, forKey: .queue)).flatMap { $0 } ?? ""
        result = (try? c.decodeIfPresent(Result.self, forKey: .result)).flatMap { $0 } ?? .victory
        kills = (try? c.decodeIfPresent(Int.self, forKey: .kills)).flatMap { $0 } ?? 0
        deaths = (try? c.decodeIfPresent(Int.self, forKey: .deaths)).flatMap { $0 } ?? 0
        assists = (try? c.decodeIfPresent(Int.self, forKey: .assists)).flatMap { $0 } ?? 0
        durationSeconds = (try? c.decodeIfPresent(Int.self, forKey: .durationSeconds)).flatMap { $0 } ?? 0
        playedAt = (try? c.decodeIfPresent(Date.self, forKey: .playedAt)).flatMap { $0 } ?? Date()
        matchId = (try? c.decodeIfPresent(String.self, forKey: .matchId)).flatMap { $0 } ?? ""
        player = (try? c.decodeIfPresent(Player.self, forKey: .player)).flatMap { $0 } ?? .unknown
    }

    var kda: String { "\(kills)/\(deaths)/\(assists)" }

    var kdaRatio: Double {
        deaths == 0 ? Double(kills + assists) : Double(kills + assists) / Double(deaths)
    }

    var durationDisplay: String {
        guard durationSeconds > 0 else { return "—" }
        return String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

// MARK: - Penalties

enum PenaltyKind: String, Codable, CaseIterable, Identifiable {
    case chatRestriction = "Chat restriction"
    case voiceMuted = "Team voice muted"
    case rankedRestriction = "Ranked restriction"
    case lowPriorityQueue = "Low priority queue"
    case queueDelay = "Queue delay"
    case dodgeTimer = "Dodge timer"
    case honorDowngrade = "Honor downgrade"
    case suspension = "Temporary suspension"
    case permanentBan = "Permanent ban"
    case honorLock = "Honor level lock"
    case other = "Other"

    var id: String { rawValue }

    /// Offered in the editor. Honor downgrade is excluded: honor is shown as a level on
    /// the account, not as a penalty. The case remains so older files still decode.
    static var selectable: [PenaltyKind] {
        allCases.filter { $0 != .honorDowngrade }
    }

    var symbol: String {
        switch self {
        case .chatRestriction:   return "bubble.left.and.exclamationmark.bubble.right"
        case .rankedRestriction: return "trophy.slash"
        case .voiceMuted:        return "mic.slash"
        case .lowPriorityQueue:  return "clock.badge.exclamationmark"
        case .queueDelay:        return "hourglass"
        case .dodgeTimer:        return "arrow.uturn.backward.circle.fill"
        case .honorDowngrade:    return "arrow.down.heart"
        case .suspension:        return "nosign"
        case .permanentBan:      return "xmark.octagon"
        case .honorLock:         return "lock.shield"
        case .other:             return "exclamationmark.triangle"
        }
    }

    /// Permanent penalties never expire.
    var isPermanentByNature: Bool { self == .permanentBan }

    /// Penalties that stop you playing normally right now, rather than ones you are
    /// merely working off. These get red treatment instead of amber.
    var isCritical: Bool {
        switch self {
        case .queueDelay, .dodgeTimer, .lowPriorityQueue, .suspension, .permanentBan: return true
        default: return false
        }
    }

    /// Queue delay leads the list — it is the one that costs you time every game.
    var severityRank: Int {
        switch self {
        case .queueDelay:        return 0
        case .dodgeTimer:        return 1
        case .suspension,
             .permanentBan:      return 2
        case .lowPriorityQueue:  return 3
        case .rankedRestriction: return 4
        case .chatRestriction,
             .voiceMuted:        return 5
        case .honorDowngrade:    return 6
        case .honorLock,
             .other:             return 7
        }
    }
}

/// Where a penalty record came from.
enum PenaltySource: String, Codable {
    case manual
    case client
}

struct Penalty: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var source: PenaltySource = .manual
    var kind: PenaltyKind = .chatRestriction
    /// Free text, e.g. "10 games" or "reason: verbal abuse".
    var detail: String = ""
    var startedAt: Date = Date()
    /// nil means permanent or unknown end date.
    var expiresAt: Date?
    var resolved: Bool = false

    init(id: UUID = UUID(), source: PenaltySource = .manual, kind: PenaltyKind = .chatRestriction,
         detail: String = "", startedAt: Date = Date(), expiresAt: Date? = nil, resolved: Bool = false) {
        self.id = id; self.source = source; self.kind = kind; self.detail = detail
        self.startedAt = startedAt; self.expiresAt = expiresAt; self.resolved = resolved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        source = (try? c.decodeIfPresent(PenaltySource.self, forKey: .source)).flatMap { $0 } ?? .manual
        kind = (try? c.decodeIfPresent(PenaltyKind.self, forKey: .kind)).flatMap { $0 } ?? .other
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)).flatMap { $0 } ?? ""
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)).flatMap { $0 } ?? Date()
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        resolved = (try? c.decodeIfPresent(Bool.self, forKey: .resolved)).flatMap { $0 } ?? false
    }

    var isActive: Bool {
        if resolved { return false }
        if kind.isPermanentByNature { return true }
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }

    var statusDisplay: String {
        if resolved { return "Served" }
        if kind.isPermanentByNature { return "Permanent" }
        guard let expiresAt else { return "Active — no end date" }
        if expiresAt <= Date() { return "Expired" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        if days >= 1 { return "Active — \(days) day\(days == 1 ? "" : "s") left" }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date(), to: expiresAt)
        let hours = parts.hour ?? 0, minutes = parts.minute ?? 0
        if hours >= 1 {
            return "Active — \(hours)h \(minutes)m left"
        }
        let shown = max(minutes, 1)
        return "Active — \(shown) minute\(shown == 1 ? "" : "s") left"
    }
}

// MARK: - Champions & wallet

struct OwnedChampion: Codable, Hashable, Identifiable, Comparable {
    var id: Int
    var name: String

    static func < (a: OwnedChampion, b: OwnedChampion) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

// MARK: - Quick prep

enum QuickPrep {
    /// The dark-elf icon with the red tear streaks, found by matching the catalogue.
    static let preferredIconId = 6923
    /// Every account owns this one, so it is what an unowned preference falls back to.
    /// Riot resets an unowned icon server-side, which makes the fallback worth having.
    static let fallbackIconId = 29

    static let defaultIconId = preferredIconId

    /// The only two icons quick prep will set.
    static var choices: [Int] { [preferredIconId, fallbackIconId] }

    private enum Keys {
        static let icon = "prepIconId"
        static let setIcon = "prepSetIcon"
        static let clearChallenges = "prepClearChallenges"
        static let removeFriends = "prepRemoveFriends"
    }

    static var iconId: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: Keys.icon) as? Int ?? preferredIconId
            // Anything else that was saved earlier collapses back to the two choices.
            return choices.contains(stored) ? stored : preferredIconId
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.icon) }
    }

    /// Which icon to actually set, given what the account owns.
    static func resolvedIcon(preferring wanted: Int, ownedIcons: Set<Int>) -> (id: Int, fellBack: Bool) {
        // An empty set means the inventory could not be read — do not second-guess it.
        guard !ownedIcons.isEmpty else { return (wanted, false) }
        if ownedIcons.contains(wanted) { return (wanted, false) }
        // Falling back to the same id is not a fallback worth reporting.
        return (fallbackIconId, fallbackIconId != wanted)
    }
    static var setsIcon: Bool {
        get { UserDefaults.standard.object(forKey: Keys.setIcon) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.setIcon) }
    }
    static var clearsChallenges: Bool {
        get { UserDefaults.standard.object(forKey: Keys.clearChallenges) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.clearChallenges) }
    }
    /// Off by default: removing friends cannot be undone.
    static var removesFriends: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.removeFriends) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.removeFriends) }
    }
}

// MARK: - Access level

/// Whether the original registration email came with the account.
enum AccessLevel: String, Codable, CaseIterable, Identifiable {
    case unknown = "UNKNOWN"
    case fullAccess = "FA"
    case notFullAccess = "NFA"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .unknown: return "—"
        case .fullAccess: return "FA"
        case .notFullAccess: return "NFA"
        }
    }

    var display: String {
        switch self {
        case .unknown: return "Not recorded"
        case .fullAccess: return "FA — full access"
        case .notFullAccess: return "NFA — no email access"
        }
    }

    var explanation: String {
        switch self {
        case .unknown: return "You have not recorded whether the original email came with this account."
        case .fullAccess: return "You control the registration email, so the account can be recovered and the email changed."
        case .notFullAccess: return "The registration email belongs to someone else — the account can be recalled and cannot be fully secured."
        }
    }
}

// MARK: - Account

struct Account: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Nickname you give the account, e.g. "Main" or "Support smurf".
    var label: String = ""
    /// Folder this account is filed under. Empty means unfiled.
    var folder: String = ""
    /// Full access (you hold the registration email) or not.
    var access: AccessLevel = .unknown
    var gameName: String = ""
    var tagLine: String = ""
    var region: Region = .na1

    var loginUsername: String = ""
    /// AES-GCM sealed, base64. Never plaintext on disk.
    var encryptedPassword: String?

    var ranks: [RankEntry] = [RankEntry(queue: .solo), RankEntry(queue: .flex)]
    var lastGame: LastGame?
    var penalties: [Penalty] = []
    var notes: String = ""

    var ownedChampions: [OwnedChampion] = []
    /// Blue essence and RP, as reported by the client's wallet.
    var blueEssence: Int?
    var riotPoints: Int?

    var honorLevel: Int?
    /// Games played in the last `recentWindowDays`, counted at the last refresh.
    var recentGames: Int?
    var recentGamesAsOf: Date?

    static let recentWindowDays = 90

    var puuid: String?
    var summonerLevel: Int?
    /// Summoner (profile) icon id from Riot, rendered from Data Dragon.
    var profileIconId: Int?
    var lastRefreshed: Date?
    var createdAt: Date = Date()

    init() {}

    /// Every field is optional on read. A file written by an older (or newer) build
    /// still loads; anything absent falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 } ?? ""
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)).flatMap { $0 } ?? ""
        access = (try? c.decodeIfPresent(AccessLevel.self, forKey: .access)).flatMap { $0 } ?? .unknown
        gameName = (try? c.decodeIfPresent(String.self, forKey: .gameName)).flatMap { $0 } ?? ""
        tagLine = (try? c.decodeIfPresent(String.self, forKey: .tagLine)).flatMap { $0 } ?? ""
        region = (try? c.decodeIfPresent(Region.self, forKey: .region)).flatMap { $0 } ?? .na1
        loginUsername = (try? c.decodeIfPresent(String.self, forKey: .loginUsername)).flatMap { $0 } ?? ""
        encryptedPassword = try? c.decodeIfPresent(String.self, forKey: .encryptedPassword)
        ranks = (try? c.decodeIfPresent([RankEntry].self, forKey: .ranks)).flatMap { $0 } ?? []
        lastGame = try? c.decodeIfPresent(LastGame.self, forKey: .lastGame)
        penalties = (try? c.decodeIfPresent([Penalty].self, forKey: .penalties)).flatMap { $0 } ?? []
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)).flatMap { $0 } ?? ""
        ownedChampions = (try? c.decodeIfPresent([OwnedChampion].self, forKey: .ownedChampions)).flatMap { $0 } ?? []
        blueEssence = try? c.decodeIfPresent(Int.self, forKey: .blueEssence)
        honorLevel = try? c.decodeIfPresent(Int.self, forKey: .honorLevel)
        recentGames = try? c.decodeIfPresent(Int.self, forKey: .recentGames)
        recentGamesAsOf = try? c.decodeIfPresent(Date.self, forKey: .recentGamesAsOf)
        riotPoints = try? c.decodeIfPresent(Int.self, forKey: .riotPoints)
        puuid = try? c.decodeIfPresent(String.self, forKey: .puuid)
        summonerLevel = try? c.decodeIfPresent(Int.self, forKey: .summonerLevel)
        profileIconId = try? c.decodeIfPresent(Int.self, forKey: .profileIconId)
        lastRefreshed = try? c.decodeIfPresent(Date.self, forKey: .lastRefreshed)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)).flatMap { $0 } ?? Date()
    }

    var riotID: String {
        tagLine.isEmpty ? gameName : "\(gameName)#\(tagLine)"
    }

    var displayName: String {
        if !label.isEmpty { return label }
        if !gameName.isEmpty { return riotID }
        if !loginUsername.isEmpty { return loginUsername }
        return "Untitled account"
    }

    /// Added by hand with only a login: no Riot ID and no PUUID yet, so it takes its
    /// identity from whichever account is signed in the first time it is refreshed.
    var isUnidentified: Bool {
        gameName.isEmpty && (puuid ?? "").isEmpty
    }

    /// u.gg profile page for this account, e.g. u.gg/lol/profile/na1/Name-TAG/overview
    var uggURL: URL? {
        guard !gameName.isEmpty, !tagLine.isEmpty else { return nil }
        let slug = "\(gameName)-\(tagLine)"
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://u.gg/lol/profile/\(region.rawValue)/\(encoded)/overview")
    }

    var soloRank: RankEntry {
        ranks.first(where: { $0.queue == .solo }) ?? RankEntry(queue: .solo)
    }

    var flexRank: RankEntry {
        ranks.first(where: { $0.queue == .flex }) ?? RankEntry(queue: .flex)
    }

    /// "fa" and "nfa" are matched as whole words so they do not collide with names.
    func matchesAccessToken(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q == "FA" || q == "NFA" else { return false }
        return access.rawValue == q
    }

    func owns(championMatching query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        return ownedChampions.contains { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var activePenalties: [Penalty] { penalties.filter(\.isActive) }

    /// The most serious active penalty, for badges and banners.
    var worstActivePenalty: Penalty? {
        activePenalties.min { $0.kind.severityRank < $1.kind.severityRank }
    }

    var hasCriticalPenalty: Bool { activePenalties.contains { $0.kind.isCritical } }

    /// "12 games" / "no games" over the tracked window, or nil when never counted.
    /// Kept as detail; the headline number is now how long the account has sat idle.
    var recentGamesLabel: String? {
        guard let recentGames else { return nil }
        return recentGames == 0 ? "no games in 3mo" : "\(recentGames) in 3mo"
    }

    /// Whole days since the last recorded game, or nil when no game is on record.
    var daysSinceLastGame: Int? {
        guard let played = lastGame?.playedAt else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: played, to: Date()).day ?? 0)
    }

    /// Short badge text: "today", "1d idle", "57d idle", "2.1y idle".
    var idleLabel: String? {
        guard let days = daysSinceLastGame else { return nil }
        if days == 0 { return "today" }
        if days < 365 { return "\(days)d idle" }
        return String(format: "%.1fy idle", Double(days) / 365)
    }

    /// The long form, for tooltips and the detail pane.
    var idleDescription: String? {
        guard let days = daysSinceLastGame else { return nil }
        switch days {
        case 0:  return "Last game was today"
        case 1:  return "Last game was yesterday"
        default: return "Last game was \(days) days ago"
        }
    }

    /// Who played it last. Drives whether the idle counter means anything: a game you
    /// played yourself says nothing about whether anyone else is on the account.
    var lastGamePlayer: LastGame.Player { lastGame?.player ?? .unknown }

    /// You played it, so the idle counter is only a note to yourself.
    var idleIsSelfInflicted: Bool { lastGamePlayer == .me }

    /// Untouched for three months by anyone. Still worth flagging separately.
    static let dormantDays = 90
    var isDormant: Bool { (daysSinceLastGame ?? Int.max) >= Account.dormantDays }

    var activeQueueDelays: [Penalty] {
        activePenalties.filter { $0.kind == .queueDelay }
    }

    var activeDodgeTimer: Penalty? {
        activePenalties.first { $0.kind == .dodgeTimer }
    }

    /// A dodge timer is a fixed 24-hour wait, recorded by hand — nothing in the client
    /// reports it, so it is entered when it happens and expires on its own.
    static func dodgeTimer(hours: Int = 24, note: String = "") -> Penalty {
        Penalty(source: .manual,
                kind: .dodgeTimer,
                detail: note.isEmpty ? "\(hours)-hour dodge timer" : note,
                startedAt: Date(),
                expiresAt: Date().addingTimeInterval(Double(hours) * 3600))
    }

    /// Replaces any running dodge timer rather than stacking a second one.
    mutating func startDodgeTimer(hours: Int = 24) {
        penalties.removeAll { $0.kind == .dodgeTimer && $0.isActive }
        penalties.append(Account.dodgeTimer(hours: hours))
    }

    /// Applies a last game read from the client. Who played it is recorded by hand and
    /// the client cannot know it, so the note is carried across for as long as it is
    /// still the same match — a genuinely new game starts out unattributed again.
    mutating func applyLiveLastGame(_ game: LastGame) {
        var merged = game
        if let existing = lastGame,
           !existing.matchId.isEmpty,
           existing.matchId == game.matchId {
            merged.player = existing.player
        }
        lastGame = merged
    }

    /// Folds a snapshot read from the client into this account: identity, rank (peak
    /// preserved), last game (attribution preserved), champions, wallet, honor and the
    /// client-reported penalties. Hand-entered penalties and peaks are left alone.
    mutating func applySnapshot(_ snapshot: LCU.Snapshot) {
        let me = snapshot.summoner
        puuid = me.puuid
        applyRiotID(gameName: me.gameName, tagLine: me.tagLine)
        summonerLevel = me.summonerLevel
        if let icon = me.profileIconId { profileIconId = icon }
        if let region = snapshot.region { self.region = region }
        for entry in snapshot.ranks { applyLiveRank(entry) }
        if let game = snapshot.lastGame { applyLiveLastGame(game) }
        if !snapshot.champions.isEmpty { ownedChampions = snapshot.champions }
        if let be = snapshot.blueEssence { blueEssence = be }
        if let rp = snapshot.riotPoints { riotPoints = rp }
        if let count = snapshot.recentGames {
            recentGames = count
            recentGamesAsOf = Date()
        }
        if let honor = snapshot.honor {
            honorLevel = honor.level
            replaceClientPenalties(with: LCU.penalties(from: snapshot.behaviour ?? LCU.BehaviourSnapshot(honor: honor)))
        }
        lastRefreshed = Date()
    }

    /// Replaces penalties the client reported, leaving hand-entered ones untouched.
    mutating func replaceClientPenalties(with detected: [Penalty]) {
        penalties.removeAll { $0.source == .client }
        penalties.append(contentsOf: detected)
    }
    var hasActivePenalty: Bool { !activePenalties.isEmpty }

    /// Applies a new Riot ID. The nickname follows along when it was just mirroring the
    /// old game name (which is what an import sets it to); a nickname you actually chose
    /// — "Main", "Support smurf" — is left alone.
    mutating func applyRiotID(gameName newName: String, tagLine newTag: String) {
        let nicknameMirroredOldName =
            label.isEmpty || label.compare(gameName, options: .caseInsensitive) == .orderedSame
        if nicknameMirroredOldName && !newName.isEmpty {
            label = newName
        }
        gameName = newName
        tagLine = newTag
    }

    /// Replaces a rank wholesale, peak included. Used by the editor, where the peak is
    /// being edited on purpose.
    mutating func setRank(_ entry: RankEntry) {
        if let idx = ranks.firstIndex(where: { $0.queue == entry.queue }) {
            ranks[idx] = entry
        } else {
            ranks.append(entry)
        }
    }

    /// Applies a rank read from the client. The client knows nothing about peak rank —
    /// it is recorded by hand — so the stored peak is carried across rather than being
    /// overwritten with a blank one. If the live rank is above the recorded peak, the
    /// peak is raised to match, since it plainly is the new peak.
    mutating func applyLiveRank(_ entry: RankEntry) {
        guard let idx = ranks.firstIndex(where: { $0.queue == entry.queue }) else {
            ranks.append(entry)
            return
        }
        var merged = entry
        merged.peakTier = ranks[idx].peakTier
        merged.peakDivision = ranks[idx].peakDivision
        merged.peakNote = ranks[idx].peakNote

        if RankEntry.ladderPosition(tier: entry.tier, division: entry.division)
            > RankEntry.ladderPosition(tier: merged.peakTier, division: merged.peakDivision) {
            merged.peakTier = entry.tier
            merged.peakDivision = entry.division
        }
        ranks[idx] = merged
    }

    mutating func normalize() {
        for queue in RankedQueue.allCases where !ranks.contains(where: { $0.queue == queue }) {
            ranks.append(RankEntry(queue: queue))
        }
        ranks.sort { $0.queue == .solo && $1.queue != .solo }
    }
}
