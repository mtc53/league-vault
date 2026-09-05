import Foundation
import CryptoKit
import CommonCrypto

// A backup is one self-describing file. Everything sensitive lives inside `payload`,
// sealed with a key derived from a passphrase — never from this Mac's Keychain — so a
// backup can be restored on a machine that has never seen this one.

struct BackupEnvelope: Codable {
    struct KDF: Codable {
        var algorithm: String = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: String            // base64
    }
    var format: String = BackupService.formatIdentifier
    var version: Int = 1
    var createdAt: Date
    var accountCount: Int
    var origin: String
    var cipher: String = "AES-256-GCM"
    var kdf: KDF
    var payload: String             // base64 AES-GCM combined box
}

/// One account as it travels: the record, plus its password in the clear *inside* the
/// sealed payload. That is what makes a backup restorable without the original Keychain.
struct PortableAccount: Codable {
    var account: Account
    var password: String?
}

struct BackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BackupService {
    static let formatIdentifier = "leaguevault-backup"
    static let fileExtension = "lvbackup"
    static let iterations = 210_000

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let length = derived.count
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase, passphrase.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    out.bindMemory(to: UInt8.self).baseAddress, length)
            }
        }
        guard status == kCCSuccess else {
            throw BackupError(message: "Could not derive a key from that passphrase (error \(status)).")
        }
        return SymmetricKey(data: derived)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func makeBackup(_ records: [PortableAccount], passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else {
            throw BackupError(message: "Set a backup passphrase first.")
        }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let plaintext = try encoder.encode(records)
        guard let sealed = try AES.GCM.seal(plaintext, using: key).combined else {
            throw BackupError(message: "Encryption failed.")
        }
        let envelope = BackupEnvelope(
            createdAt: Date(),
            accountCount: records.count,
            origin: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            kdf: .init(iterations: iterations, salt: salt.base64EncodedString()),
            payload: sealed.base64EncodedString())
        return try encoder.encode(envelope)
    }

    static func readBackup(_ data: Data, passphrase: String) throws -> (envelope: BackupEnvelope, records: [PortableAccount]) {
        guard let envelope = try? decoder.decode(BackupEnvelope.self, from: data) else {
            throw BackupError(message: "That file is not a League Vault backup.")
        }
        guard envelope.format == formatIdentifier else {
            throw BackupError(message: "Unexpected file format “\(envelope.format)”.")
        }
        guard envelope.version <= 1 else {
            throw BackupError(message: "This backup was written by a newer version of League Vault.")
        }
        guard let salt = Data(base64Encoded: envelope.kdf.salt),
              let sealedData = Data(base64Encoded: envelope.payload) else {
            throw BackupError(message: "The backup file is corrupt.")
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.kdf.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: sealedData),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            throw BackupError(message: "Wrong passphrase, or the backup has been altered.")
        }
        guard let records = try? decoder.decode([PortableAccount].self, from: plaintext) else {
            throw BackupError(message: "The backup decrypted but its contents could not be read.")
        }
        return (envelope, records)
    }

    /// Reads only the unencrypted header, for showing what a file is before asking for
    /// the passphrase.
    static func inspect(_ data: Data) -> BackupEnvelope? {
        guard let envelope = try? decoder.decode(BackupEnvelope.self, from: data),
              envelope.format == formatIdentifier else { return nil }
        return envelope
    }
}
