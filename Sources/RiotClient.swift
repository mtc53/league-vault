import Foundation
import AppKit

// The Riot Client (RCU) is the launcher that signs you in; the League client (LCU) is
// the game client it then starts. They are separate processes with separate local APIs.
// This talks to the Riot Client: it reports whether anyone is signed in, signs them out,
// and launches League. Like the LCU, it is undocumented and unsupported — every call
// degrades to a process-level fallback rather than throwing.

struct RCUCredentials {
    let port: Int
    let password: String

    var baseURL: String { "https://127.0.0.1:\(port)" }
    var authorizationHeader: String {
        "Basic " + Data("riot:\(password)".utf8).base64EncodedString()
    }
}

enum RiotClient {
    private static let delegate = LoopbackTrustDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    static let appPath = "/Applications/Riot Client.app"
    static let servicesBinary = appPath + "/Contents/MacOS/RiotClientServices"

    private static var lockfilePath: String {
        NSHomeDirectory() + "/Library/Application Support/Riot Games/Riot Client/Config/lockfile"
    }

    // MARK: Discovery

    /// The Riot Client writes `name:pid:port:password:protocol` to a lockfile while it
    /// runs, and deletes it on quit. That is the port and password for its local API.
    static func discover() -> RCUCredentials? {
        if let creds = fromLockfile() { return creds }
        return fromProcessList()
    }

    private static func fromLockfile() -> RCUCredentials? {
        guard let text = try? String(contentsOfFile: lockfilePath, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count >= 4, let port = Int(parts[2]) else { return nil }
        return RCUCredentials(port: port, password: String(parts[3]))
    }

    /// Some builds also carry the port and token on the command line; a backstop for when
    /// the lockfile has not been written yet.
    private static func fromProcessList() -> RCUCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-xww", "-o", "args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n")
        where line.contains("Riot Client") && line.contains("--app-port=") {
            let text = String(line)
            guard let port = capture(#"--app-port=(\d+)"#, in: text).flatMap(Int.init),
                  let token = capture(#"--remoting-auth-token=([\w-]+)"#, in: text) else { continue }
            return RCUCredentials(port: port, password: token)
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Requests

    @discardableResult
    private static func request(_ method: String, _ path: String,
                                body: [String: Any]? = nil,
                                credentials: RCUCredentials,
                                timeout: TimeInterval = 8) async -> (status: Int, data: Data)? {
        guard let url = URL(string: credentials.baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    // MARK: State

    /// Whether a process named like the Riot Client is running at all.
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").hasPrefix("Riot Client")
                || ($0.bundleIdentifier ?? "").contains("riotgames")
        }
    }

    enum SessionState { case signedIn(puuid: String), signedOut, unknown }

    /// Is someone signed in? The access-token endpoint answers 200 with a token once the
    /// RSO session exists, and 404/4xx before that.
    static func sessionState(credentials: RCUCredentials) async -> SessionState {
        if let alias = await request("GET", "/player-account/aliases/v1/active", credentials: credentials),
           alias.status == 200,
           let object = try? JSONSerialization.jsonObject(with: alias.data) as? [String: Any],
           let puuid = object["puuid"] as? String, !puuid.isEmpty {
            return .signedIn(puuid: puuid)
        }
        if let token = await request("GET", "/rso-auth/v1/authorization/access-token", credentials: credentials) {
            return token.status == 200 ? .signedIn(puuid: "") : .signedOut
        }
        return .unknown
    }

    // MARK: Launching

    /// Brings the Riot Client up (login window) if it is not already running. Returns once
    /// its local API answers, or after the timeout.
    @discardableResult
    static func ensureRunning(timeout: TimeInterval = 40) async -> RCUCredentials? {
        if let creds = discover() { return creds }

        // RiotClientServices with no product opens the launcher to the login screen.
        launch([])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let creds = discover() { return creds }
        }
        return discover()
    }

    /// Starts League for the signed-in account. Uses RiotClientServices' documented launch
    /// arguments, which is more dependable than any single RCU endpoint.
    static func launchLeague() {
        launch(["--launch-product=league_of_legends", "--launch-patchline=live"])
    }

    private static func launch(_ arguments: [String]) {
        guard FileManager.default.fileExists(atPath: servicesBinary) else {
            // Last resort: let Launch Services open the app bundle.
            if let url = URL(string: "file://" + appPath) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: servicesBinary)
        process.arguments = arguments
        try? process.run()
    }

    // MARK: Signing out

    enum SignOutMethod { case endpoint, quit, alreadyOut }

    /// Tries the client's own logout first, then falls back to quitting the processes,
    /// which drops the session just as surely. Reports which one did it.
    static func signOut() async -> SignOutMethod {
        if let creds = discover() {
            // Two spellings have shipped over the years; either returning a success is fine.
            for (method, path) in [("POST", "/rso-auth/v1/session/logout"),
                                   ("DELETE", "/rso-auth/v1/session")] {
                if let result = await request(method, path, credentials: creds),
                   (200..<400).contains(result.status) {
                    // Give it a moment to actually tear the session down.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if case .signedIn = await sessionState(credentials: creds) {
                        break   // it claimed success but is still in — fall through to quit
                    }
                    return .endpoint
                }
            }
        }
        quitProcesses()
        return .quit
    }

    /// Force-quits the Riot Client and League. The next launch returns to the login screen.
    static func quitProcesses() {
        let names = ["LeagueClient", "LeagueClientUx", "Riot Client", "RiotClientServices",
                     "RiotClientUx", "RiotClientCrashHandler"]
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            let name = app.localizedName ?? ""
            if names.contains(where: { name.hasPrefix($0) }) {
                app.terminate()
            }
        }
        // A blunt backstop for helpers NSWorkspace does not list as applications.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "LeagueClientUx|RiotClientServices|RiotClientUx"]
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    /// True once nothing Riot-related is running any more.
    static func waitUntilQuit(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning && LCU.discover() == nil { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}
