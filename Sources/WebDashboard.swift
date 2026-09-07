import Foundation
import CryptoKit

// A published dashboard is one static file. The page is generated here, the vault is
// baked into it as JSON, and the whole thing is dropped into a folder on the Windows
// server for whatever web server is already pointed at it. Nothing runs server-side,
// so there is no database, no PHP, and nothing to keep patched.
//
// Passwords are never written into the page. Optionally the payload is sealed with a
// passphrase exactly the way a backup is, and the browser unseals it with WebCrypto —
// so what actually sits on the server is ciphertext.

// MARK: - What the page receives

struct SiteRegion: Codable {
    var code: String
    var short: String
    var long: String
}

struct SiteRank: Codable {
    var tier: String
    var div: String
    var lp: Int
    var wins: Int
    var losses: Int
    var peakTier: String
    var peakDiv: String
    var peakNote: String

    init(_ r: RankEntry) {
        tier = r.tier.rawValue
        div = r.division.rawValue
        lp = r.lp
        wins = r.wins
        losses = r.losses
        peakTier = r.peakTier.rawValue
        peakDiv = r.peakDivision.rawValue
        peakNote = r.peakNote
    }
}

struct SiteGame: Codable {
    var champion: String
    /// Riot's numeric champion id, when the account's own champion list can supply it.
    /// The page draws art from it directly, with no name-to-key guessing.
    var championId: Int?
    var queue: String
    var result: String
    var kda: String
    var duration: String
    var playedAt: Date

    init(_ g: LastGame, championId: Int?) {
        self.championId = championId
        champion = g.champion
        queue = g.queue
        result = g.result.rawValue
        kda = g.kda
        duration = g.durationDisplay
        playedAt = g.playedAt
    }
}

struct SitePenalty: Codable {
    var kind: String
    var detail: String
    var status: String
    var source: String
    var active: Bool
    var critical: Bool
    var startedAt: Date
    var expiresAt: Date?

    init(_ p: Penalty) {
        kind = p.kind.rawValue
        detail = p.detail
        status = p.statusDisplay
        source = p.source.rawValue
        active = p.isActive
        critical = p.kind.isCritical
        startedAt = p.startedAt
        expiresAt = p.expiresAt
    }
}

struct SiteChampion: Codable {
    var id: Int
    var name: String
}

struct SiteAccount: Codable {
    var id: String
    var name: String
    var riotId: String
    var folder: String
    var notes: String
    /// Only carried when the page is locked — a login on an open page is a giveaway.
    var login: String?
    var region: SiteRegion
    /// "FA", "NFA", or absent when it was never recorded.
    var access: String?
    var level: Int?
    var iconId: Int?
    var be: Int?
    var rp: Int?
    var honor: Int?
    /// Keyed "solo" and "flex" so the page can read them by name.
    var ranks: [String: SiteRank]
    var lastGame: SiteGame?
    var penalties: [SitePenalty]
    var champions: [SiteChampion]
    var recentGames: Int?
    var recentGamesAsOf: Date?
    var lastRefreshed: Date?
    var ugg: String?

    init(_ a: Account, includeLogin: Bool) {
        id = a.id.uuidString
        name = a.displayName
        riotId = a.riotID
        folder = a.folder
        notes = a.notes
        login = includeLogin && !a.loginUsername.isEmpty ? a.loginUsername : nil
        region = SiteRegion(code: a.region.rawValue, short: a.region.display, long: a.region.longName)
        access = a.access == .unknown ? nil : a.access.rawValue
        level = a.summonerLevel
        iconId = a.profileIconId
        be = a.blueEssence
        rp = a.riotPoints
        honor = a.honorLevel
        ranks = ["solo": SiteRank(a.soloRank), "flex": SiteRank(a.flexRank)]
        lastGame = a.lastGame.map { game in
            SiteGame(game, championId: a.ownedChampions
                .first { $0.name.caseInsensitiveCompare(game.champion) == .orderedSame }?.id)
        }
        // Worst first, so the page can show the leading badge without re-sorting.
        penalties = a.penalties
            .sorted { $0.kind.severityRank < $1.kind.severityRank }
            .map(SitePenalty.init)
        champions = a.ownedChampions.sorted().map { SiteChampion(id: $0.id, name: $0.name) }
        recentGames = a.recentGames
        recentGamesAsOf = a.recentGamesAsOf
        lastRefreshed = a.lastRefreshed
        ugg = a.uggURL?.absoluteString
    }
}

