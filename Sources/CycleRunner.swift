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
        static let leagueUp: TimeInterval = 150     // LCU answers with a summoner
        static let signOut: TimeInterval = 25
        static let afterSignIn: TimeInterval = 10   // let the game view load before Play
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

    /// Isolates the keystroke path from the rest of the cycle: hides League Vault, brings
    /// the Riot Client forward, and types a marker so you can see whether anything lands.
    func selfTest() {
        guard !isRunning else { return }
        log = []
        note("Self-test starting.")
        note("Accessibility permission: \(Autofill.isPermitted ? "granted" : "OFF — this is almost certainly why nothing types")")
        note("Riot Client running: \(RiotClient.isRunning ? "yes" : "no")")
        Task { [weak self] in
            guard let self else { return }
            if !RiotClient.isRunning {
                self.note("Opening the Riot Client — put its login window on this desktop.")
                RiotClient.openLauncher()
                _ = await RiotClient.ensureRunning(timeout: 30)
            }
            self.note("Frontmost before: \(self.frontmostName())")
            self.hideSelf()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let focused = Autofill.focusRiotClient()
            self.note("focusRiotClient() = \(focused); frontmost now: \(self.frontmostName())")
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let pid = AXControl.riotPID() {
                let fields = await AXControl.loginFieldsWaiting(pid: pid)
                self.note("login fields — username: \(fields.username != nil ? "found" : "not found"), password: \(fields.password != nil ? "found" : "not found")")
                if let user = fields.username {
                    AXControl.click(in: user)
                    usleep(200_000)
                }
            } else {
                self.note("could not find the Riot Client process id.")
            }
            Autofill.type("LeagueVaultTest")
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.showSelf()
            self.note("Done. Did “LeagueVaultTest” land in the username box on its own this time?")
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
        note("Accessibility permission: \(Autofill.isPermitted ? "granted" : "OFF — keystrokes will do nothing")")
        note("Riot Client installed: \(RiotClient.isInstalled ? "yes" : "no — not found in /Applications")")

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
                try? await signOutCurrent(label: account.displayName)
            } catch {
                set(index, .failed, error.localizedDescription)
            }
        }

        // Tidy up: sign the last account out so nothing is left logged in.
        if !Task.isCancelled {
            set(nil, .signingOut, "")
            try? await signOutCurrent(label: "cleanup")
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
        note("[\(account.displayName)] opening the Riot Client…")
        guard let rcu = await RiotClient.ensureRunning(timeout: Timeout.clientUp) else {
            note("[\(account.displayName)] Riot Client API never answered (port \(RiotClient.discover().map { String($0.port) } ?? "none")).")
            throw StepError(message: "The Riot Client did not start, or its API never came up.")
        }
        note("[\(account.displayName)] Riot Client up on port \(rcu.port).")
        try checkCancel()

        set(index, .signingOut, "Signing out the last account")
        try await signOutCurrent(label: account.displayName)
        try checkCancel()
        // Let the login screen settle and take focus before typing at it.
        try await sleep(4)

        // 2. Bring the Riot Client forward and type into it. League Vault must not be
        //    frontmost when the keystrokes fire, or they land in our own window — its
        //    modal sheet keeps it key otherwise, which is why nothing was typed. So hide
        //    League Vault for the brief typing window, then bring it back.
        set(index, .signingIn, "Focusing the Riot Client")
        hideSelf()
        try await sleep(0.6)

        var focused = false
        for attempt in 0..<6 {
            if Autofill.focusRiotClient() { focused = true; break }
            if Task.isCancelled { showSelf(); throw CancellationError() }
            note("[\(account.displayName)] focus attempt \(attempt + 1) failed — frontmost is \(frontmostName()).")
            set(index, .signingIn, "Waiting for the Riot Client window (\(attempt + 1))")
            try await sleep(2.5)
        }
        guard focused else {
            showSelf()
            throw StepError(message: "Could not bring the Riot Client forward to type into it. Is its window open on the same desktop as League Vault?")
        }

        // No published updates between confirming focus and typing — a redraw can pull
        // focus back to us.
        note("[\(account.displayName)] Riot Client focused (frontmost: \(frontmostName())). Locating the login fields…")
        try await sleep(0.5)
        await typeLogin(username: username, password: password, label: account.displayName)
        try await sleep(0.4)
        showSelf()
        set(index, .signingIn, "Typed — waiting for sign-in")

        // 3. Wait for the RSO session to appear.
        set(index, .signingIn, "Waiting for sign-in")
        try await waitForSignIn(rcu: rcu)

        // 4. Click Play in the Riot Client to launch League, then wait for its client.
        set(index, .launchingLeague, "Clicking Play")
        await launchLeague(label: account.displayName)
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

    /// Puts the caret in the username field by clicking it — focusing the window is not
    /// enough for an Electron form — then types, clicks the password field (or Tabs to it
    /// if it could not be located), types that, and submits.
    private func typeLogin(username: String, password: String, label: String) async {
        guard let pid = AXControl.riotPID() else {
            note("[\(label)] could not find the Riot Client process for the click. Typing blind.")
            Autofill.signIn(username: username, password: password)
            return
        }
        let fields = await AXControl.loginFieldsWaiting(pid: pid)

        if let user = fields.username {
            note("[\(label)] clicking the username field.")
            AXControl.click(in: user)
            usleep(200_000)
            Autofill.clearField()
            Autofill.type(username)

            if let pass = fields.password {
                AXControl.click(in: pass)
                usleep(200_000)
                Autofill.clearField()
                Autofill.type(password)
            } else {
                note("[\(label)] no password field found — Tabbing from the username field.")
                Autofill.pressTab()
                Autofill.type(password)
            }
            usleep(150_000)
            Autofill.pressReturn()
        } else {
            note("[\(label)] the login fields were not exposed by the client — typing blind after a Tab.")
            Autofill.pressTab()
            Autofill.signIn(username: username, password: password)
        }
    }

    /// Signs whoever is signed in out, without ever quitting the Riot Client. If League is
    /// up it is done through the League client (which returns to the Riot Client login);
    /// otherwise through the Riot Client's own logout.
    /// Ends the current session: closes the League client (never the Riot Client), then
    /// signs the account out at the Riot Client level, leaving it open at its login screen.
    private func signOutCurrent(label: String) async throws {
        if let lcu = LCU.discover() {
            note("[\(label)] closing the League client…")
            _ = await LCU.quitClient(credentials: lcu)
            var gone = await waitUntil(timeout: Timeout.signOut) { LCU.discover() == nil }
            if !gone {
                note("[\(label)] League did not close on request — forcing it.")
                RiotClient.killLeague()
                gone = await waitUntil(timeout: Timeout.signOut) { LCU.discover() == nil }
            }
            note(gone ? "[\(label)] League closed." : "[\(label)] League still running after a forced close.")
        }

        // Sign the account out at the Riot Client, which stays open at its login screen.
        let result = await RiotClient.signOut(timeout: Timeout.signOut)
        note("[\(label)] Riot Client sign-out: \(describe(result))")
        if case .failed(let why) = result {
            note("[\(label)] \(why)")
        }
        // Let the Riot Client settle back on its login screen before the next account.
        try await sleep(3)
    }

    /// Clicks the Riot Client's Play button to launch League. Waits first, because the
    /// button appears before the client is ready and an early click does nothing, then
    /// clicks and verifies League actually starts (its client appears), clicking again if
    /// it did not. Falls back to the RiotClientServices launch arguments as a last resort.
    private func launchLeague(label: String) async {
        // Let the Riot Client finish loading its game view after sign-in.
        set(nil, .launchingLeague, "Letting the client finish loading")
        try? await sleep(Timeout.afterSignIn)

        guard let pid = AXControl.riotPID() else {
            RiotClient.launchLeague(); return
        }

        for attempt in 0..<8 {
            if LCU.discover() != nil {
                note("[\(label)] League is starting.")
                return
            }
            if AXControl.clickControl(pid: pid, words: ["play"]) {
                note("[\(label)] clicked Play (attempt \(attempt + 1)).")
            } else {
                note("[\(label)] Play button not visible yet (attempt \(attempt + 1)).")
            }
            set(nil, .launchingLeague, "Launching League (\(attempt + 1))")
            // Give the click time to register and League a chance to begin launching
            // before deciding it did not take.
            try? await sleep(6)
        }

        if LCU.discover() == nil {
            note("[\(label)] Play did not start League — launching directly.")
            RiotClient.launchLeague()
        }
    }

    /// Polls `condition` until it is true or the deadline passes.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return condition()
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
        store.update(current)     // writes accounts.json

        // Spell out what landed in the vault so the refresh is visibly confirmed.
        let solo = current.soloRank.shortDisplay
        let champs = current.ownedChampions.count
        let be = current.blueEssence.map { "\($0.grouped) BE" } ?? "BE ?"
        note("[\(current.displayName)] refreshed into the vault — \(current.riotID), level \(current.summonerLevel.map(String.init) ?? "?"), \(solo), \(champs) champs, \(be).")
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

    private func describe(_ r: RiotClient.SignOutResult) -> String {
        switch r {
        case .signedOut:    return "logged out via the client"
        case .alreadyOut:   return "nobody was signed in"
        case .failed(let m): return "failed — \(m)"
        }
    }

    private func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    }

    // MARK: Our own window

    /// Hide League Vault so synthetic keystrokes go to the Riot Client, not to us.
    private func hideSelf() { NSApplication.shared.hide(nil) }

    /// Bring League Vault back so its progress list is visible again.
    private func showSelf() {
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
