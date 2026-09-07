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

    /// Set when a sign-in has been seen that has not been refreshed yet. The view
    /// clears it once it has acted.
    @Published private(set) var pending: SignIn?

    @Published private(set) var isClientRunning = false
    @Published private(set) var signedInAs: String?
    @Published private(set) var lastHandled: Date?
    @Published private(set) var status = "Not watching."

    struct SignIn: Identifiable, Equatable {
        let id = UUID()
        var summoner: LCUSummoner
        var seenAt = Date()

        static func == (a: SignIn, b: SignIn) -> Bool { a.id == b.id }
    }

    private enum Keys { static let enabled = "autoRefreshOnClient" }

    private let defaults = UserDefaults.standard
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
        handledPuuid = nil
        pending = nil
        status = "Not watching."
    }

    /// The cycle takes over sign-ins while it runs; the watcher stands down.
    func suspend() {
        isSuspended = true
        pending = nil
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
        guard me.puuid != handledPuuid else {
            status = "Watching \(me.riotID)."
            return Pace.settled
        }

        handledPuuid = me.puuid
        lastHandled = Date()
        status = "Signed in as \(me.riotID) — refreshing."
        pending = SignIn(summoner: me)
        return Pace.settled
    }

    // MARK: Talking to the view

    /// Called once the view has refreshed (or decided it cannot).
    func clearPending() { pending = nil }

    /// Makes the next poll offer the current sign-in again — used by "Refresh now".
    func forgetHandled() {
        handledPuuid = nil
        status = isClientRunning ? "Rechecking…" : status
    }

    func describeStatus() -> String { status }
}
