import Foundation

// The League Client (LCU) API: the client runs a local HTTPS server on 127.0.0.1 and
// puts its port and auth token in its own command line. Anything the client itself can
// do, a local tool can do over that socket — including writes the public Riot Developer
// API does not expose. Undocumented and unsupported by Riot; endpoints can change on any
// patch, so every call here degrades gracefully.

struct LCUCredentials {
    let port: Int
    let token: String

    var baseURL: String { "https://127.0.0.1:\(port)" }

    var authorizationHeader: String {
        "Basic " + Data("riot:\(token)".utf8).base64EncodedString()
    }
}

struct LCUError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Summoner currently signed in to the running client.
struct LCUSummoner {
    var gameName: String
    var tagLine: String
    var puuid: String
    var summonerId: Int64?
    var summonerLevel: Int?
    var profileIconId: Int?

    var riotID: String { tagLine.isEmpty ? gameName : "\(gameName)#\(tagLine)" }
}

/// Accepts the client's self-signed certificate, and only ever for loopback.
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum LCU {
    private static let delegate = LoopbackTrustDelegate()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: Discovery

    /// Reads the running client's own command line for its port and auth token.
    /// Only this user's processes are visible to `ps`, and the token dies with the client.
    /// `processList` is an injection seam for tests; production passes nil and reads `ps`.
    static func discover(processList: String? = nil) -> LCUCredentials? {
        guard let output = processList ?? runPS() else { return nil }

        for line in output.split(separator: "\n") where line.contains("LeagueClientUx") {
            let text = String(line)
            guard let port = capture(#"--app-port=(\d+)"#, in: text),
                  let portNumber = Int(port),
                  let token = capture(#"--remoting-auth-token=([\w-]+)"#, in: text) else { continue }
            return LCUCredentials(port: portNumber, token: token)
        }
        return nil
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-xww", "-o", "args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Requests

    private static func request(_ method: String,
                                _ path: String,
                                body: [String: Any]? = nil,
                                credentials: LCUCredentials) async throws -> Data {
        guard let url = URL(string: credentials.baseURL + path) else {
            throw LCUError(message: "Bad LCU path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LCUError(message: "Could not reach the League client: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw LCUError(message: "No response from the League client.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LCUError(message: clientMessage(from: data, status: http.statusCode))
        }
        return data
    }

    /// The client returns its own error envelope; surface its message rather than a bare code.
    private static func clientMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let message = object["message"] as? String
            let code = object["errorCode"] as? String
            switch (message, code) {
            case let (m?, c?) where !m.isEmpty: return "\(m) (\(c))"
            case let (m?, nil) where !m.isEmpty: return m
            case let (_, c?): return "The client rejected it: \(c)"
            default: break
            }
        }
        if status == 400 { return "The client rejected that Riot ID (HTTP 400) — it may be taken, invalid, or changed too recently." }
        if status == 401 || status == 403 { return "The client refused the request (HTTP \(status)). Restart the League client and try again." }
        return "The League client returned HTTP \(status)."
    }

    // MARK: Endpoints

    static func currentSummoner(credentials: LCUCredentials) async throws -> LCUSummoner {
        struct DTO: Decodable {
            let gameName: String?
            let tagLine: String?
            let displayName: String?
            let puuid: String?
            let summonerId: Int64?
            let accountId: Int64?
            let summonerLevel: Int?
            let profileIconId: Int?
        }
        let data = try await request("GET", "/lol-summoner/v1/current-summoner", credentials: credentials)
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), let puuid = dto.puuid, !puuid.isEmpty else {
            throw LCUError(message: "The client is running but nobody is signed in yet.")
        }
        return LCUSummoner(gameName: dto.gameName?.isEmpty == false ? dto.gameName! : (dto.displayName ?? ""),
                           tagLine: dto.tagLine ?? "",
                           puuid: puuid,
                           summonerId: dto.summonerId,
                           summonerLevel: dto.summonerLevel,
                           profileIconId: dto.profileIconId)
    }

    /// The region the client is signed in to, e.g. "NA".
    static func region(credentials: LCUCredentials) async -> Region? {
        struct DTO: Decodable { let region: String?; let webRegion: String? }
        guard let data = try? await request("GET", "/riotclient/region-locale", credentials: credentials),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        return Region.fromClientRegion(dto.region ?? dto.webRegion ?? "")
    }

    // MARK: Refresh (no API key involved)

    /// Everything Refresh needs, read straight from the running client.
    struct Snapshot {
        var summoner: LCUSummoner
        var region: Region?
        var ranks: [RankEntry]
        var lastGame: LastGame?
        var champions: [OwnedChampion]
        var blueEssence: Int?
        var riotPoints: Int?
    }

    static func snapshot(credentials: LCUCredentials) async throws -> Snapshot {
        let me = try await currentSummoner(credentials: credentials)
        async let regionTask = region(credentials: credentials)
        async let ranksTask = rankedStats(credentials: credentials)
        async let gameTask = lastGame(puuid: me.puuid, credentials: credentials)
        async let championTask = ownedChampions(summonerId: me.summonerId, credentials: credentials)
        async let walletTask = wallet(credentials: credentials)

        let purse = await walletTask
        return Snapshot(summoner: me,
                        region: await regionTask,
                        ranks: await ranksTask,
                        lastGame: await gameTask,
                        champions: await championTask,
                        blueEssence: purse.blueEssence,
                        riotPoints: purse.riotPoints)
    }

    // MARK: Champion inventory

    /// The client has shipped two spellings of this over the years; try both.
    static func ownedChampions(summonerId: Int64?, credentials: LCUCredentials) async -> [OwnedChampion] {
        var paths = ["/lol-champions/v1/owned-champions-minimal"]
        if let summonerId {
            paths.append("/lol-champions/v1/inventories/\(summonerId)/champions-minimal")
            paths.append("/lol-champions/v1/inventories/\(summonerId)/champions")
        }
        for path in paths {
            guard let data = try? await request("GET", path, credentials: credentials) else { continue }
            let champions = parseOwnedChampions(data)
            if !champions.isEmpty { return champions }
        }
        return []
    }

    static func parseOwnedChampions(_ data: Data) -> [OwnedChampion] {
        struct DTO: Decodable {
            struct Ownership: Decodable { let owned: Bool? }
            let id: Int?
            let name: String?
            let alias: String?
            let ownership: Ownership?
        }
        guard let list = try? JSONDecoder().decode([DTO].self, from: data) else { return [] }

        var seenIDs = Set<Int>()
        var seenNames = Set<String>()
        var result: [OwnedChampion] = []
        for champ in list {
            // id 0/-1 is the "None" placeholder the client includes.
            guard let id = champ.id, id > 0 else { continue }
            // Absent ownership means the endpoint already filtered to owned champions.
            if let owned = champ.ownership?.owned, owned == false { continue }
            let name = champ.name?.isEmpty == false ? champ.name! : (champ.alias ?? "Champion \(id)")
            // The client can list one champion under several inventory entries, so guard
            // on the name too — an id-only check let those through as visible duplicates.
            let key = name.lowercased()
            guard !seenIDs.contains(id), !seenNames.contains(key) else { continue }
            seenIDs.insert(id)
            seenNames.insert(key)
            result.append(OwnedChampion(id: id, name: name))
        }
        return result.sorted()
    }

    // MARK: Wallet

    struct Wallet {
        var blueEssence: Int?
        var riotPoints: Int?
    }

    static let walletPaths = [
        "/lol-inventory/v1/wallet?currencyTypes=%5B%22lol_blue_essence%22,%22RP%22%5D",
        "/lol-inventory/v1/wallet",
        "/lol-store/v1/wallet",
        "/lol-inventory/v1/wallet/lol_blue_essence",
        "/lol-inventory/v1/wallet/RP"
    ]

    /// The client has moved this endpoint around and changed its key names more than
    /// once; try each known shape and merge whatever comes back.
    static func wallet(credentials: LCUCredentials) async -> Wallet {
        var purse = Wallet()
        for path in walletPaths {
            if purse.blueEssence != nil && purse.riotPoints != nil { break }
            guard let data = try? await request("GET", path, credentials: credentials) else { continue }
            let found = parseWallet(data, hintingCurrency: path)
            if purse.blueEssence == nil { purse.blueEssence = found.blueEssence }
            if purse.riotPoints == nil { purse.riotPoints = found.riotPoints }
        }
        return purse
    }

    private static let blueEssenceKeys = ["lol_blue_essence", "blueEssence", "blue_essence", "ip", "IP"]
    private static let riotPointsKeys = ["RP", "rp", "riotPoints", "riot_points", "lol_rp"]

    static func parseWallet(_ data: Data, hintingCurrency path: String = "") -> Wallet {
        let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        func asInt(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let n = value as? Int64 { return Int(n) }
            if let d = value as? Double { return Int(d) }
            if let s = value as? String, let n = Int(s) { return n }
            return nil
        }

        // A per-currency endpoint answers with a bare number; the path says which one.
        if !(root is [String: Any]), let scalar = asInt(root) {
            if path.localizedCaseInsensitiveContains("blue_essence") { return Wallet(blueEssence: scalar, riotPoints: nil) }
            if path.hasSuffix("/RP") { return Wallet(blueEssence: nil, riotPoints: scalar) }
            return Wallet()
        }

        guard let object = root as? [String: Any] else { return Wallet() }

        func number(_ keys: [String]) -> Int? {
            for (key, value) in object where keys.contains(where: { $0.compare(key, options: .caseInsensitive) == .orderedSame }) {
                if let n = asInt(value) { return n }
            }
            return nil
        }

        return Wallet(blueEssence: number(blueEssenceKeys), riotPoints: number(riotPointsKeys))
    }

    // MARK: Profile icon

    /// PUT /lol-summoner/v1/current-summoner/icon
    ///
    /// The client accepts any icon id, owned or not — this is the same call its own
    /// icon picker makes, without the inventory filter in front of it.
    static func setProfileIcon(id: Int, credentials: LCUCredentials) async throws {
        _ = try await request("PUT", "/lol-summoner/v1/current-summoner/icon",
                              body: ["profileIconId": id],
                              credentials: credentials)
    }

    // MARK: Endpoint discovery

    /// The client publishes its own API catalogue at /help. Rather than hard-coding a
    /// guess at where behaviour penalties live, ask the client and filter.
    static func discoverEndpoints(matching keywords: [String], credentials: LCUCredentials) async -> [String] {
        var text: String?
        for path in ["/help?format=Full", "/help"] {
            if let data = try? await request("GET", path, credentials: credentials) {
                text = String(data: data, encoding: .utf8)
                if text?.isEmpty == false { break }
            }
        }
        guard let text else { return [] }

        // Collect anything shaped like an LCU path, then keep parameter-free GETs.
        let pattern = #"/(?:lol|riotclient|lol-[a-z0-9-]+)[a-zA-Z0-9/_{}-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)

        var found = Set<String>()
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let path = String(text[r])
            guard !path.contains("{"), path.count > 8 else { return }
            let lower = path.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { return }
            found.insert(path)
        }
        return found.sorted()
    }

    /// Everything the client will tell us about behaviour, honor and restrictions.
    static func scanBehaviourEndpoints(credentials: LCUCredentials) async -> [(path: String, body: String)] {
        let keywords = ["honor", "behavior", "behaviour", "restrict", "penalt", "leaver", "standing", "muted"]
        var paths = await discoverEndpoints(matching: keywords, credentials: credentials)

        // Endpoints known to exist even when /help is unavailable or trimmed.
        let fallbacks = [
            "/lol-honor-v2/v1/profile",
            "/lol-leaver-buster/v1/notifications",
            "/lol-player-behavior/v1/restrictions",
            "/lol-chat/v1/me"
        ]
        for path in fallbacks where !paths.contains(path) { paths.append(path) }

        var results: [(String, String)] = []
        for path in paths {
            guard let data = try? await request("GET", path, credentials: credentials),
                  var body = String(data: data, encoding: .utf8) else { continue }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip the empties so the report is only what actually answered.
            guard !body.isEmpty, body != "[]", body != "{}", body != "null" else { continue }
            results.append((path, body))
        }
        return results
    }

    // MARK: Challenges

    /// What a challenge reset managed to clear.
    struct ChallengeReset {
        var badgesCleared = false
        var titleCleared = false
        var bannerCleared = false
        var allSucceeded: Bool { badgesCleared && titleCleared && bannerCleared }
    }

    /// Empties the three challenge tokens shown under your name, the challenge title,
    /// and the banner accent. Each is a separate call so one rejection does not sink
    /// the others.
    static func clearChallenges(credentials: LCUCredentials) async -> ChallengeReset {
        let path = "/lol-challenges/v1/update-player-preferences/"
        var result = ChallengeReset()
        result.badgesCleared = (try? await request("POST", path, body: ["challengeIds": []], credentials: credentials)) != nil
        result.titleCleared = (try? await request("POST", path, body: ["title": ""], credentials: credentials)) != nil
        result.bannerCleared = (try? await request("POST", path, body: ["bannerAccent": ""], credentials: credentials)) != nil
        return result
    }

    // MARK: Friends

    struct Friend: Identifiable, Hashable {
        var id: String          // the client's own handle for this friend
        var name: String
        var note: String
    }

    /// GET /lol-chat/v1/friends
    static func friends(credentials: LCUCredentials) async -> [Friend] {
        guard let data = try? await request("GET", "/lol-chat/v1/friends", credentials: credentials) else {
            return []
        }
        return parseFriends(data)
    }

    static func parseFriends(_ data: Data) -> [Friend] {
        struct DTO: Decodable {
            let pid: String?
            let puuid: String?
            let id: String?
            let name: String?
            let gameName: String?
            let tagLine: String?
            let note: String?
        }
        guard let list = try? JSONDecoder().decode([DTO].self, from: data) else { return [] }

        var seen = Set<String>()
        var result: [Friend] = []
        for dto in list {
            // The client keys friend removal on `pid`; the others are fallbacks.
            guard let handle = [dto.pid, dto.puuid, dto.id]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }), !seen.contains(handle) else { continue }

            let display: String = {
                if let game = dto.gameName, !game.isEmpty {
                    let tag = dto.tagLine ?? ""
                    return tag.isEmpty ? game : "\(game)#\(tag)"
                }
                if let name = dto.name, !name.isEmpty { return name }
                return handle
            }()

            seen.insert(handle)
            result.append(Friend(id: handle, name: display, note: dto.note ?? ""))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// DELETE /lol-chat/v1/friends/{pid}. Irreversible — the client does not undo this.
    static func removeFriend(id: String, credentials: LCUCredentials) async -> Bool {
        (try? await request("DELETE", "/lol-chat/v1/friends/\(id)", credentials: credentials)) != nil
    }

    /// Removes every friend, reporting how many went and how many refused.
    static func removeAllFriends(credentials: LCUCredentials,
                                 progress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> (removed: Int, failed: Int) {
        let all = await friends(credentials: credentials)
        var removed = 0, failed = 0
        for (index, friend) in all.enumerated() {
            if await removeFriend(id: friend.id, credentials: credentials) { removed += 1 } else { failed += 1 }
            await progress(index + 1, all.count)
            // The chat service dislikes a tight loop of deletes.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return (removed, failed)
    }

    // MARK: Diagnostics

    /// Raw GET against any LCU path, for finding endpoints this build guessed wrong.
    static func probe(path: String, credentials: LCUCredentials) async -> String {
        let cleaned = path.hasPrefix("/") ? path : "/" + path
        do {
            let data = try await request("GET", cleaned, credentials: credentials)
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: pretty, encoding: .utf8) {
                return text
            }
            return String(data: data, encoding: .utf8) ?? "\(data.count) bytes of non-text data"
        } catch {
            return "⚠️ \(error.localizedDescription)"
        }
    }

    /// GET /lol-ranked/v1/current-ranked-stats
    static func rankedStats(credentials: LCUCredentials) async -> [RankEntry] {
        guard let data = try? await request("GET", "/lol-ranked/v1/current-ranked-stats", credentials: credentials) else {
            return RankedQueue.allCases.map { RankEntry(queue: $0) }
        }
        return parseRankedStats(data)
    }

    static func parseRankedStats(_ data: Data) -> [RankEntry] {
        struct DTO: Decodable {
            struct Entry: Decodable {
                let queueType: String?
                let tier: String?
                let division: String?
                let leaguePoints: Int?
                let wins: Int?
                let losses: Int?
            }
            let queueMap: [String: Entry]?
        }

        var ranks = RankedQueue.allCases.map { RankEntry(queue: $0) }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let map = dto.queueMap else { return ranks }

        for (key, entry) in map {
            guard let queue = RankedQueue(rawValue: entry.queueType ?? key),
                  let idx = ranks.firstIndex(where: { $0.queue == queue }) else { continue }
            ranks[idx].tier = Tier.from(entry.tier)
            // The client sends "NA" for apex tiers and unranked players.
            ranks[idx].division = Division(rawValue: (entry.division ?? "").uppercased()) ?? .iv
            ranks[idx].lp = entry.leaguePoints ?? 0
            ranks[idx].wins = entry.wins ?? 0
            ranks[idx].losses = entry.losses ?? 0
        }
        return ranks
    }

    /// GET /lol-match-history/v1/products/lol/current-summoner/matches — legacy match shape.
    static func lastGame(puuid: String, credentials: LCUCredentials) async -> LastGame? {
        guard let data = try? await request("GET",
                                            "/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=1",
                                            credentials: credentials) else { return nil }
        let champions = await championMap(credentials: credentials)
        return parseLastGame(data, puuid: puuid, champions: champions)
    }

    static func parseLastGame(_ data: Data, puuid: String, champions: [Int: String]) -> LastGame? {
        struct DTO: Decodable {
            struct Wrapper: Decodable { let games: [Game]? }
            struct Game: Decodable {
                let gameId: Double?
                let gameCreation: Double?
                let gameCreationDate: String?
                let gameDuration: Double?
                let queueId: Int?
                let gameMode: String?
                let platformId: String?
                let participants: [Participant]?
                let participantIdentities: [Identity]?
            }
            struct Participant: Decodable {
                let participantId: Int?
                let championId: Int?
                let stats: Stats?
            }
            struct Stats: Decodable {
                let kills: Int?
                let deaths: Int?
                let assists: Int?
                let win: Bool?
                let gameEndedInEarlySurrender: Bool?
            }
            struct Identity: Decodable {
                struct Player: Decodable { let puuid: String? }
                let participantId: Int?
                let player: Player?
            }
            let games: Wrapper?
        }

        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let game = dto.games?.games?.first else { return nil }

        // Find our row: by PUUID when the client gives one, else the only participant.
        let myParticipantId = game.participantIdentities?.first { $0.player?.puuid == puuid }?.participantId
        let participants = game.participants ?? []
        let me = participants.first { $0.participantId == myParticipantId } ?? participants.first
        guard let me else { return nil }

        var duration = Int(game.gameDuration ?? 0)
        if duration > 60 * 60 * 6 { duration /= 1000 }

        let playedAt: Date = {
            if let millis = game.gameCreation, millis > 0 {
                return Date(timeIntervalSince1970: millis / 1000 + Double(duration))
            }
            if let iso = game.gameCreationDate {
                return ISO8601DateFormatter().date(from: iso) ?? Date()
            }
            return Date()
        }()

        let remake = me.stats?.gameEndedInEarlySurrender == true
        let champion: String = {
            guard let id = me.championId, id > 0 else { return "Unknown" }
            return champions[id] ?? "Champion \(id)"
        }()

        var matchId = ""
        if let id = game.gameId, id > 0 {
            matchId = "\(game.platformId ?? "")_\(String(format: "%.0f", id))"
        }

        return LastGame(champion: champion,
                        queue: LoLQueues.name(for: game.queueId, fallback: game.gameMode),
                        result: remake ? .remake : ((me.stats?.win == true) ? .victory : .defeat),
                        kills: me.stats?.kills ?? 0,
                        deaths: me.stats?.deaths ?? 0,
                        assists: me.stats?.assists ?? 0,
                        durationSeconds: duration,
                        playedAt: playedAt,
                        matchId: matchId)
    }

    /// Champion id → name, from the client's own bundled asset. Served locally, cached once.
    private static var championNames: [Int: String] = [:]

    static func championMap(credentials: LCUCredentials) async -> [Int: String] {
        if !championNames.isEmpty { return championNames }
        struct Champ: Decodable { let id: Int?; let name: String? }
        guard let data = try? await request("GET", "/lol-game-data/assets/v1/champion-summary.json", credentials: credentials),
              let list = try? JSONDecoder().decode([Champ].self, from: data) else { return [:] }
        var map: [Int: String] = [:]
        for champ in list {
            guard let cid = champ.id, cid > 0, let name = champ.name else { continue }
            map[cid] = name
        }
        if !map.isEmpty { championNames = map }
        return championNames
    }

    /// Changes the signed-in account's Riot ID. This is the write the public API has no
    /// equivalent for — it is the same call the client makes for you in its own settings.
    static func changeRiotID(gameName: String, tagLine: String, credentials: LCUCredentials) async throws {
        _ = try await request("POST", "/lol-summoner/v1/save-alias",
                              body: ["gameName": gameName, "tagLine": tagLine],
                              credentials: credentials)
    }
}

extension Region {
    /// Maps the client's region string ("NA", "EUW", "LA1"…) onto a platform.
    static func fromClientRegion(_ raw: String) -> Region? {
        switch raw.uppercased() {
        case "NA", "NA1":            return .na1
        case "EUW", "EUW1":          return .euw1
        case "EUNE", "EUN1", "EUN":  return .eun1
        case "KR":                   return .kr
        case "JP", "JP1":            return .jp1
        case "BR", "BR1":            return .br1
        case "LAN", "LA1":           return .la1
        case "LAS", "LA2":           return .la2
        case "OCE", "OC1":           return .oc1
        case "TR", "TR1":            return .tr1
        case "RU":                   return .ru
        case "PH", "PH2":            return .ph2
        case "SG", "SG2":            return .sg2
        case "TH", "TH2":            return .th2
        case "TW", "TW2":            return .tw2
        case "VN", "VN2":            return .vn2
        case "ME", "ME1", "MENA":    return .me1
        default:                     return nil
        }
    }
}
