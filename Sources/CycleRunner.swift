import Foundation
import AppKit

// Signs into each account in turn, launches League, refreshes it, runs quick prep
// (icon + challenge reset, never friends), publishes the page, signs out, and moves on.
//
// Much of this drives the Riot Client — a separate program — with synthetic keystrokes
// and its undocumented local API. Those steps cannot be made bulletproof: a captcha, a
// 2FA prompt, or an unfocused window will stall a sign-in. So every wait has a deadline,
// every account is independent, and the whole run stops on command. An account that
// stalls is marked failed and the cycle carries on to the next one.

@MainActor
final class CycleRunner: ObservableObject {

    enum Stage: String {
        case queued        = "Queued"
        case signingOut    = "Signing out the last account"
        case openingClient = "Opening the Riot Client"
        case signingIn     = "Signing in"
        case launchingLeague = "Launching League"
        case waitingForClient = "Waiting for the League client"
        case refreshing    = "Refreshing"
        case quickPrep     = "Quick prep"
        case publishing    = "Publishing"
        case done          = "Done"
        case failed        = "Failed"
        case skipped       = "Skipped"
    }

    struct Item: Identifiable {
        let id: UUID           // the account id
        var name: String
        var stage: Stage = .queued
        var detail: String = ""

        var isTerminal: Bool { stage == .done || stage == .failed || stage == .skipped }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentIndex: Int?
    @Published private(set) var log: [String] = []

    // Timeouts, generous because the client is slow to come up.
    private struct Timeout {
        static let clientUp: TimeInterval = 45      // Riot Client API answers
        static let signIn: TimeInterval = 60        // RSO session appears after submit
        static let leagueUp: TimeInterval = 120     // LCU answers with a summoner
        static let signOut: TimeInterval = 25
    }

    private weak var store: AccountStore?
    private weak var web: WebDashboard?
    private weak var watcher: ClientWatcher?
    private var task: Task<Void, Never>?

    func attach(store: AccountStore, web: WebDashboard, watcher: ClientWatcher) {
        self.store = store
        self.web = web
        self.watcher = watcher
    }

    /// Accounts that can be cycled: a login and a stored password to sign in with.
    func eligibleAccounts() -> [Account] {
        guard let store else { return [] }
        return store.accounts.filter {
            !$0.loginUsername.isEmpty && store.password(for: $0) != nil
        }
    }

    var eligibleCount: Int { eligibleAccounts().count }

    // MARK: Control

