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
final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
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
                                timeout: TimeInterval = 10,
                                credentials: LCUCredentials) async throws -> Data {
        guard let url = URL(string: credentials.baseURL + path) else {
            throw LCUError(message: "Bad LCU path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
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
        var honor: HonorProfile?
        var behaviour: BehaviourSnapshot?
        var recentGames: Int?
    }

    static func snapshot(credentials: LCUCredentials) async throws -> Snapshot {
        let me = try await currentSummoner(credentials: credentials)
        async let regionTask = region(credentials: credentials)
        async let ranksTask = rankedStats(credentials: credentials)
        async let gameTask = lastGame(puuid: me.puuid, credentials: credentials)
        async let championTask = ownedChampions(summonerId: me.summonerId, credentials: credentials)
        async let walletTask = wallet(credentials: credentials)
        async let behaviourTask = behaviour(credentials: credentials)
        async let recentTask = recentGameCount(days: Account.recentWindowDays, credentials: credentials)

        let purse = await walletTask
        let behaviourResult = await behaviourTask
        return Snapshot(summoner: me,
                        region: await regionTask,
                        ranks: await ranksTask,
                        lastGame: await gameTask,
                        champions: await championTask,
                        blueEssence: purse.blueEssence,
                        riotPoints: purse.riotPoints,
                        honor: behaviourResult.honor,
                        behaviour: behaviourResult,
                        recentGames: await recentTask)
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

    /// Closes the League client cleanly through its own process-control endpoint — the
    /// same as quitting from the app. Returns whether the request was accepted.
    @discardableResult
    static func quitClient(credentials: LCUCredentials) async -> Bool {
        (try? await request("POST", "/process-control/v1/process/quit",
                            timeout: 6, credentials: credentials)) != nil
    }

    struct ProbeResult {
        let path: String
        let status: Int      // 0 when the request never completed
        let body: String
        var exists: Bool { status != 404 && status != 0 }
        var hasData: Bool {
            guard status == 200 else { return false }
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t != "[]" && t != "{}" && t != "null"
        }
    }

    static func probeStatus(_ path: String, credentials: LCUCredentials, timeout: TimeInterval = 10) async -> ProbeResult {
        guard let url = URL(string: credentials.baseURL + (path.hasPrefix("/") ? path : "/" + path)) else {
            return ProbeResult(path: path, status: 0, body: "bad path")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ProbeResult(path: path, status: status,
                               body: String(data: data, encoding: .utf8) ?? "\(data.count) bytes")
        } catch {
            return ProbeResult(path: path, status: 0, body: error.localizedDescription)
        }
    }

    // MARK: Endpoint discovery

    /// The client publishes its own API catalogue at /help. Rather than hard-coding a
    /// guess at where behaviour penalties live, ask the client and filter.
    /// Every catalogue the client is known to publish, cheapest first.
    static let cataloguePaths = [
        "/swagger/v3/openapi.json",
        "/swagger/v2/swagger.json",
        "/help?format=Full",
        "/help",
        "/Help"
    ]

    /// The catalogue is megabytes; fetch it once per session.
    private static var catalogueCache: String?

    static func catalogue(credentials: LCUCredentials, log: ((String) -> Void)? = nil) async -> String? {
        if let catalogueCache { return catalogueCache }
        for path in cataloguePaths {
            // These payloads run to megabytes; the 10s default was cutting them off.
            let probe = await probeStatus(path, credentials: credentials, timeout: 120)
            log?("\(path) → HTTP \(probe.status), \(probe.body.count) bytes")
            if probe.status == 200, probe.body.count > 200 {
                catalogueCache = probe.body
                return probe.body
            }
        }
        return nil
    }

    /// Raw context around each keyword hit. /help does not spell endpoints out as
    /// literal paths, so seeing how it *does* name them is the only way forward.
    static func catalogueSnippets(matching keywords: [String],
                                  credentials: LCUCredentials,
                                  limit: Int = 6,
                                  window: Int = 140) async -> [String] {
        guard let text = await catalogue(credentials: credentials) else { return [] }
        let lower = text.lowercased()
        var snippets: [String] = []
        var seen = Set<String>()

        for keyword in keywords {
            var searchStart = lower.startIndex
            var perKeyword = 0
            while perKeyword < limit,
                  let range = lower.range(of: keyword.lowercased(), range: searchStart..<lower.endIndex) {
                let start = lower.index(range.lowerBound, offsetBy: -window, limitedBy: lower.startIndex) ?? lower.startIndex
                let end = lower.index(range.upperBound, offsetBy: window, limitedBy: lower.endIndex) ?? lower.endIndex
                let snippet = String(text[start..<end])
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                // Collapse near-duplicates so one plugin does not fill the report.
                let key = String(snippet.prefix(60))
                if !seen.contains(key) {
                    seen.insert(key)
                    snippets.append("[\(keyword)] …\(snippet)…")
                    perKeyword += 1
                }
                searchStart = range.upperBound
            }
        }
        return snippets
    }

    static func discoverEndpoints(matching keywords: [String],
                                  credentials: LCUCredentials,
                                  log: ((String) -> Void)? = nil) async -> [String] {
        guard let text = await catalogue(credentials: credentials, log: log) else { return [] }

        var found = Set<String>()
        for path in allEndpoints(in: text) {
            guard keywords.contains(where: { path.lowercased().contains($0) }) else { continue }
            found.insert(path)
        }
        return found.sorted()
    }

    /// /help does not print URLs. It prints event names —
    /// `OnJsonApiEvent_lol-honor-v2_v1_profile` — where each underscore is a path
    /// separator. That converts straight back into `/lol-honor-v2/v1/profile`.
    static func allEndpoints(in catalogue: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""OnJsonApiEvent_([A-Za-z0-9_-]+)""#) else { return [] }
        let range = NSRange(catalogue.startIndex..., in: catalogue)
        var found = Set<String>()
        regex.enumerateMatches(in: catalogue, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: catalogue) else { return }
            let path = "/" + String(catalogue[r]).replacingOccurrences(of: "_", with: "/")
            found.insert(path)
        }
        return found.sorted()
    }

    /// Test seam: filter a catalogue string without touching the network.
    static func allPlugins(in catalogue: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""Plugin ([a-z0-9-]+)""#) else { return [] }
        let range = NSRange(catalogue.startIndex..., in: catalogue)
        var found = Set<String>()
        regex.enumerateMatches(in: catalogue, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: catalogue) else { return }
            found.insert(String(catalogue[r]))
        }
        return found.sorted()
    }

    struct BehaviourScan {
        var withData: [(path: String, body: String)] = []
        var empty: [String] = []
        var missing: [String] = []
        var catalogueLog: [String] = []
        var snippets: [String] = []
        var plugins: [String] = []
        var totalEndpoints = 0
        var catalogueSize = 0
        var helpWorked = false
    }

    /// "REPUTATION_ELIGIBLE_GAME_PLAYED" in the honor payload says Riot calls this
    /// system reputation, so search widely rather than around one guessed word.
    static let behaviourKeywords = [
        "honor", "behavior", "behaviour", "restrict", "penalt", "leaver", "standing",
        "muted", "mute", "reputation", "reform", "sanction", "punish", "voice",
        "dodge", "gatekeep", "chat-restrict", "matchmaking"
    ]

    /// Plausible homes for the Behaviour Standing panel. A 404 here is still useful:
    /// it rules a plugin out.
    static let behaviourFallbackPaths = [
        "/lol-honor-v2/v1/profile",
        "/lol-honor-v2/v1/rewards",
        "/lol-honor-v2/v1/penalties",
        "/lol-honor-v2/v1/standing",
        "/lol-leaver-buster/v1/notifications",
        "/lol-leaver-buster/v1/state",
        "/lol-leaver-buster/v1/ranked-restriction",
        "/lol-leaver-buster/v1/queue-lockout",
        "/lol-player-behavior/v1/reform-card",
        "/lol-player-behavior/v2/reform-card",
        "/lol-player-behavior/v3/reform-cards",
        "/lol-player-behavior/v1/config",
        "/lol-player-behavior/v1/code-of-conduct-notification",
        "/lol-player-behavior/v1/notifications",
        "/ga-restriction/v1/penalty-notifications",
        "/lol-lobby-team-builder/v1/matchmaking",
        "/lol-matchmaking/v1/search/errors",
        "/lol-player-behavior/v1/restrictions",
        "/lol-player-behavior/v1/behavior-standing",
        "/lol-player-behavior/v1/penalties",
        "/lol-reputation/v1/standing",
        "/lol-reputation/v1/penalties",
        "/lol-reputation/v1/profile",
        "/lol-restriction/v1/restrictions",
        "/lol-penalties/v1/penalties",
        "/lol-behaviour/v1/standing",
        "/lol-matchmaking/v1/search",
        "/lol-premade-voice/v1/settings",
        "/lol-gameflow/v1/gameflow-metadata/player-status",
        "/lol-chat/v1/me"
    ]

    /// Everything the client will tell us about behaviour, honor and restrictions.
    static func scanBehaviourEndpoints(credentials: LCUCredentials) async -> BehaviourScan {
        var scan = BehaviourScan()
        var log: [String] = []
        catalogueCache = nil   // a fresh scan should re-read the client
        var paths = await discoverEndpoints(matching: behaviourKeywords,
                                            credentials: credentials) { log.append($0) }
        scan.catalogueLog = log
        scan.catalogueSize = paths.count
        scan.helpWorked = !paths.isEmpty

        // Whatever the parser made of it, show raw context so the naming scheme is
        // visible even when no path is recognised.
        if let text = await catalogue(credentials: credentials) {
            scan.totalEndpoints = allEndpoints(in: text).count
            // Plugins whose name hints at behaviour; the full count tells us the
            // catalogue really was parsed.
            let interesting = ["honor", "penalt", "restrict", "reputation", "behavi",
                               "leaver", "mute", "ban", "suspend", "reform", "standing", "punish"]
            scan.plugins = allPlugins(in: text).filter { plugin in
                interesting.contains { plugin.contains($0) }
            }
        }
        scan.snippets = await catalogueSnippets(
            matching: ["penalt", "restrict", "reputation", "behavi", "suspend", "reform", "punish", "standing"],
            credentials: credentials)

        // Config namespaces are server settings, not player state, and there are
        // hundreds of them — they swallowed the whole probe budget last time and the
        // player-behavior endpoints were never reached.
        let noise = ["/lol-platform-config/", "/lol-game-queues/", "/lol-settings/"]
        paths.removeAll { path in noise.contains { path.hasPrefix($0) } }

        for path in behaviourFallbackPaths where !paths.contains(path) { paths.append(path) }
        if paths.count > 200 { paths = Array(paths.prefix(200)) }

        for path in paths {
            let probe = await probeStatus(path, credentials: credentials)
            if probe.hasData {
                // Keep the report readable; one endpoint dumped 200 KB of queue config.
                var body = probe.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.count > 1200 { body = String(body.prefix(1200)) + "… [truncated]" }
                scan.withData.append((path, body))
            } else if probe.exists {
                scan.empty.append("\(path) [HTTP \(probe.status)]")
            } else {
                scan.missing.append("\(path) [\(probe.status == 0 ? "no response" : "404")]")
            }
        }
        writeDiagnostics(scan, credentials: credentials)
        return scan
    }

    /// Dumps the full scan and the client's entire endpoint list to disk, so the
    /// report does not have to be copied out of the window by hand.
    static var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LeagueVault/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeDiagnostics(_ scan: BehaviourScan, credentials: LCUCredentials) {
        var report = "League Vault behaviour scan\n"
        report += Date().description + "\n\n"
        report += "catalogue: \(scan.totalEndpoints) endpoints, \(scan.catalogueSize) matching\n"
        report += scan.catalogueLog.map { "  " + $0 }.joined(separator: "\n") + "\n"
        if !scan.plugins.isEmpty {
            report += "\nplugins: " + scan.plugins.joined(separator: ", ") + "\n"
        }
        for entry in scan.withData {
            report += "\n=== \(entry.path) ===\n\(entry.body)\n"
        }
        if !scan.empty.isEmpty {
            report += "\n=== exists but empty ===\n" + scan.empty.joined(separator: "\n") + "\n"
        }
        if !scan.missing.isEmpty {
            report += "\n=== not present ===\n" + scan.missing.joined(separator: "\n") + "\n"
        }
        try? report.write(to: diagnosticsDirectory.appendingPathComponent("scan.txt"),
                          atomically: true, encoding: .utf8)

        // The complete endpoint list is the most useful artefact of all.
        if let catalogue = catalogueCache {
            let all = allEndpoints(in: catalogue)
            try? all.joined(separator: "\n").write(
                to: diagnosticsDirectory.appendingPathComponent("endpoints.txt"),
                atomically: true, encoding: .utf8)
        }
    }

    // MARK: Honor

    struct HonorProfile {
        var level: Int?
        var rewardsLocked: Bool
        var gamesRemaining: Int?
        var gamesRequired: Int?
    }

    /// GET /lol-honor-v2/v1/profile — the client's Behaviour Standing panel reads this.
    static func honor(credentials: LCUCredentials) async -> HonorProfile? {
        guard let data = try? await request("GET", "/lol-honor-v2/v1/profile", credentials: credentials) else {
            return nil
        }
        return parseHonor(data)
    }

    static func parseHonor(_ data: Data) -> HonorProfile? {
        struct DTO: Decodable {
            struct Redemption: Decodable {
                let eventType: String?
                let remaining: Int?
                let required: Int?
            }
            let honorLevel: Int?
            let rewardsLocked: Bool?
            let redemptions: [Redemption]?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        // The panel's "HONOR DOWNGRADE — n Games" is this redemption's `remaining`.
        let redemption = dto.redemptions?.first { ($0.remaining ?? 0) > 0 } ?? dto.redemptions?.first
        return HonorProfile(level: dto.honorLevel,
                            rewardsLocked: dto.rewardsLocked ?? false,
                            gamesRemaining: redemption?.remaining,
                            gamesRequired: redemption?.required)
    }

    // MARK: Behaviour penalties
    //
    // Endpoint names recovered from the client's own /help catalogue. The field names
    // below come from its published type definitions:
    //   LolLeaverBusterLeaverBusterNotification { punishedGamesRemaining,
    //       hasActivePenalty, queueLockoutTimerExpiryUtcMillis, punishmentTimerType }
    //   lowPriorityData { penaltyTime, penaltyTimeRemaining, penalizedSummonerIds }

    struct BehaviourSnapshot {
        var honor: HonorProfile?
        var lowPriorityPenaltySeconds: Double?
        var punishedGamesRemaining: Int?
        var lockoutExpiry: Date?
        var hasActivePenalty = false
        var reformCard: String?
        var restrictions: [Penalty] = []
    }

    /// GET /lol-summoner-profiles/v1/get-restriction-view
    ///
    /// ```
    /// {"restrictions":[{"restrictionType":"QUEUE_DELAY",
    ///                   "restrictionReason":"AWAY_FROM_KEYBOARD",
    ///                   "restrictionsMillis":600000,
    ///                   "expirationData":{"expirationMillis":0,
    ///                     "redemptions":[{"redemptionCountRemaining":3,
    ///                                     "redemptionCountRequired":5,
    ///                                     "redemptionEventType":"MATCHMADE_GAME_PLAYED"}]}}]}
    /// ```
    static func parseRestrictions(_ data: Data) -> [Penalty] {
        struct DTO: Decodable {
            struct Restriction: Decodable {
                struct Expiration: Decodable {
                    struct Redemption: Decodable {
                        let redemptionCountRemaining: Int?
                        let redemptionCountRequired: Int?
                        let redemptionEventType: String?
                    }
                    let expirationMillis: Double?
                    let redemptions: [Redemption]?
                }
                let restrictionType: String?
                let restrictionReason: String?
                let restrictionsMillis: Double?
                let expirationData: Expiration?
            }
            let restrictions: [Restriction]?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let list = dto.restrictions else { return [] }

        var result: [Penalty] = []
        for restriction in list {
            let type = (restriction.restrictionType ?? "").uppercased()
            // REPUTATION_LIMIT is progress back to full honor, not a restriction on
            // play. The honor level is surfaced on its own instead.
            if type.contains("REPUTATION") { continue }
            let redemption = restriction.expirationData?.redemptions?.first

            var parts: [String] = []
            // restrictionsMillis is the size of the penalty, e.g. a 10-minute delay.
            if let millis = restriction.restrictionsMillis, millis > 0 {
                let minutes = Int((millis / 60_000).rounded())
                parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
            }
            if let remaining = redemption?.redemptionCountRemaining, remaining > 0 {
                if let required = redemption?.redemptionCountRequired, required > 0 {
                    parts.append("\(remaining) of \(required) games remaining")
                } else {
                    parts.append("\(remaining) games remaining")
                }
            }
            if let reason = restriction.restrictionReason, !reason.isEmpty, reason != "NONE" {
                parts.append(humanise(reason))
            }

            // Nothing left to serve: not an active penalty.
            let remaining = redemption?.redemptionCountRemaining ?? 0
            let expiry = restriction.expirationData?.expirationMillis ?? 0
            if remaining <= 0 && expiry <= 0 && (restriction.restrictionsMillis ?? 0) <= 0 { continue }

            result.append(Penalty(
                source: .client,
                kind: kind(forRestrictionType: type),
                detail: parts.isEmpty ? humanise(type) : parts.joined(separator: " · "),
                startedAt: Date(),
                expiresAt: expiry > 0 ? Date(timeIntervalSince1970: expiry / 1000) : nil
            ))
        }
        return result
    }

    private static func kind(forRestrictionType type: String) -> PenaltyKind {
        switch true {
        case type.contains("QUEUE_DELAY"):      return .queueDelay
        case type.contains("REPUTATION"):       return .honorDowngrade
        case type.contains("LOW_PRIORITY"),
             type.contains("LEAVER"):           return .lowPriorityQueue
        case type.contains("VOICE"):            return .voiceMuted
        case type.contains("CHAT"),
             type.contains("COMMUNICATION"):    return .chatRestriction
        case type.contains("RANKED"):           return .rankedRestriction
        case type.contains("PERMANENT"):        return .permanentBan
        case type.contains("BAN"),
             type.contains("SUSPEN"):           return .suspension
        default:                                return .other
        }
    }

    /// AWAY_FROM_KEYBOARD -> "Away from keyboard"
    private static func humanise(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func behaviour(credentials: LCUCredentials) async -> BehaviourSnapshot {
        var snapshot = BehaviourSnapshot()
        snapshot.honor = await honor(credentials: credentials)

        // The Behaviour Standing panel itself. Everything it renders is here, with
        // real numbers, whether or not you are queued.
        if let data = try? await request("GET", "/lol-summoner-profiles/v1/get-restriction-view", credentials: credentials) {
            snapshot.restrictions = parseRestrictions(data)
        }


        if let data = try? await request("GET", "/lol-leaver-buster/v1/notifications", credentials: credentials) {
            let parsed = parseLeaverNotifications(data)
            snapshot.punishedGamesRemaining = parsed.games
            snapshot.lockoutExpiry = parsed.lockout
            snapshot.hasActivePenalty = parsed.active
        }

        // The queue-delay timer lives on the matchmaking resource, not leaver-buster.
        if let data = try? await request("GET", "/lol-lobby-team-builder/v1/matchmaking", credentials: credentials) {
            snapshot.lowPriorityPenaltySeconds = parseLowPriority(data)
        }

        for path in ["/lol-player-behavior/v1/reform-card", "/lol-player-behavior/v2/reform-card"] {
            guard let data = try? await request("GET", path, credentials: credentials),
                  let summary = parseReformCard(data) else { continue }
            snapshot.reformCard = summary
            break
        }
        return snapshot
    }

    static func parseLeaverNotifications(_ data: Data) -> (games: Int?, lockout: Date?, active: Bool) {
        struct DTO: Decodable {
            let punishedGamesRemaining: Int?
            let hasActivePenalty: Bool?
            let queueLockoutTimerExpiryUtcMillis: Double?
        }
        let items: [DTO]
        if let list = try? JSONDecoder().decode([DTO].self, from: data) {
            items = list
        } else if let one = try? JSONDecoder().decode(DTO.self, from: data) {
            items = [one]
        } else {
            return (nil, nil, false)
        }

        var games: Int?
        var lockout: Date?
        var active = false
        for item in items {
            if let n = item.punishedGamesRemaining, n > 0 { games = max(games ?? 0, n) }
            if let millis = item.queueLockoutTimerExpiryUtcMillis, millis > 0 {
                lockout = Date(timeIntervalSince1970: millis / 1000)
            }
            if item.hasActivePenalty == true { active = true }
        }
        return (games, lockout, active)
    }

    /// `penaltyTimeRemaining` counts down; `penaltyTime` is the sentence length.
    static func parseLowPriority(_ data: Data) -> Double? {
        struct DTO: Decodable {
            struct LowPriority: Decodable {
                let penaltyTime: Double?
                let penaltyTimeRemaining: Double?
            }
            let lowPriorityData: LowPriority?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let low = dto.lowPriorityData else { return nil }
        if let remaining = low.penaltyTimeRemaining, remaining > 0 { return remaining }
        if let total = low.penaltyTime, total > 0 { return total }
        return nil
    }

    /// The reform card's shape is not published; summarise whatever it carries.
    static func parseReformCard(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts: [String] = []
        for key in ["punishment", "punishmentType", "restrictionType", "reason", "status", "state"] {
            if let value = object[key] as? String, !value.isEmpty { parts.append(value) }
        }
        if let games = object["gamesRemaining"] as? Int, games > 0 { parts.append("\(games) games remaining") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Turns the honor profile into penalty records the vault can hold.
    static func penalties(from snapshot: BehaviourSnapshot) -> [Penalty] {
        var result: [Penalty] = []

        // The restriction view is authoritative. Honor is reported as a level on the
        // account rather than as a penalty.
        result += snapshot.restrictions


        // Queue delay: a live countdown in seconds.
        if let seconds = snapshot.lowPriorityPenaltySeconds, seconds > 0 {
            let minutes = Int((seconds / 60).rounded())
            result.append(Penalty(
                source: .client,
                kind: .queueDelay,
                detail: "\(minutes) minute\(minutes == 1 ? "" : "s") added to each queue",
                startedAt: Date(),
                expiresAt: Date().addingTimeInterval(seconds)
            ))
        }

        // Low-priority queue served off in games rather than time.
        if let games = snapshot.punishedGamesRemaining, games > 0 {
            result.append(Penalty(
                source: .client,
                kind: .lowPriorityQueue,
                detail: "\(games) game\(games == 1 ? "" : "s") remaining",
                startedAt: Date(),
                expiresAt: nil
            ))
        }

        if let lockout = snapshot.lockoutExpiry, lockout > Date() {
            result.append(Penalty(
                source: .client,
                kind: .queueDelay,
                detail: "Queue lockout",
                startedAt: Date(),
                expiresAt: lockout
            ))
        }

        if let card = snapshot.reformCard {
            result.append(Penalty(
                source: .client,
                kind: .chatRestriction,
                detail: card,
                startedAt: Date(),
                expiresAt: nil
            ))
        }

        return result
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

    // MARK: Owned profile icons

    /// Icon ids this account actually owns. The client accepts any id, but Riot resets
    /// an unowned one server-side, so quick prep checks before choosing.
    /// What one quick-prep pass did. Callers word their own report from it — the client
    /// sheet and the account cycle describe the same actions differently.
    struct QuickPrepOutcome {
        var iconRequested: Int?
        var iconSet: Int?
        var iconFellBack = false
        var iconError: String?
        var challenges: ChallengeReset?
        var friendsRemoved: Int?
        var friendsFailed: Int?
    }

    /// Sets the profile icon, clears the challenge badges, and optionally removes every
    /// friend — the sequence behind both the Quick prep button and the account cycle.
    /// `stage` reports what it is doing, for a progress line.
    static func runQuickPrep(credentials: LCUCredentials,
                             setIcon: Bool, iconId: Int,
                             clearChallenges: Bool,
                             removeFriends: Bool,
                             stage: ((String) -> Void)? = nil) async -> QuickPrepOutcome {
        var outcome = QuickPrepOutcome()

        if setIcon {
            outcome.iconRequested = iconId
            stage?("Checking icon ownership…")
            let owned = await ownedProfileIcons(credentials: credentials)
            let choice = QuickPrep.resolvedIcon(preferring: iconId, ownedIcons: owned)

            stage?("Setting profile icon…")
            do {
                try await setProfileIcon(id: choice.id, credentials: credentials)
                outcome.iconSet = choice.id
                outcome.iconFellBack = choice.fellBack
            } catch {
                outcome.iconError = error.localizedDescription
            }
        }

        if clearChallenges {
            stage?("Clearing challenge badges…")
            // Qualified: the `clearChallenges` parameter shadows the function name here.
            outcome.challenges = await Self.clearChallenges(credentials: credentials)
        }

        if removeFriends {
            let result = await removeAllFriends(credentials: credentials) { done, total in
                stage?("Removing friend \(done) of \(total)…")
            }
            outcome.friendsRemoved = result.removed
            outcome.friendsFailed = result.failed
        }
        return outcome
    }

    static func ownedProfileIcons(credentials: LCUCredentials) async -> Set<Int> {
        let paths = [
            "/lol-inventory/v2/inventory/SUMMONER_ICON",
            "/lol-inventory/v1/inventory?inventoryTypes=%5B%22SUMMONER_ICON%22%5D",
            "/lol-inventory/v2/inventory?inventoryTypes=%5B%22SUMMONER_ICON%22%5D",
            "/lol-inventory/v1/inventory"
        ]
        for path in paths {
            guard let data = try? await request("GET", path, credentials: credentials) else { continue }
            let owned = parseOwnedIcons(data)
            if !owned.isEmpty { return owned }
        }
        return []
    }

    /// Inventory entries vary in shape between versions; take any SUMMONER_ICON row and
    /// read whichever id field it carries.
    static func parseOwnedIcons(_ data: Data) -> Set<Int> {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var rows: [[String: Any]] = []
        if let list = root as? [[String: Any]] {
            rows = list
        } else if let object = root as? [String: Any] {
            // Some builds wrap the list, e.g. {"data":{"SUMMONER_ICON":[…]}}
            for value in object.values {
                if let list = value as? [[String: Any]] { rows += list }
                if let nested = value as? [String: Any] {
                    for inner in nested.values where inner is [[String: Any]] {
                        rows += inner as! [[String: Any]]
                    }
                }
            }
        }

        var owned = Set<Int>()
        for row in rows {
            if let type = row["inventoryType"] as? String,
               !type.uppercased().contains("SUMMONER_ICON") { continue }
            for key in ["itemId", "id", "contentId", "inventoryItemId"] {
                if let value = row[key] as? Int, value >= 0 { owned.insert(value); break }
                if let value = row[key] as? String, let n = Int(value), n >= 0 { owned.insert(n); break }
            }
        }
        return owned
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

    /// How many games in the last `days`, counted from the client's match history.
    /// Paged, and stops as soon as it walks past the window — nobody needs the whole
    /// history to answer "how much has this account been played lately".
    static func recentGameCount(days: Int, credentials: LCUCredentials) async -> Int? {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let pageSize = 100
        let maxPages = 4                    // 400 games is plenty for a 3-month window
        var total = 0

        for page in 0..<maxPages {
            let start = page * pageSize
            let end = start + pageSize - 1
            guard let data = try? await request(
                "GET",
                "/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=\(start)&endIndex=\(end)",
                credentials: credentials) else { return page == 0 ? nil : total }

            let dates = parseMatchDates(data)
            if dates.isEmpty { return total }

            total += dates.filter { $0 >= cutoff }.count
            // Anything older than the window means the rest is older still.
            if let oldest = dates.min(), oldest < cutoff { return total }
            if dates.count < pageSize { return total }
        }
        return total
    }

    static func parseMatchDates(_ data: Data) -> [Date] {
        struct DTO: Decodable {
            struct Wrapper: Decodable { let games: [Game]? }
            struct Game: Decodable {
                let gameCreation: Double?
                let gameCreationDate: String?
            }
            let games: Wrapper?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let games = dto.games?.games else { return [] }

        let iso = ISO8601DateFormatter()
        return games.compactMap { game in
            if let millis = game.gameCreation, millis > 0 {
                return Date(timeIntervalSince1970: millis / 1000)
            }
            if let text = game.gameCreationDate { return iso.date(from: text) }
            return nil
        }
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
