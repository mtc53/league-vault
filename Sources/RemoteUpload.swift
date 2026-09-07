import Foundation

extension Notification.Name {
    static let vaultDidChange = Notification.Name("LeagueVaultDidChange")
}

/// Uploads encrypted backups to a remote machine over SFTP.
///
/// SSH is used rather than a Windows file share because the server is remote: SMB over
/// the open internet is a bad idea, while OpenSSH ships with Windows 10 and authenticates
/// with a key instead of a password.
@MainActor
final class RemoteBackup: ObservableObject {
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled); reschedule() } }
    @Published var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var user: String { didSet { defaults.set(user, forKey: Keys.user) } }
    @Published var remotePath: String { didSet { defaults.set(remotePath, forKey: Keys.path) } }
    @Published var keyPath: String { didSet { defaults.set(keyPath, forKey: Keys.key) } }
    @Published var keepCount: Int { didSet { defaults.set(keepCount, forKey: Keys.keep) } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: Keys.interval); reschedule() } }

    @Published private(set) var lastUpload: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastFileName: String?
    @Published private(set) var isBusy = false
    @Published var log: [String] = []

    private enum Keys {
        static let enabled = "remoteEnabled", host = "remoteHost", port = "remotePort"
        static let user = "remoteUser", path = "remotePath", key = "remoteKeyPath"
        static let keep = "remoteKeep", interval = "remoteInterval", last = "remoteLastUpload"
    }

    private let defaults = UserDefaults.standard
    private weak var store: AccountStore?
    private var timer: Timer?
    private var debounce: Task<Void, Never>?

    static let defaultKeyPath = NSHomeDirectory() + "/.ssh/leaguevault_ed25519"

    init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        host = defaults.string(forKey: Keys.host) ?? ""
        port = defaults.object(forKey: Keys.port) as? Int ?? 22
        user = defaults.string(forKey: Keys.user) ?? ""
        remotePath = defaults.string(forKey: Keys.path) ?? "LeagueVaultBackups"
        keyPath = defaults.string(forKey: Keys.key) ?? Self.defaultKeyPath
        keepCount = max(1, defaults.object(forKey: Keys.keep) as? Int ?? 20)
        intervalMinutes = defaults.object(forKey: Keys.interval) as? Int ?? 360
        lastUpload = defaults.object(forKey: Keys.last) as? Date
    }

    /// Passphrase lives in the Keychain so unattended uploads can run.
    var passphrase: String? {
        get {
            guard let data = Keychain.read("backup-passphrase") else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(Data(newValue.utf8), account: "backup-passphrase")
            } else {
                Keychain.delete("backup-passphrase")
            }
        }
    }

    var isConfigured: Bool {
        !host.isEmpty && !user.isEmpty && !(passphrase ?? "").isEmpty
            && FileManager.default.fileExists(atPath: keyPath)
    }

    var hasKey: Bool { FileManager.default.fileExists(atPath: keyPath) }

    /// Where the files actually land, spelled out in Windows terms. An SFTP session on
    /// Windows OpenSSH starts in the user's profile folder, so a relative path hangs off
    /// C:\Users\<user>. An absolute path is passed through as typed.
    var resolvedWindowsPath: String {
        let folder = remotePath.trimmingCharacters(in: .whitespaces)
        if folder.isEmpty { return "C:\\Users\\\(user.isEmpty ? "<username>" : user)" }
        // Already absolute: C:\..., C:/... or /C:/...
        let looksAbsolute = folder.contains(":") || folder.hasPrefix("/")
        if looksAbsolute {
            return folder.replacingOccurrences(of: "/", with: "\\")
        }
        let user = self.user.isEmpty ? "<username>" : self.user
        return "C:\\Users\\\(user)\\" + folder.replacingOccurrences(of: "/", with: "\\")
    }

    var publicKey: String {
        (try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Wiring

    func attach(to store: AccountStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .vaultDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleDebounced() }
        }
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard isEnabled, intervalMinutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.upload(reason: "scheduled") }
        }
    }

    /// A burst of edits should be one upload, not twenty.
    private func scheduleDebounced() {
        guard isEnabled, isConfigured else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.upload(reason: "vault changed")
        }
    }

    // MARK: SSH

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

    /// sftp wants forward slashes even when talking to Windows.
    private var sftpPath: String {
        let folder = remotePath.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "/")
        return folder.isEmpty ? "." : folder
    }

    /// Builds a folder, one level at a time, so a nested path works too. Each mkdir is
    /// prefixed with "-" so an existing folder is not treated as a failure.
    func makeRemoteDirectory(path: String, target: String) -> (status: Int32, output: String) {
        guard path != "." else { return (0, "") }

        var built: [String] = []
        var prefix = ""
        for segment in path.split(separator: "/") {
            // Keep a drive letter attached to the first real segment: C:/Backups.
            prefix = prefix.isEmpty ? String(segment) : prefix + "/" + String(segment)
            if prefix.hasSuffix(":") { continue }        // "C:" alone is not a folder
            built.append("-mkdir \"\(prefix)\"")
        }
        return runSFTPBatch(built, target: target)
    }

    /// Runs an sftp batch. sftp's "-b -" reads from stdin, which a GUI app does not
    /// have, so the commands go through a real file every time.
    func runSFTPBatch(_ lines: [String], target: String? = nil) -> (status: Int32, output: String) {
        guard !lines.isEmpty else { return (0, "") }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-sftp-\(UUID().uuidString)")
        guard (try? (lines + ["bye"]).joined(separator: "\n")
                .write(to: script, atomically: true, encoding: .utf8)) != nil
        else { return (-1, "could not stage the sftp batch") }
        defer { try? FileManager.default.removeItem(at: script) }

        return run("/usr/bin/sftp", sftpOptions + ["-b", script.path, target ?? sshTarget])
    }

    /// The user@host every part of the server integration talks to.
    var sshTarget: String { "\(user)@\(host)" }

    /// True once there is somewhere to send files and a key to send them with. The
    /// backup passphrase is not part of this — the dashboard does not need one.
    var hasServerAccess: Bool { !host.isEmpty && !user.isEmpty && hasKey }

    /// Shared with both tools; only the port flag differs between them.
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

    /// Creates the keypair if it does not exist yet.
    @discardableResult
    func createKeyIfNeeded() -> String {
        if hasKey { return publicKey }
        let dir = (keyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // No passphrase on the key: uploads have to run unattended. The key only grants
        // access to this one backup folder on the server.
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
        guard !host.isEmpty, !user.isEmpty else { lastError = "Fill in the server address and username."; return false }

        let target = "\(user)@\(host)"
        log.append("ssh \(target) …")
        let probe = run("/usr/bin/ssh", sshOptions + [target, "echo", "leaguevault-ok"])
        log.append(probe.output.trimmingCharacters(in: .whitespacesAndNewlines))

        guard probe.status == 0, probe.output.contains("leaguevault-ok") else {
            lastError = describeFailure(probe.output)
            return false
        }
        lastError = nil
        log.append("Connected. Creating \(resolvedWindowsPath) if it is not there…")

        let mk = makeRemoteDirectory(path: sftpPath, target: target)
        // "-mkdir" swallows "already exists"; anything else is worth surfacing.
        if mk.status != 0 {
            lastError = "Connected, but the folder could not be created: \(describeFailure(mk.output))"
            log.append(mk.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        log.append("Folder ready. Backups will be written to \(resolvedWindowsPath).")
        return true
    }

    /// Turns ssh's output into something actionable.
    func describeFailure(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("usage: sftp") || text.contains("usage: ssh") {
            return "League Vault built a bad command line — this is a bug in the app, not a problem with your server. Please report it."
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

    // MARK: Uploading

    @discardableResult
    func upload(reason: String) async -> Bool {
        guard let store, !isBusy else { return false }
        guard let passphrase, !passphrase.isEmpty else { lastError = "No backup passphrase set."; return false }
        guard hasKey else { lastError = "No SSH key yet — press Create key."; return false }
        guard !host.isEmpty, !user.isEmpty else { lastError = "Server address and username are required."; return false }

        isBusy = true
        defer { isBusy = false }

        do {
            let records = store.accounts.map {
                var stripped = $0
                stripped.encryptedPassword = nil     // the portable copy carries it instead
                return PortableAccount(account: stripped, password: store.password(for: $0))
            }
            let data = try BackupService.makeBackup(records, passphrase: passphrase)

            let stamp = Self.stampFormatter.string(from: Date())
            let name = "LeagueVault-\(stamp).\(BackupService.fileExtension)"
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: staged, options: .atomic)
            defer { try? FileManager.default.removeItem(at: staged) }

            let target = "\(user)@\(host)"
            let remoteDir = sftpPath

            // Make sure the folder exists — including every level of a nested path —
            // before writing into it.
            _ = makeRemoteDirectory(path: sftpPath, target: target)

            // Upload under a temporary name and rename on success, so a dropped
            // connection never leaves a half-written backup behind.
            let batch = """
            put "\(staged.path)" "\(remoteDir)/\(name).part"
            rename "\(remoteDir)/\(name).part" "\(remoteDir)/\(name)"
            put "\(staged.path)" "\(remoteDir)/LeagueVault-latest.\(BackupService.fileExtension)"
            bye
            """
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("lv-sftp-batch")
            try batch.write(to: script, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: script) }

            let result = run("/usr/bin/sftp", sftpOptions + ["-b", script.path, target])
            guard result.status == 0 else {
                lastError = "\(reason.capitalized) upload failed: \(describeFailure(result.output))"
                return false
            }

            prune(target: target, directory: remoteDir)
            lastUpload = Date()
            defaults.set(lastUpload, forKey: Keys.last)
            lastFileName = name
            lastError = nil
            return true
        } catch {
            lastError = "\(reason.capitalized) upload failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes all but the newest `keepCount` timestamped files, leaving -latest alone.
    private func prune(target: String, directory: String) {
        // `dir` on Windows, `ls` elsewhere: ask the shell for whichever works.
        var listing = run("/usr/bin/ssh", sshOptions + [target, "ls", directory])
        if listing.status != 0 || listing.output.isEmpty {
            listing = run("/usr/bin/ssh", sshOptions + [target, "dir", "/b", directory.replacingOccurrences(of: "/", with: "\\")])
        }
        guard listing.status == 0 else { return }

        let files = listing.output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("LeagueVault-") && $0.hasSuffix(".\(BackupService.fileExtension)") }
            .filter { !$0.contains("latest") }
            .sorted(by: >)          // the timestamp is in the name, so this is newest-first

        guard files.count > keepCount else { return }
        for old in files.dropFirst(keepCount) {
            _ = run("/usr/bin/ssh", sshOptions + [target, "rm", "\(directory)/\(old)"])
        }
    }

    // MARK: Restore

    /// Pulls the newest backup off the server and hands back its records.
    func fetchLatest(passphrase: String) async throws -> (envelope: BackupEnvelope, records: [PortableAccount]) {
        guard hasKey, !host.isEmpty, !user.isEmpty else {
            throw BackupError(message: "Set the server address, username and key first.")
        }
        let target = "\(user)@\(host)"
        let remoteDir = sftpPath
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-restore.\(BackupService.fileExtension)")
        try? FileManager.default.removeItem(at: local)

        let batch = """
        get "\(remoteDir)/LeagueVault-latest.\(BackupService.fileExtension)" "\(local.path)"
        bye
        """
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("lv-sftp-get")
        try batch.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = run("/usr/bin/sftp", sftpOptions + ["-b", script.path, target])
        guard result.status == 0, let data = try? Data(contentsOf: local) else {
            throw BackupError(message: describeFailure(result.output))
        }
        defer { try? FileManager.default.removeItem(at: local) }
        return try BackupService.readBackup(data, passphrase: passphrase)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = .current
        return f
    }()
}