    func start(iconId: Int, setIcon: Bool, clearChallenges: Bool) {
        guard !isRunning, store != nil, let watcher else { return }
        guard Autofill.isPermitted else {
            note("Accessibility permission is off — League Vault cannot type the login. Grant it in the Sign in sheet, then start again.")
            return
        }
        let queue = eligibleAccounts()
        guard !queue.isEmpty else { note("No accounts have both a login and a saved password."); return }

        items = queue.map { Item(id: $0.id, name: $0.displayName) }
        log = []
        isRunning = true
        watcher.suspend()

        task = Task { [weak self] in
            await self?.run(queue: queue, iconId: iconId, setIcon: setIcon, clearChallenges: clearChallenges)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        finish(interrupted: true)
    }

    private func finish(interrupted: Bool) {
        isRunning = false
        currentIndex = nil
        watcher?.resume()
        if interrupted {
            for i in items.indices where !items[i].isTerminal {
                items[i].stage = .skipped
                items[i].detail = "Stopped."
            }
            note("Stopped.")
        }
    }

    // MARK: The cycle

    private func run(queue: [Account], iconId: Int, setIcon: Bool, clearChallenges: Bool) async {
        note("Starting a cycle of \(queue.count) account\(queue.count == 1 ? "" : "s").")

        for (index, account) in queue.enumerated() {
            if Task.isCancelled { break }
            currentIndex = index

            guard let password = store?.password(for: account) else {
                set(index, .skipped, "No saved password.")
                continue
            }

            do {
                try await cycleOne(index: index, account: account,
                                   username: account.loginUsername, password: password,
                                   iconId: iconId, setIcon: setIcon, clearChallenges: clearChallenges)
                set(index, .done, "")
            } catch is CancellationError {
                break
            } catch let error as StepError {
                set(index, .failed, error.message)
                note("\(account.displayName): \(error.message)")
                // Best effort: sign this account out before the next one. Never quits.
                _ = await RiotClient.signOut()
            } catch {
                set(index, .failed, error.localizedDescription)
            }
        }

        // Tidy up: sign the last account out so nothing is left logged in.
        if !Task.isCancelled {
            set(nil, .signingOut, "")
            _ = await RiotClient.signOut()
        }
        finish(interrupted: Task.isCancelled)
        if !Task.isCancelled { note("Cycle complete.") }
    }

    struct StepError: Error { let message: String }

    private func cycleOne(index: Int, account: Account,
                          username: String, password: String,
                          iconId: Int, setIcon: Bool, clearChallenges: Bool) async throws {
        // 1. Sign out whoever is signed in, leaving the Riot Client open at its login
        //    screen. The client is never force-quit.
        set(index, .openingClient, "")
        guard let rcu = await RiotClient.ensureRunning(timeout: Timeout.clientUp) else {
            throw StepError(message: "The Riot Client did not start.")
        }
        try checkCancel()

        set(index, .signingOut, "Signing out the last account")
        let signOut = await RiotClient.signOut(timeout: Timeout.signOut)
        if case .failed(let why) = signOut { throw StepError(message: why) }
        try checkCancel()
        // Let the login screen settle and take focus before typing at it.
        try await sleep(4)

        // 2. Bring the Riot Client forward and type into it. A freshly launched client
        //    can take a few seconds before its window will accept focus, so keep trying.
        set(index, .signingIn, "Focusing the Riot Client")
        var focused = false
        for attempt in 0..<6 {
            if Autofill.focusRiotClient() { focused = true; break }
            try checkCancel()
            set(index, .signingIn, "Waiting for the Riot Client window (\(attempt + 1))")
            try await sleep(2.5)
        }
        guard focused else {
            throw StepError(message: "Could not bring the Riot Client forward to type into it. Is its window open on this Space?")
        }

        set(index, .signingIn, "Typing the login")
        try await sleep(1)
        Autofill.signIn(username: username, password: password)

        // 3. Wait for the RSO session to appear.
        set(index, .signingIn, "Waiting for sign-in")
        try await waitForSignIn(rcu: rcu)

        // 4. Launch League and wait for its client to answer.
        set(index, .launchingLeague, "")
        RiotClient.launchLeague()
        set(index, .waitingForClient, "")
        let credentials = try await waitForLeague()

        // 5. Refresh — link the signed-in summoner to this queue entry.
        set(index, .refreshing, "")
        let summonerName = try await refreshInto(account: account, credentials: credentials)
        setName(index, summonerName)

        // 6. Quick prep — icon and challenge reset, never friends.
        if setIcon || clearChallenges {
            set(index, .quickPrep, "")
            await runQuickPrep(credentials: credentials, iconId: iconId,
                               setIcon: setIcon, clearChallenges: clearChallenges, index: index)
        }

        // 7. Publish, if the dashboard is set up.
        if let web, web.isEnabled, web.isConfigured {
            set(index, .publishing, "")
            _ = await web.publish(reason: "account cycle")
        }
    }

    // MARK: Waits

    private func waitForSignIn(rcu: RCUCredentials) async throws {
        let deadline = Date().addingTimeInterval(Timeout.signIn)
        while Date() < deadline {
            try checkCancel()
            // The RCU credentials can rotate when the client relaunches; rediscover.
            let creds = RiotClient.discover() ?? rcu
            if case .signedIn = await RiotClient.sessionState(credentials: creds) { return }
            // Sometimes League itself comes up first; treat that as signed in too.
            if LCU.discover() != nil { return }
            try await sleep(2)
        }
        throw StepError(message: "No sign-in after \(Int(Timeout.signIn))s — a captcha, 2FA, or the wrong window. Nothing was submitted twice.")
    }

    private func waitForLeague() async throws -> LCUCredentials {
        let deadline = Date().addingTimeInterval(Timeout.leagueUp)
        var relaunched = false
        while Date() < deadline {
            try checkCancel()
            if let creds = LCU.discover(),
               let me = try? await LCU.currentSummoner(credentials: creds), !me.puuid.isEmpty {
                return creds
            }
            // If League has not appeared halfway through, nudge it once more.
            if !relaunched, Date() > deadline.addingTimeInterval(-Timeout.leagueUp / 2) {
                RiotClient.launchLeague()
                relaunched = true
            }
            try await sleep(3)
        }
        throw StepError(message: "The League client did not come up in \(Int(Timeout.leagueUp))s.")
    }

    // MARK: Work

    private func refreshInto(account: Account, credentials: LCUCredentials) async throws -> String {
        let snapshot: LCU.Snapshot
        do {
            snapshot = try await LCU.snapshot(credentials: credentials)
        } catch {
            throw StepError(message: "Refresh failed: \(error.localizedDescription)")
        }
        guard let store, var current = store.accounts.first(where: { $0.id == account.id }) else {
            throw StepError(message: "The account went away mid-cycle.")
        }
        current.applySnapshot(snapshot)
        store.update(current)
        return current.displayName
    }

    private func runQuickPrep(credentials: LCUCredentials, iconId: Int,
                              setIcon: Bool, clearChallenges: Bool, index: Int) async {
        if setIcon {
            let owned = await LCU.ownedProfileIcons(credentials: credentials)
            let choice = QuickPrep.resolvedIcon(preferring: iconId, ownedIcons: owned)
            do {
                try await LCU.setProfileIcon(id: choice.id, credentials: credentials)
                note("\(items[index].name): icon set to \(choice.id)\(choice.fellBack ? " (fell back)" : "").")
            } catch {
                note("\(items[index].name): icon failed — \(error.localizedDescription)")
            }
        }
        if clearChallenges {
            let reset = await LCU.clearChallenges(credentials: credentials)
            note(reset.allSucceeded
                 ? "\(items[index].name): challenge badges cleared."
                 : "\(items[index].name): challenge reset was partly refused.")
        }
    }

    // MARK: Small helpers

    private func checkCancel() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func set(_ index: Int?, _ stage: Stage, _ detail: String) {
        if let index, items.indices.contains(index) {
            items[index].stage = stage
            items[index].detail = detail
        }
    }

    private func setName(_ index: Int, _ name: String) {
        if items.indices.contains(index) { items[index].name = name }
    }

    private func note(_ text: String) {
        log.append(text)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
