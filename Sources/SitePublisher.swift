import Foundation

// Publishing an aggregate snapshot of the vault to myprojects.cc.
//
// The public hub is read-only and has no password, so nothing identifying goes
// to it: no account names, no logins, no Riot IDs — only counts. The full
// per-account dashboard is a separate, private thing (see WebDashboard), and
// this never touches it. What leaves here is the same headline the window's
// hero row shows, and nothing more.

/// The counts the public page shows. No per-account data, by design.
struct VaultSummary {
    var accounts: Int
    var ranked: Int
    var championsOwned: Int
    var blueEssence: Int
    var riotPoints: Int
    var idle90: Int
    var withPenalty: Int
    var flagged: Int

    init(_ accounts: [Account]) {
        self.accounts = accounts.count
        ranked = accounts.filter {
            $0.soloRank.tier != .unranked || $0.flexRank.tier != .unranked
        }.count
        championsOwned = accounts.reduce(0) { $0 + $1.ownedChampions.count }
        blueEssence = accounts.reduce(0) { $0 + ($1.blueEssence ?? 0) }
        riotPoints = accounts.reduce(0) { $0 + ($1.riotPoints ?? 0) }
        idle90 = accounts.filter(\.isDormant).count
        withPenalty = accounts.filter { !$0.activePenalties.isEmpty }.count
        flagged = accounts.filter(\.isFlagged).count
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private func n(_ v: Int) -> String {
        Self.grouping.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// The site's data contract (see DATA_CONTRACT.md in myprojects-site).
    func contract(title: String) -> [String: Any] {
        let fmt = ISO8601DateFormatter()
        return [
            "project": "league",
            "title": title,
            "updated": fmt.string(from: Date()),
            "status": "ok",
            "summary": "\(n(accounts)) accounts — \(n(ranked)) ranked, "
                + "\(n(championsOwned)) champions owned.",
            "stats": [
                ["label": "Accounts", "value": n(accounts)],
                ["label": "Ranked", "value": n(ranked)],
                ["label": "Champions", "value": n(championsOwned)],
                ["label": "Blue essence", "value": n(blueEssence)],
                ["label": "RP", "value": n(riotPoints)],
                ["label": "Idle 90d", "value": n(idle90)],
                ["label": "Penalties", "value": n(withPenalty)],
                ["label": "Flagged", "value": n(flagged), "hint": "by the cycle"],
            ],
            "note": "Counts only — the detailed vault stays private.",
            "source": "https://github.com/mtc53/league-vault",
        ]
    }
}

enum SitePublisher {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fire a repository_dispatch so myprojects-site writes data/league.json and
    /// redeploys. `repo` is "owner/name"; `token` needs contents: write there.
    static func publish(summary: VaultSummary, title: String,
                        repo: String, token: String) async throws {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, !token.isEmpty else {
            throw Failure(message: "No site repository or token is set.")
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/dispatches") else {
            throw Failure(message: "“\(repo)” is not a valid owner/name.")
        }

        let body: [String: Any] = [
            "event_type": "publish-data",
            "client_payload": ["project": "league", "data": summary.contract(title: title)],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("league-vault", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "No response from GitHub.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw Failure(message: "GitHub returned \(http.statusCode). \(detail)")
        }
    }
}
