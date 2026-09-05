import Foundation
import Security
import CryptoKit

// MARK: - Keychain

enum Keychain {
    static let service = "com.corbin.leaguevault"

    static func read(_ account: String) -> Data? {
        readWithStatus(account).data
    }

    /// The status matters: "no such item" and "you may not read this item" call for
    /// completely different handling, and conflating them can destroy data.
    static func readWithStatus(_ account: String) -> (data: Data?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status == errSecSuccess ? item as? Data : nil, status)
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Crypto

/// Encrypts stored passwords with an AES-256 key that lives in the login Keychain,
/// so the on-disk JSON never contains a readable password.
struct Vault {
    private let key: SymmetricKey?

    /// Set when the key exists but could not be read — a denied Keychain prompt, a
    /// locked keychain. Distinct from "there is no key yet".
    let unavailableReason: String?

    var isAvailable: Bool { key != nil }

    init() {
        let (data, status) = Keychain.readWithStatus("vault-key")

        if let data, data.count == 32 {
            key = SymmetricKey(data: data)
            unavailableReason = nil
            return
        }

        switch status {
        case errSecItemNotFound:
            // Genuinely first run: mint a key.
            let fresh = SymmetricKey(size: .bits256)
            let raw = fresh.withUnsafeBytes { Data($0) }
            if Keychain.write(raw, account: "vault-key") {
                key = fresh
                unavailableReason = nil
            } else {
                key = nil
                unavailableReason = "Could not save the encryption key to your Keychain, so passwords cannot be stored."
            }

        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
            // The key exists but is not readable right now. Minting a replacement here
            // would overwrite it and make every stored password unrecoverable.
            key = nil
            unavailableReason = "League Vault was denied access to its Keychain key, so saved passwords can't be read. Quit and reopen, and choose “Always Allow” when macOS asks. Nothing has been overwritten."

        default:
            key = nil
            unavailableReason = "Keychain error \(status) reading the encryption key. Saved passwords can't be read; nothing has been overwritten."
        }
    }

    func seal(_ plaintext: String) -> String? {
        guard !plaintext.isEmpty, let key else { return nil }
        guard let data = plaintext.data(using: .utf8),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    func open(_ sealed: String?) -> String? {
        guard let key else { return nil }
        guard let sealed, let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

// MARK: - Store

@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var loadError: String?

    private let vault = Vault()
    private let fileURL: URL

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LeagueVault", isDirectory: true)
    }

    /// Non-nil when passwords cannot be read or written this session.
    @Published var vaultWarning: String?

    init() {
        fileURL = Self.directory.appendingPathComponent("accounts.json")
        vaultWarning = vault.unavailableReason
        load()
    }

    var canStorePasswords: Bool { vault.isAvailable }

    // MARK: Persistence

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            var loaded = try Self.decoder().decode([Account].self, from: data)
            for i in loaded.indices { loaded[i].normalize() }
            accounts = loaded
        } catch {
            loadError = "Could not read your saved accounts: \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try Self.encoder().encode(accounts)
            try data.write(to: fileURL, options: .atomic)
            // The file holds encrypted passwords; still keep it owner-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Mutations

    func add(_ account: Account) {
        var a = account
        a.normalize()
        accounts.append(a)
        save()
    }

    func update(_ account: Account) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var a = account
        a.normalize()
        accounts[idx] = a
        save()
    }

    /// Renames a folder across every account. An empty `to` unfiles them.
    func renameFolder(from old: String, to new: String) {
        var changed = false
        for i in accounts.indices where accounts[i].folder == old {
            accounts[i].folder = new
            changed = true
        }
        if changed { save() }
    }

    func delete(id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    // MARK: Passwords

    func password(for account: Account) -> String? {
        vault.open(account.encryptedPassword)
    }

    func encrypt(_ password: String) -> String? {
        vault.seal(password)
    }

    // MARK: Export

    /// Plain-text export, passwords decrypted. Only written where the user chooses.
    func exportJSON(includePasswords: Bool) throws -> Data {
        struct Exported: Encodable {
            var label: String
            var folder: String
            var riotID: String
            var region: String
            var loginUsername: String
            var password: String?
            var ranks: [RankEntry]
            var lastGame: LastGame?
            var penalties: [Penalty]
            var notes: String
            var uggURL: String?
            var blueEssence: Int?
            var riotPoints: Int?
            var ownedChampions: [String]
            var summonerLevel: Int?
            var lastRefreshed: Date?
        }
        let rows = accounts.map { a in
            Exported(label: a.label,
                     folder: a.folder,
                     riotID: a.riotID,
                     region: a.region.display,
                     loginUsername: a.loginUsername,
                     password: includePasswords ? password(for: a) : nil,
                     ranks: a.ranks,
                     lastGame: a.lastGame,
                     penalties: a.penalties,
                     notes: a.notes,
                     uggURL: a.uggURL?.absoluteString,
                     blueEssence: a.blueEssence,
                     riotPoints: a.riotPoints,
                     ownedChampions: a.ownedChampions.map(\.name),
                     summonerLevel: a.summonerLevel,
                     lastRefreshed: a.lastRefreshed)
        }
        return try Self.encoder().encode(rows)
    }
}
