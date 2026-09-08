import Foundation

/// Renames the signed-in account to a name taken from the pool file.
///
/// Riot refuses a name for reasons only it knows — already taken, filtered, too soon
/// since the last change — so a refusal is retried with a *different* name. Two refusals
/// and it stops: a third is unlikely to behave differently, and burning through the pool
/// on a rate limit would be worse than leaving the account alone.
///
/// A request that comes back without an error has not necessarily taken effect, so every
/// attempt is checked by reading the account back a few seconds later. That also catches
/// the reverse case, where the call reports an error but the rename landed anyway.
enum AutoRename {

    struct Attempt {
        var name: String
        var succeeded: Bool
        /// Why it did not take. Nil on success.
        var reason: String?
    }

    struct Outcome {
        var renamedTo: PoolName?
        /// Every name tried, in order, for the log.
        var attempts: [Attempt] = []
        /// Set when the pool itself could not be used at all.
        var poolError: String?

        var didRename: Bool { renamedTo != nil }
    }

    static let maxAttempts = 2
    /// How long to let the client settle before reading the name back.
    static let verifyDelay: TimeInterval = 5

    static func run(credentials: LCUCredentials,
                    poolURL: URL,
                    stage: ((String) -> Void)? = nil) async -> Outcome {
        var outcome = Outcome()

        let pool: [PoolName]
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
        for attempt in 1...maxAttempts {
            // A different name each attempt, chosen at random so runs do not all march
            // down the file in the same order.
            let candidates = pool.filter { !tried.contains($0.line) }
            guard let pick = candidates.randomElement() else { break }
            tried.append(pick.line)

            stage?("Renaming to \(pick.riotID) (attempt \(attempt) of \(maxAttempts))…")
            var requestError: String?
            do {
                try await LCU.changeRiotID(gameName: pick.gameName,
                                           tagLine: pick.tagLine,
                                           credentials: credentials)
            } catch {
                requestError = error.localizedDescription
            }

            // The client can accept the call and not apply it, so wait and read it back
            // rather than believing the response either way.
            stage?("Checking whether \(pick.riotID) took…")
            try? await Task.sleep(nanoseconds: UInt64(verifyDelay * 1_000_000_000))
            let check = await verify(pick, credentials: credentials)

            if check.applied {
                outcome.attempts.append(Attempt(name: pick.riotID, succeeded: true))
                outcome.renamedTo = pick
                // Used up — take it out of the file so it is never handed out again.
                do {
                    try NamePool.remove(pick, from: poolURL)
                } catch {
                    outcome.poolError = "Renamed, but the name could not be removed from the list: \(error.localizedDescription)"
                }
                return outcome
            }

            outcome.attempts.append(Attempt(name: pick.riotID, succeeded: false,
                                            reason: requestError ?? check.detail))
        }
        return outcome
    }

    /// Reads the account back and says whether it now carries the requested name.
    private static func verify(_ pick: PoolName,
                               credentials: LCUCredentials) async -> (applied: Bool, detail: String) {
        guard let me = try? await LCU.currentSummoner(credentials: credentials) else {
            return (false, "the account could not be read back to check")
        }
        let applied = me.gameName.compare(pick.gameName, options: .caseInsensitive) == .orderedSame
        return (applied, applied ? "" : "the name is still \(me.riotID)")
    }
}