struct SitePayload: Codable {
    var title: String
    var origin: String
    var publishedAt: Date
    var accounts: [SiteAccount]
}

/// What sits on the server when the page is locked: an envelope the browser can open
/// with the passphrase and nothing else.
struct LockedPayload: Codable {
    var locked = true
    var cipher = "AES-256-GCM"
    var kdf = "PBKDF2-HMAC-SHA256"
    var iterations: Int
    var salt: String        // base64
    var payload: String     // base64, nonce ‖ ciphertext ‖ tag
}

// MARK: - Building the page

struct SiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SiteBuilder {
    static let titlePlaceholder = "__LV_TITLE__"
    static let payloadPlaceholder = "__LV_PAYLOAD__"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func payload(from accounts: [Account], title: String, includeLogins: Bool) -> SitePayload {
        SitePayload(
            title: title,
            origin: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            publishedAt: Date(),
            accounts: accounts.map { SiteAccount($0, includeLogin: includeLogins) })
    }

    /// The page template, shipped inside the app bundle.
    static func template() throws -> String {
        if let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        throw SiteError(message: "dashboard.html is missing from the app bundle. Rebuild League Vault with build.sh.")
    }

    /// JSON that is safe to drop inside a <script> element. The three characters that
    /// could end the element early are escaped; both are valid JSON escapes, so the
    /// browser still parses it as the same document.
    private static func inlineJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SiteError(message: "The vault could not be encoded as JSON.")
        }
        return text
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    /// Seals the payload the same way a backup is sealed, so the browser's WebCrypto
    /// side can be a direct translation of BackupService.
    static func lock(_ payload: SitePayload, passphrase: String) throws -> LockedPayload {
        guard !passphrase.isEmpty else {
            throw SiteError(message: "Set a page passphrase, or turn the lock off.")
        }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let key = try BackupService.deriveKey(passphrase: passphrase, salt: salt,
                                              iterations: BackupService.iterations)
        let plaintext = try encoder.encode(payload)
        guard let sealed = try AES.GCM.seal(plaintext, using: key).combined else {
            throw SiteError(message: "The page payload could not be encrypted.")
        }
        return LockedPayload(iterations: BackupService.iterations,
                             salt: salt.base64EncodedString(),
                             payload: sealed.base64EncodedString())
    }

    /// The finished page: template, title, and either the vault or its ciphertext.
    static func html(accounts: [Account], title: String,
                     passphrase: String?, includeLogins: Bool) throws -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "League Vault" : title
        let payload = payload(from: accounts, title: cleanTitle, includeLogins: includeLogins)

        let json: String
        if let passphrase, !passphrase.isEmpty {
            json = try inlineJSON(lock(payload, passphrase: passphrase))
        } else {
            json = try inlineJSON(payload)
        }

        let escapedTitle = cleanTitle
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return try template()
            .replacingOccurrences(of: titlePlaceholder, with: escapedTitle)
            .replacingOccurrences(of: payloadPlaceholder, with: json)
    }
}

// MARK: - Publishing

@MainActor
final class WebDashboard: ObservableObject {
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Folder on the server that the web server serves. index.html lands in it.
    @Published var remotePath: String { didSet { defaults.set(remotePath, forKey: Keys.path) } }
    /// Where the page ends up in a browser, used by the Open button. Cosmetic only.
    @Published var siteURL: String { didSet { defaults.set(siteURL, forKey: Keys.url) } }
    @Published var title: String { didSet { defaults.set(title, forKey: Keys.title) } }
    /// Encrypt the payload and make the browser ask for a passphrase.
    @Published var isLocked: Bool { didSet { defaults.set(isLocked, forKey: Keys.locked) } }
    /// Login names are only ever published behind the lock.
    @Published var includeLogins: Bool { didSet { defaults.set(includeLogins, forKey: Keys.logins) } }

    @Published private(set) var lastPublish: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false
    @Published var log: [String] = []

    private enum Keys {
        static let enabled = "webEnabled", path = "webPath", url = "webURL"
        static let title = "webTitle", locked = "webLocked", logins = "webLogins"
        static let last = "webLastPublish"
    }

    private let defaults = UserDefaults.standard
    private weak var store: AccountStore?
    private weak var remote: RemoteBackup?
    private var debounce: Task<Void, Never>?

