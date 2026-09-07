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

    /// Is someone signed in? The active-alias endpoint is authoritative: a 200 carrying a
    /// puuid means signed in, and a 200 without one (or a 4xx) means signed out — even if
    /// the access token lingers for a moment. Only when that request cannot be reached at
    /// all do we fall back to the access token, and then to unknown.
    static func sessionState(credentials: RCUCredentials) async -> SessionState {
        if let alias = await request("GET", "/player-account/aliases/v1/active", credentials: credentials) {
            if alias.status == 200,
               let object = try? JSONSerialization.jsonObject(with: alias.data) as? [String: Any],
               let puuid = object["puuid"] as? String, !puuid.isEmpty {
                return .signedIn(puuid: puuid)
            }
            return .signedOut
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
        openLauncher()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let creds = discover() { return creds }
        }
        return discover()
    }

    /// Opens the Riot Client to its login screen. Opening the app bundle is what actually
    /// shows the window — running RiotClientServices bare does not always.
    static func openLauncher() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: config) { _, _ in }
    }

    /// Whether the Riot Client app bundle is where we expect it.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: servicesBinary)
            || FileManager.default.fileExists(atPath: appPath)
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

    // MARK: Closing League

    /// Force-closes only the League client — never the Riot Client. Used to end a session
    /// before signing out at the Riot Client level.
    static func killLeague() {
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? ""
            let bid = (app.bundleIdentifier ?? "").lowercased()
            if name.hasPrefix("LeagueClient") || name.hasPrefix("League of Legends")
                || bid.contains("leagueoflegends") {
                app.terminate()
            }
        }
        // Backstop for the helper process NSWorkspace does not list. The pattern matches
        // only League, not the Riot Client.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "LeagueClientUx|LeagueClient.app/Contents"]
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: Signing out

    enum SignOutResult {
        case signedOut          // the endpoint logged the account out
        case alreadyOut         // nobody was signed in to begin with
        case failed(String)     // could not sign out; the client is left open and running

        var isClear: Bool {
            switch self { case .signedOut, .alreadyOut: return true; case .failed: return false }
        }
    }

    /// Every logout spelling that has shipped, tried together each round.
    private static let logoutEndpoints: [(String, String)] = [
        ("POST", "/rso-auth/v1/session/logout"),
        ("DELETE", "/rso-auth/v1/session"),
        ("POST", "/rso-auth/v2/session/logout"),
        ("DELETE", "/rso-auth/v2/session"),
        ("PUT", "/rso-auth/v1/authorization/logout"),
        ("POST", "/riot-login/v1/session/logout")
    ]

    /// Signs the current account out through the Riot Client's own logout, leaving the Riot
    /// Client running at its login screen — never force-quit. Fires every known logout
    /// endpoint each round and keeps retrying until the session is gone or the timeout
    /// passes, so a slow or fussy client still signs out. The failure message carries the
    /// status codes it saw, for diagnosis.
    static func signOut(timeout: TimeInterval = 30) async -> SignOutResult {
        guard let creds = discover() else { return .alreadyOut }   // not running → nobody in
        if case .signedOut = await sessionState(credentials: creds) { return .alreadyOut }

        var seen: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        var round = 0
        while Date() < deadline {
            round += 1
            for (method, path) in logoutEndpoints {
                let result = await request(method, path, credentials: creds)
                if round == 1 {
                    seen.append("\(method) \(path.split(separator: "/").last ?? "") → \(result.map { String($0.status) } ?? "no reply")")
                }
            }
            // Give the client a moment, then check.
            if await waitUntilSignedOut(credentials: creds, timeout: 4) { return .signedOut }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return .failed("The Riot Client would not sign out. Endpoints tried: \(seen.joined(separator: "; ")). It has been left open and running, as asked.")
    }

    /// Polls until the session is gone. `.unknown` (both endpoints silent) falls back to
    /// League having closed as evidence the account is out.
    private static func waitUntilSignedOut(credentials: RCUCredentials, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch await sessionState(credentials: credentials) {
            case .signedOut: return true
            case .signedIn:  break
            case .unknown:   if LCU.discover() == nil { return true }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return false
    }
}
