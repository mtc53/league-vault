import Foundation

extension Notification.Name {
    static let vaultDidChange = Notification.Name("LeagueVaultDidChange")
}

/// Path shapes the Windows OpenSSH server expects.
///
/// Its SFTP subsystem exposes drives beneath a single root: `C:\LeagueVaultWeb` is
/// `/C:/LeagueVaultWeb` on the wire. Leave that leading slash off and the server reads
/// the whole thing as relative and hangs it off the login folder, which is how you end
/// up asking it for `/C:/Users/Administrator/C:/LeagueVaultWeb`.
enum SFTPPath {
    /// What to send to sftp: forward slashes, and a leading slash on any drive path.
    static func remote(_ raw: String) -> String {
        let folder = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "/")
        guard !folder.isEmpty else { return "." }
        if folder.hasPrefix("/") { return folder }      // already rooted
        return hasDriveLetter(folder) ? "/" + folder : folder
    }

    /// What to show the user: the path the way Explorer spells it. A relative path is
    /// resolved against the login folder, because that is where an SSH session starts.
    static func windows(_ raw: String, user: String) -> String {
        var folder = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "\\")
        guard !folder.isEmpty else { return "C:\\Users\\" + user }
        if folder.hasPrefix("\\") && hasDriveLetter(String(folder.dropFirst())) {
            folder.removeFirst()                        // "\C:\x" is really "C:\x"
        }
        if hasDriveLetter(folder) || folder.hasPrefix("\\\\") { return folder }
        return "C:\\Users\\" + user + "\\" + folder
    }

    /// "C:", "c:/x" — a drive letter, not a folder called something with a colon in it.
    private static func hasDriveLetter(_ path: String) -> Bool {
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":" else { return false }
        return chars[0].isLetter
    }
}

/// The SSH connection to your own machine, and nothing more: an address, a key, and
/// the two commands needed to put a file somewhere on it.
///
/// SSH rather than a Windows file share because the server is remote — SMB over the
/// open internet is a bad idea, while OpenSSH ships with Windows 10 and authenticates
/// with a key instead of a password.
@MainActor
final class RemoteServer: ObservableObject {
    @Published var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var user: String { didSet { defaults.set(user, forKey: Keys.user) } }
    @Published var keyPath: String { didSet { defaults.set(keyPath, forKey: Keys.key) } }

    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false
    @Published var log: [String] = []

    private enum Keys {
        static let host = "remoteHost", port = "remotePort"
        static let user = "remoteUser", key = "remoteKeyPath"
    }

    private let defaults = UserDefaults.standard

    static let defaultKeyPath = NSHomeDirectory() + "/.ssh/leaguevault_ed25519"

    init() {
        host = defaults.string(forKey: Keys.host) ?? ""
        port = defaults.object(forKey: Keys.port) as? Int ?? 22
        user = defaults.string(forKey: Keys.user) ?? ""
        keyPath = defaults.string(forKey: Keys.key) ?? Self.defaultKeyPath
    }

    // MARK: State

    var hasKey: Bool { FileManager.default.fileExists(atPath: keyPath) }

    /// The user@host every command is aimed at.
    var sshTarget: String { "\(user)@\(host)" }

    /// True once there is somewhere to send files and a key to send them with.
    var hasServerAccess: Bool { !host.isEmpty && !user.isEmpty && hasKey }

