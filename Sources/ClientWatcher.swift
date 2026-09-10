import Foundation

/// Watches for the League client and reports whoever signs in.
///
/// There is nothing to subscribe to — the client is a helper process that publishes its
/// port and token on its own command line and nothing else — so this polls. The interval
/// changes with what is going on: slowly while nothing is running, briskly while the
/// client is up but nobody has signed in yet, and rarely once the current sign-in has
/// already been handled.
@MainActor
final class ClientWatcher: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    /// The last thing the watcher did, for the window to show as a banner when it is
    /// open. Nothing depends on anyone reading it — the work happens either way.
    @Published var lastMessage: Banner?

    /// Raised by the menu bar to ask the window to select the signed-in account.
    @Published var wantsReveal = false

    @Published private(set) var isClientRunning = false
    @Published private(set) var signedInAs: String?
    /// The signed-in account's identity, for jumping straight to it in the sidebar.
    @Published private(set) var signedInPuuid: String?
    @Published private(set) var lastHandled: Date?
    /// When presence was last put back to offline, for the settings line.
    @Published private(set) var lastOfflineRestore: Date?
    @Published private(set) var status = "Not watching."

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError = false

        static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
    }

    private enum Keys { static let enabled = "autoRefreshOnClient" }

    private let defaults = UserDefaults.standard
    private weak var store: AccountStore?
    private weak var web: WebDashboard?
    private var loop: Task<Void, Never>?
    /// Held while the account cycle drives the client itself, so the two do not fight
    /// over the same sign-in.
    private(set) var isSuspended = false
    /// The sign-in already handed over, so the same one is not offered twice.
    private var handledPuuid: String?

    private enum Pace {
        /// No client. Checking costs a `ps`, so do it gently.
        static let idle: UInt64 = 15
        /// Client is up but nobody is signed in — the login screen can sit a while.
        static let waiting: UInt64 = 5
        /// Signed in and dealt with. Only still polling to notice an account switch.
        static let settled: UInt64 = 20
    }

    init() {
        // On by default: it is the whole point of the feature, and it only reads.
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if isEnabled { start() }
    }

    deinit { loop?.cancel() }

    // MARK: The loop

    private func start() {
        guard loop == nil else { return }
        status = "Waiting for the League client…"
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.tick()
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        isClientRunning = false
        signedInAs = nil
        signedInPuuid = nil
        handledPuuid = nil
        status = "Not watching."
    }

    /// Everything the watcher needs to do the refresh itself. It deliberately does not
    /// go through the window: the whole point is that this keeps working with the window
    /// closed and the app sitting in the menu bar.
    func attach(store: AccountStore, web: WebDashboard) {
        self.store = store
        self.web = web
    }

    /// The cycle takes over sign-ins while it runs; the watcher stands down.
    func suspend() {
        isSuspended = true
        status = "Paused while the account cycle runs."
    }

    func resume() {
        isSuspended = false
        handledPuuid = nil          // re-offer whoever is signed in now
        status = isClientRunning ? "Watching." : "Waiting for the League client…"
    }

    /// One poll. Returns how long to wait before the next one.
    private func tick() async -> UInt64 {
        guard isEnabled, !isSuspended else { return Pace.idle }

        guard let credentials = LCU.discover() else {
            if isClientRunning {
                isClientRunning = false
                signedInAs = nil
                signedInPuuid = nil
                // A restart should refresh again even for the same account.
                handledPuuid = nil
                status = "League client is closed."
            }
            return Pace.idle
        }

        if !isClientRunning {
            isClientRunning = true
            status = "League client is up — waiting for sign-in…"
        }

        // The client answers on its port well before anyone has signed in; the summoner
        // endpoint is what actually tells you a session exists.
        guard let me = try? await LCU.currentSummoner(credentials: credentials),
              !me.puuid.isEmpty else {
            signedInAs = nil
            status = "League client is up — waiting for sign-in…"
            return Pace.waiting
        }

        signedInAs = me.riotID
        signedInPuuid = me.puuid

        // Riot puts presence back to online on its own — entering a lobby or a game does
        // it — so while "appear offline" is on, put it back whenever it drifts.
        if QuickPrep.appearsOffline {
            let now = await LCU.chatAvailability(credentials: credentials)
            if now != nil && now != .offline {
                _ = await LCU.applyChatAvailability(.offline, credentials: credentials)
                lastOfflineRestore = Date()
            }
        }

        guard me.puuid != handledPuuid else {
            status = "Watching \(me.riotID)."
            return Pace.settled
        }

        handledPuuid = me.puuid
        lastHandled = Date()
        status = "Signed in as \(me.riotID) — refreshing."
        await refresh(me, credentials: credentials)
        status = "Watching \(me.riotID)."
        return Pace.settled
    }

    // MARK: The refresh itself

    /// Which vault entry this sign-in belongs to.
    ///
    /// Identity first, then Riot ID. Failing both, an entry added with only a login has
    /// no identity yet and is waiting to adopt one — but only when there is exactly one
    /// such entry, because guessing between two would attach the wrong account.
    private func target(for me: LCUSummoner, in store: AccountStore) -> Account? {
        if !me.puuid.isEmpty,
           let match = store.accounts.first(where: { $0.puuid == me.puuid }) {
            return match
        }
        if let match = store.accounts.first(where: {
            !$0.gameName.isEmpty && $0.riotID.compare(me.riotID, options: .caseInsensitive) == .orderedSame
        }) {
            return match
        }
        let waiting = store.accounts.filter(\.isUnidentified)
        return waiting.count == 1 ? waiting[0] : nil
    }

    private func refresh(_ me: LCUSummoner, credentials: LCUCredentials) async {
        guard let store else { return }
        guard let entry = target(for: me, in: store) else {
            lastMessage = Banner(text: "The client signed in as \(me.riotID), which matches no entry here. Add it, or select an entry and press Refresh to link it.")
            return
        }
        guard let snapshot = try? await LCU.snapshot(credentials: credentials) else {
            lastMessage = Banner(text: "Could not read \(entry.displayName) from the client.", isError: true)
            return
        }
        guard var current = store.accounts.first(where: { $0.id == entry.id }) else { return }

        let before = current.riotID
        let wasUnidentified = current.isUnidentified
        current.applySnapshot(snapshot)
        store.update(current)

        if wasUnidentified {
            lastMessage = Banner(text: "Linked to \(current.riotID) and filled in.")
        } else if !before.isEmpty && before != current.riotID {
            lastMessage = Banner(text: "Riot ID changed: \(before) → \(current.riotID).")
        } else {
            lastMessage = Banner(text: "Updated \(current.displayName) from the League client.")
        }

        // Push it straight out rather than waiting for the publish debounce, so signing
        // in and seeing the page update is one motion.
        if let web, web.isEnabled, web.isConfigured {
            _ = await web.publish(reason: "auto-refresh")
        }
    }

    // MARK: Talking to the view

    /// Makes the next poll offer the current sign-in again — used by "Refresh now".
    func forgetHandled() {
        handledPuuid = nil
        status = isClientRunning ? "Rechecking…" : status
    }

}
