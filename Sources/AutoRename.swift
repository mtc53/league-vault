import Foundation

/// Renames the signed-in account to a name taken from the pool file.
///
/// Riot refuses a name for reasons only it knows — already taken, filtered, too soon
/// since the last change — so a refusal is retried with a *different* name. Two refusals
/// and it stops: a third is unlikely to behave differently, and burning through the pool
/// on a rate limit would be worse than leaving the account alone.
enum AutoRename {

    struct Outcome {
        var renamedTo: PoolName?
        /// Every name tried, with why it was refused, for the log.
        var refusals: [(name: String, reason: String)] = []
        /// Set when the pool itself could not be used at all.
        var poolError: String?

        var didRename: Bool { renamedTo != nil }
    }

    static let maxAttempts = 2

    static func run(credentials: LCUCredentials,
                    poolURL: URL,
                    stage: ((String) -> Void)? = nil) async -> Outcome {
        var outcome = Outcome()

        var pool: [PoolName]
        do {
            pool = try NamePool.load(from: poolURL)
        } catch {
            outcome.poolError = "Could not read the name list: \(error.localizedDescription)"
            return outcome
        }
        guard !pool.isEmpty else {
            outcome.poolError = "The name list is empty."
            return outcome
        }

        var tried: [String] = []
        for _ in 0..<maxAttempts {
            // A different name each attempt, chosen at random so runs do not all march
            // down the file in the same order.
            let candidates = pool.filter { !tried.contains($0.line) }
            guard let pick = candidates.randomElement() else { break }
            tried.append(pick.line)

            stage?("Renaming to \(pick.riotID)…")
            do {
                try await LCU.changeRiotID(gameName: pick.gameName,
                                           tagLine: pick.tagLine,
                                           credentials: credentials)
                outcome.renamedTo = pick
                // Used up — take it out of the file so it is never handed out again.
                do {
                    try NamePool.remove(pick, from: poolURL)
                } catch {
                    outcome.poolError = "Renamed, but the name could not be removed from the list: \(error.localizedDescription)"
                }
                return outcome
            } catch {
                outcome.refusals.append((pick.riotID, error.localizedDescription))
            }
        }
        return outcome
    }
}