    var publicKey: String {
        (try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Running things

    /// Runs a command and returns its status and combined output.
    func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Shared by both tools; only the port flag differs between them.
    var commonOptions: [String] {
        ["-i", keyPath,
         "-o", "BatchMode=yes",              // never sit waiting for a password prompt
         "-o", "StrictHostKeyChecking=accept-new",
         "-o", "ConnectTimeout=15"]
    }

    /// ssh takes a lowercase -p for the port.
    var sshOptions: [String] { ["-p", String(port)] + commonOptions }

    /// sftp takes an uppercase -P; lowercase -p means "preserve timestamps" there, so
    /// passing ssh's flags to sftp makes it reject the whole command line.
    var sftpOptions: [String] { ["-P", String(port)] + commonOptions }

    /// Runs an sftp batch. sftp's "-b -" reads from stdin, which a GUI app does not
    /// have, so the commands go through a real file every time.
    func runSFTPBatch(_ lines: [String]) -> (status: Int32, output: String) {
        guard !lines.isEmpty else { return (0, "") }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-sftp-\(UUID().uuidString)")
        guard (try? (lines + ["bye"]).joined(separator: "\n")
                .write(to: script, atomically: true, encoding: .utf8)) != nil
        else { return (-1, "could not stage the sftp batch") }
        defer { try? FileManager.default.removeItem(at: script) }

        return run("/usr/bin/sftp", sftpOptions + ["-b", script.path, sshTarget])
    }

    /// Builds a folder, one level at a time, so a nested path works too. Each mkdir is
    /// prefixed with "-" so an existing folder is not treated as a failure.
    func makeRemoteDirectory(path: String) -> (status: Int32, output: String) {
        guard path != "." else { return (0, "") }

        // A server-absolute path keeps its leading slash on every level, or each mkdir
        // would be issued relative to the login folder instead.
        let root = path.hasPrefix("/") ? "/" : ""
        var built: [String] = []
        var prefix = ""
        for segment in path.split(separator: "/") {
            // Keep a drive letter attached to the first real segment: /C:/Web.
            prefix = prefix.isEmpty ? String(segment) : prefix + "/" + String(segment)
            if prefix.hasSuffix(":") { continue }        // "C:" alone is not a folder
            built.append("-mkdir \"\(root)\(prefix)\"")
        }
        return runSFTPBatch(built)
    }

    // MARK: Setup

    /// Creates the keypair if it does not exist yet.
    @discardableResult
    func createKeyIfNeeded() -> String {
        if hasKey { return publicKey }
        let dir = (keyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // No passphrase on the key: publishing has to run unattended, and the key only
        // reaches this one machine.
        let result = run("/usr/bin/ssh-keygen",
                         ["-t", "ed25519", "-N", "", "-C", "leaguevault", "-f", keyPath])
        if result.status != 0 { lastError = "Could not create the key: \(result.output)" }
        return publicKey
    }

    func testConnection() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        log = []

        guard hasKey else { lastError = "No SSH key yet — press Create key."; return false }
        guard !host.isEmpty, !user.isEmpty else {
            lastError = "Fill in the server address and username."
            return false
        }

        log.append("ssh \(sshTarget) …")
        let probe = run("/usr/bin/ssh", sshOptions + [sshTarget, "echo", "leaguevault-ok"])
        log.append(probe.output.trimmingCharacters(in: .whitespacesAndNewlines))

        guard probe.status == 0, probe.output.contains("leaguevault-ok") else {
            lastError = describeFailure(probe.output)
            return false
        }
        lastError = nil
        log.append("Connected.")
        return true
    }

    /// Turns ssh's output into something actionable.
    func describeFailure(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("usage: sftp") || text.contains("usage: ssh") {
            return "League Vault built a bad command line — this is a bug in the app, not a problem with your server. Please report it."
        }
        if text.contains("no such file or directory") {
            return "The server has no folder at that path. Create it on the Windows machine, or correct the folder setting — remember a plain name is taken relative to your Windows user folder."
        }
        if text.contains("permission denied") {
            return "The server refused the key. The public key is probably not in the right authorized_keys file on Windows — see the setup steps."
        }
        if text.contains("connection refused") {
            return "Nothing is listening on port \(port). OpenSSH Server may not be installed or started on the Windows machine."
        }
        if text.contains("timed out") || text.contains("operation timed out") {
            return "No answer from \(host):\(port). Check the address, and that the firewall allows the port."
        }
        if text.contains("could not resolve") {
            return "Could not find a machine called “\(host)”. Use its IP address if the name does not resolve."
        }
        if text.contains("host key verification failed") {
            return "The server's identity changed. Remove its line from ~/.ssh/known_hosts and try again."
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "The connection failed with no message."
            : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
