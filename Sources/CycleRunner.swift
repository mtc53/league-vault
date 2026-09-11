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
        static let signOut: TimeInterval = 30
        static let afterSignIn: TimeInterval = 10   // let the game view load before Play
        static let afterSignOut: TimeInterval = 10  // settle on the login screen before next
        /// How long the League client may answer without ever producing an account before
        /// it is judged to have opened blank. Timed from its first reply, not from launch.
        static let leagueUsable: TimeInterval = 15
    }

    /// How many times League is reopened when its client keeps coming up blank.
    private static let maxLaunchAttempts = 3
    /// How many times a login is submitted when the client reports a failed sign-in.
    private static let maxSignInAttempts = 2

    /// The League client came up but never loaded. Closing and reopening League fixes it,
    /// and the account stays signed in, so only the launch is repeated.
    private struct StuckClientError: Error {}

    /// The Riot Client answered the login with an error rather than a session.
    private struct SignInRejectedError: Error {}

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
    ///
    /// Deliberately checks that a password *exists* rather than decrypting it. This is read
    /// from a view body, which SwiftUI re-evaluates freely — decrypting every account there
    /// pinned the main thread, and with the key fetched lazily it could also raise a
    /// Keychain prompt mid-render. The decryption happens once, when the cycle actually
    /// runs; an entry whose password will not open is reported and skipped there.
    func eligibleAccounts() -> [Account] {
        guard let store else { return [] }
        return store.accounts.filter {
            !$0.loginUsername.isEmpty && !($0.encryptedPassword ?? "").isEmpty
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
            if let pid = RiotClient.launcherPID {
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

        // 2–3. Type the login and wait for the session. The client sometimes answers with
        //      "failed to sign in" for no good reason, so a rejection is tried once more.
        for attempt in 1...Self.maxSignInAttempts {
            try await submitLogin(index: index, account: account,
                                  username: username, password: password)
            do {
                set(index, .signingIn, "Waiting for sign-in")
                try await waitForSignIn(rcu: rcu, label: account.displayName)
                break
            } catch is SignInRejectedError {
                guard attempt < Self.maxSignInAttempts else {
                    throw StepError(message: "The Riot Client rejected the sign-in — it reported a failed sign-in \(Self.maxSignInAttempts) times.")
                }
                note("[\(account.displayName)] the client reported a failed sign-in — trying once more.")
                try await sleep(4)
            }
        }

        // 4. Click Play to launch League. A client that comes up blank never recovers, so
        //    close just League and open it again — the account stays signed in, so only
        //    this part repeats.
        var credentials: LCUCredentials?
        for attempt in 1...Self.maxLaunchAttempts {
            set(index, .launchingLeague, attempt == 1 ? "Clicking Play" : "Reopening League (\(attempt))")
            await launchLeague(label: account.displayName)
            set(index, .waitingForClient, "")
            do {
                credentials = try await waitForLeague(label: account.displayName)
                break
            } catch is StuckClientError {
                guard attempt < Self.maxLaunchAttempts else {
                    throw StepError(message: "The League client kept opening blank (\(Self.maxLaunchAttempts) tries).")
                }
                note("[\(account.displayName)] League opened but never loaded — closing it and opening it again.")
                await closeLeague(label: account.displayName)
                try await sleep(3)
            }
        }
        guard let credentials else {
            throw StepError(message: "The League client never became usable.")
        }

        // 5. Refresh — link the signed-in summoner to this queue entry.
        set(index, .refreshing, "")
        let summonerName = try await refreshInto(account: account, credentials: credentials)
        setName(index, summonerName)

        // 6. Quick prep — rename, icon, challenge reset and presence, never friends.
        if setIcon || clearChallenges || QuickPrep.renames || QuickPrep.appearsOffline {
            set(index, .quickPrep, "")
            let renamed = await runQuickPrep(credentials: credentials, iconId: iconId,
                                             setIcon: setIcon, clearChallenges: clearChallenges,
                                             index: index)
            // A rename changes the Riot ID the vault just recorded, so read it again.
            if renamed {
                set(index, .refreshing, "Re-reading the new Riot ID")
                try await sleep(2)
                let newName = try await refreshInto(account: account, credentials: credentials)
                setName(index, newName)
            }
        }

        // 7. Publish, if the dashboard is set up.
        if let web, web.isEnabled, web.isConfigured {
            set(index, .publishing, "")
            _ = await web.publish(reason: "account cycle")
        }
    }

    /// Brings the Riot Client forward, waits for its login form and types into it.
    ///
    /// League Vault must not be frontmost when the keystrokes fire, or they land in our own
    /// window — its modal sheet keeps it key otherwise. So League Vault hides for the brief
    /// typing window, then comes back.
    private func submitLogin(index: Int, account: Account,
                             username: String, password: String) async throws {
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

        note("[\(account.displayName)] Riot Client focused (frontmost: \(frontmostName())). Locating the login fields…")

        // The login form takes a while to rebuild after a sign-out, and until it exists
        // there is nothing to type into. Wait for it rather than typing blind.
        set(index, .signingIn, "Waiting for the login form")
        let fields = await waitForLoginForm(label: account.displayName)
        guard fields.found else {
            showSelf()
            throw StepError(message: "The Riot Client never showed its login form after signing out.")
        }

        // No published updates between confirming the form and typing — a redraw can pull
        // focus back to us.
        await typeLogin(fields: fields, username: username, password: password,
                        label: account.displayName)
        try await sleep(0.4)
        showSelf()
        set(index, .signingIn, "Typed — waiting for sign-in")
    }

    /// Closes the League client without touching the session, so the account stays signed
    /// in at the Riot Client and League can simply be opened again.
    private func closeLeague(label: String) async {
        guard let lcu = LCU.discover() else { return }
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

    /// Waits for the Riot Client's login form to actually exist. After a sign-out the
    /// client rebuilds it, and until then there are no fields to click — typing during that
    /// window goes nowhere. If it does not appear, the window is reopened and refocused
    /// once before giving up.
    private func waitForLoginForm(label: String) async -> AXControl.LoginFields {
        guard let pid = RiotClient.launcherPID else { return AXControl.LoginFields() }

        var fields = await AXControl.loginFieldsWaiting(pid: pid, attempts: 8)
        if fields.found { return fields }

        note("[\(label)] no login form yet — reopening the Riot Client window.")
        RiotClient.openLauncher()
        try? await sleep(3)
        _ = Autofill.focusRiotClient()
        try? await sleep(1)

        fields = await AXControl.loginFieldsWaiting(pid: pid, attempts: 8)
        if !fields.found {
            note("[\(label)] the login form never appeared.")
        }
        return fields
    }

    /// Puts the caret in the username field by clicking it — focusing the window is not
    /// enough for an Electron form — then types, clicks the password field (or Tabs to it
    /// if it could not be located), types that, and submits.
    private func typeLogin(fields: AXControl.LoginFields,
                           username: String, password: String, label: String) async {
        guard let user = fields.username else {
            note("[\(label)] no username field to click — Tabbing and typing blind.")
            Autofill.pressTab()
            Autofill.signIn(username: username, password: password)
            return
        }

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
    }

    /// Ends the current session: closes the League client (never the Riot Client), then
    /// signs the account out at the Riot Client level, leaving it open at its login screen.
    private func signOutCurrent(label: String) async throws {
        if LCU.discover() != nil {
            await closeLeague(label: label)
            // Let the Riot Client settle back to its game screen before asking it to log out.
            try await sleep(5)
        }

        // Sign the account out at the Riot Client, which stays open at its login screen.
        let result = await RiotClient.signOut(timeout: Timeout.signOut)
        note("[\(label)] Riot Client sign-out: \(describe(result))")
        if case .failed(let why) = result {
            note("[\(label)] \(why)")
        }

        // A pause on the Riot Client's login screen before the next account starts, so it
        // is fully settled and nothing from the last account bleeds into the next.
        set(nil, .signingOut, "Settling before the next account")
        try await sleep(Timeout.afterSignOut)
    }

    /// Clicks the Riot Client's Play button to launch League. Waits first, because the
    /// button appears before the client is ready and an early click does nothing, then
    /// clicks and verifies League actually starts (its client appears), clicking again if
    /// it did not. Falls back to the RiotClientServices launch arguments as a last resort.
    private func launchLeague(label: String) async {
        // Let the Riot Client finish loading its game view after sign-in.
        set(nil, .launchingLeague, "Letting the client finish loading")
        try? await sleep(Timeout.afterSignIn)

        guard let pid = RiotClient.launcherPID else {
            RiotClient.launchLeague(); return
        }

        // The sidebar and Play clicks below are real mouse events at real screen positions,
        // so the Riot Client has to be the window on top or they land on whatever is
        // covering it. League Vault is frontmost by this point — it comes back after
        // typing — and after League is closed for a reopen there is nothing else to raise
        // the client, which is when this bites.
        if !Autofill.focusRiotClient() {
            note("[\(label)] could not bring the Riot Client forward before clicking Play.")
        }
        try? await sleep(1)

        // The Riot Client sometimes opens on the League Classic page, whose Play launches
        // the wrong mode. Select the normal League icon in the left sidebar first.
        if AXControl.clickLeagueSidebarIcon(pid: pid) {
            note("[\(label)] selected the League tab in the sidebar.")
            try? await sleep(2)
        } else {
            note("[\(label)] League sidebar icon not found by label — assuming it is already selected.")
        }

        for attempt in 0..<8 {
            if LCU.discover() != nil {
                note("[\(label)] League is starting.")
                return
            }
            // Re-assert before each click: anything that steals the front between attempts
            // would otherwise swallow it.
            _ = Autofill.focusRiotClient()
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

    private func waitForSignIn(rcu: RCUCredentials, label: String) async throws {
        let deadline = Date().addingTimeInterval(Timeout.signIn)
        while Date() < deadline {
            try checkCancel()
            // The RCU credentials can rotate when the client relaunches; rediscover.
            let creds = RiotClient.discover() ?? rcu
            if case .signedIn = await RiotClient.sessionState(credentials: creds) { return }
            // Sometimes League itself comes up first; treat that as signed in too.
            if LCU.discover() != nil { return }

            // The client puts its own error on screen rather than telling the API, so read
            // the window: a rejected sign-in is worth retrying immediately rather than
            // sitting out the whole timeout.
            if let pid = RiotClient.launcherPID,
               AXControl.containsAnyText(pid: pid, phrases: Self.signInErrorPhrases) {
                note("[\(label)] the Riot Client is showing a sign-in error.")
                throw SignInRejectedError()
            }
            try await sleep(2)
        }
        throw StepError(message: "No sign-in after \(Int(Timeout.signIn))s — a captcha, 2FA, or the wrong window. Nothing was submitted twice.")
    }

    /// What the Riot Client says when it will not sign you in. Matched case-insensitively
    /// as substrings of any label in its window.
    private static let signInErrorPhrases = [
        "failed to sign in",
        "couldn\u{2019}t sign you in",
        "couldn't sign you in",
        "check your username and password",
        "invalid username or password"
    ]

    private func waitForLeague(label: String) async throws -> LCUCredentials {
        let deadline = Date().addingTimeInterval(Timeout.leagueUp)
        var relaunched = false
        var answeringSince: Date?

        while Date() < deadline {
            try checkCancel()
            if let creds = LCU.discover() {
                if let me = try? await LCU.currentSummoner(credentials: creds), !me.puuid.isEmpty {
                    return creds
                }
                // The API answering while the account never arrives is the blank-client
                // case: the window is up showing "<unknown player>" and will not recover.
                // Time it from when the API first replies, so a slow start is not counted.
                if answeringSince == nil, await LCU.isResponding(credentials: creds) {
                    answeringSince = Date()
                    note("[\(label)] League client is up — waiting for it to finish loading.")
                }
                if let since = answeringSince,
                   Date().timeIntervalSince(since) > Timeout.leagueUsable {
                    throw StuckClientError()
                }
            }
            // If League has not appeared halfway through, nudge it once more.
            if !relaunched, Date() > deadline.addingTimeInterval(-Timeout.leagueUp / 2) {
                RiotClient.launchLeague()
                relaunched = true
            }
            try await sleep(2)
        }
        // It got as far as existing, so treat it as stuck rather than never launched.
        if LCU.discover() != nil { throw StuckClientError() }
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

    /// Returns whether the account was renamed, so the caller can refresh it again.
    @discardableResult
    private func runQuickPrep(credentials: LCUCredentials, iconId: Int,
                              setIcon: Bool, clearChallenges: Bool, index: Int) async -> Bool {
        let name = items[index].name
        let outcome = await LCU.runQuickPrep(credentials: credentials,
                                             setIcon: setIcon, iconId: iconId,
                                             clearChallenges: clearChallenges,
                                             removeFriends: false,   // never, by design
                                             renameFrom: QuickPrep.renames ? QuickPrep.namePoolURL : nil,
                                             availability: QuickPrep.appearsOffline ? .offline : nil) { [weak self] text in
            // Live, because a rename now takes several seconds per attempt. The callback
            // arrives off the main actor, so hop before touching the published log.
            Task { @MainActor in self?.note("\(name): \(text)") }
        }

        if let rename = outcome.rename {
            for attempt in rename.attempts {
                note(attempt.succeeded
                     ? "\(name): renamed to \(attempt.name) — confirmed."
                     : "\(name): “\(attempt.name)” did not take — \(attempt.reason ?? "no reason given").")
            }
            if let picked = rename.renamedTo {
                note("\(name): removed \(picked.riotID) from the name list.")
            } else if rename.attempts.count >= AutoRename.maxAttempts {
                note("\(name): \(AutoRename.maxAttempts) names did not take — leaving the Riot ID alone.")
            }
            if let problem = rename.poolError { note("\(name): \(problem)") }
        }

        if let error = outcome.iconError {
            note("\(name): icon failed — \(error)")
        } else if let set = outcome.iconSet {
            note("\(name): icon set to \(set)\(outcome.iconFellBack ? " (fell back)" : "").")
        }
        if let reset = outcome.challenges {
            note(reset.allSucceeded
                 ? "\(name): challenge badges cleared."
                 : "\(name): challenge reset was partly refused.")
        }
        if let wanted = outcome.availabilityWanted {
            let actual = outcome.availability
            note(actual == wanted
                 ? "\(name): chat set to \(wanted.display.lowercased())."
                 : "\(name): chat would not stay \(wanted.display.lowercased()) — it is \(actual?.display.lowercased() ?? "unknown").")
        }
        return outcome.rename?.didRename ?? false
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
