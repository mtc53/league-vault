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

    var champion: String = ""
    var queue: String = ""
    var result: Result = .victory
    var kills: Int = 0
    var deaths: Int = 0
    var assists: Int = 0
    var durationSeconds: Int = 0
    var playedAt: Date = Date()
    var matchId: String = ""

    init(champion: String = "", queue: String = "", result: Result = .victory,
         kills: Int = 0, deaths: Int = 0, assists: Int = 0,
         durationSeconds: Int = 0, playedAt: Date = Date(), matchId: String = "") {
        self.champion = champion; self.queue = queue; self.result = result
        self.kills = kills; self.deaths = deaths; self.assists = assists
        self.durationSeconds = durationSeconds; self.playedAt = playedAt; self.matchId = matchId
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
        case .queueDelay, .lowPriorityQueue, .suspension, .permanentBan: return true
        default: return false
        }
    }

    /// Queue delay leads the list — it is the one that costs you time every game.
    var severityRank: Int {
        switch self {
        case .queueDelay:        return 0
        case .suspension,
             .permanentBan:      return 1
        case .lowPriorityQueue:  return 2
        case .rankedRestriction: return 3
        case .chatRestriction,
             .voiceMuted:        return 4
        case .honorDowngrade:    return 5
        case .honorLock,
             .other:             return 6
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
        let hours = Calendar.current.dateComponents([.hour], from: Date(), to: expiresAt).hour ?? 0
        return "Active — \(max(hours, 1)) hour\(hours == 1 ? "" : "s") left"
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
    static let defaultIconId = 6923

    private enum Keys {
        static let icon = "prepIconId"
        static let setIcon = "prepSetIcon"
        static let clearChallenges = "prepClearChallenges"
        static let removeFriends = "prepRemoveFriends"
    }

    static var iconId: Int {
        get { UserDefaults.standard.object(forKey: Keys.icon) as? Int ?? defaultIconId }
        set { UserDefaults.standard.set(newValue, forKey: Keys.icon) }
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
        return "Untitled account"
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

    var activeQueueDelays: [Penalty] {
        activePenalties.filter { $0.kind == .queueDelay }
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

    mutating func setRank(_ entry: RankEntry) {
        if let idx = ranks.firstIndex(where: { $0.queue == entry.queue }) {
            ranks[idx] = entry
        } else {
            ranks.append(entry)
        }
    }

    mutating func normalize() {
        for queue in RankedQueue.allCases where !ranks.contains(where: { $0.queue == queue }) {
            ranks.append(RankEntry(queue: queue))
        }
        ranks.sort { $0.queue == .solo && $1.queue != .solo }
    }
}