    init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        remotePath = defaults.string(forKey: Keys.path) ?? "C:/LeagueVaultWeb"
        siteURL = defaults.string(forKey: Keys.url) ?? ""
        title = defaults.string(forKey: Keys.title) ?? "League Vault"
        // Locked by default: the page is going onto an address anyone can reach.
        isLocked = defaults.object(forKey: Keys.locked) as? Bool ?? true
        includeLogins = defaults.bool(forKey: Keys.logins)
        lastPublish = defaults.object(forKey: Keys.last) as? Date
    }

    /// Kept in the Keychain so an automatic publish can run without asking.
    var passphrase: String? {
        get {
            guard let data = Keychain.read("web-passphrase") else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(Data(newValue.utf8), account: "web-passphrase")
            } else {
                Keychain.delete("web-passphrase")
            }
        }
    }

    var hasPassphrase: Bool { !(passphrase ?? "").isEmpty }

    /// Everything needed to actually push a page out.
    var isConfigured: Bool {
        guard let remote, remote.hasServerAccess else { return false }
        guard !remotePath.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !isLocked || hasPassphrase
    }

    /// The Windows path the page lands in, spelled the way Explorer spells it.
    var resolvedWindowsPath: String {
        SFTPPath.windows(remotePath, user: remote?.user.isEmpty == false ? remote!.user : "<username>")
    }

    private var sftpDirectory: String { SFTPPath.remote(remotePath) }

    // MARK: Wiring

    func attach(to store: AccountStore, remote: RemoteBackup) {
        self.store = store
        self.remote = remote
        NotificationCenter.default.addObserver(forName: .vaultDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleDebounced() }
        }
    }

    /// A burst of edits should publish once, not twenty times.
    private func scheduleDebounced() {
        guard isEnabled, isConfigured else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.publish(reason: "vault changed")
        }
    }

    // MARK: Building

    private func renderHTML() throws -> String {
        guard let store else { throw SiteError(message: "The vault is not loaded yet.") }
        let key = isLocked ? passphrase : nil
        if isLocked && (key ?? "").isEmpty {
            throw SiteError(message: "The page is set to lock but no passphrase is saved.")
        }
        return try SiteBuilder.html(accounts: store.accounts,
                                    title: title,
                                    passphrase: key,
                                    includeLogins: isLocked && includeLogins)
    }

    /// Writes the page next to the vault's own data and hands back the file, so it can
    /// be opened in a browser without a server anywhere in the picture.
    @discardableResult
    func writePreview() -> URL? {
        do {
            let html = try renderHTML()
            let dir = AccountStore.directory.appendingPathComponent("web", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("index.html")
            try html.write(to: file, atomically: true, encoding: .utf8)
            lastError = nil
            return file
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Publishing

    @discardableResult
    func publish(reason: String) async -> Bool {
        guard !isBusy else { return false }
        guard let remote else { lastError = "The server settings are not loaded."; return false }
        guard remote.hasServerAccess else {
            lastError = "Set the server up first, under “Back up to your server”."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        log = []

        do {
            let html = try renderHTML()
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-index-\(UUID().uuidString).html")
            try html.write(to: staged, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: staged) }

            let dir = sftpDirectory
            log.append("Publishing \(store?.accounts.count ?? 0) accounts to \(resolvedWindowsPath)…")

            let made = remote.makeRemoteDirectory(path: dir, target: remote.sshTarget)
            if made.status != 0 {
                lastError = "Could not create \(resolvedWindowsPath): \(remote.describeFailure(made.output))"
                log.append(made.output.trimmingCharacters(in: .whitespacesAndNewlines))
                return false
            }

            // Upload beside the live page and swap it in, so a dropped connection never
            // leaves a half-written page being served. SFTP's rename will not overwrite,
            // so the old file goes first — "-" keeps a missing file from failing the run.
            let result = remote.runSFTPBatch([
                "put \"\(staged.path)\" \"\(dir)/index.html.part\"",
                "-rm \"\(dir)/index.html\"",
                "rename \"\(dir)/index.html.part\" \"\(dir)/index.html\""
            ])
            guard result.status == 0 else {
                lastError = "\(reason.capitalized) publish failed: \(remote.describeFailure(result.output))"
                log.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                return false
            }

            lastPublish = Date()
            defaults.set(lastPublish, forKey: Keys.last)
            lastError = nil
            log.append("Published. \(resolvedWindowsPath)\\index.html is now the current page.")
            return true
        } catch {
            lastError = "\(reason.capitalized) publish failed: \(error.localizedDescription)"
            return false
        }
    }
}
