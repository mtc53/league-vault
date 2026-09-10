import SwiftUI
import AppKit

@main
struct LeagueVaultApp: App {
    /// The one window, named so the menu bar can reopen it after it has been closed.
    static let mainWindowID = "vault"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AccountStore()
    @StateObject private var remote = RemoteServer()
    @StateObject private var web = WebDashboard()
    @StateObject private var watcher = ClientWatcher()
    @StateObject private var cycle = CycleRunner()

    init() {
        Self.forgetTheBackupFeature()
    }

    /// The scheduled encrypted-backup upload was removed. Its passphrase and settings
    /// are this app's own leftovers, so they go rather than sitting in the Keychain and
    /// preferences forever.
    private static func forgetTheBackupFeature() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "backupFeatureRemoved") else { return }
        Keychain.delete("backup-passphrase")
        for key in ["remoteEnabled", "remotePath", "remoteKeep", "remoteInterval", "remoteLastUpload"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "backupFeatureRemoved")
    }

    var body: some Scene {
        WindowGroup("League Vault", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(remote)
                .environmentObject(web)
                .environmentObject(watcher)
                .environmentObject(cycle)
                .task {
                    web.attach(to: store, remote: remote)
                    watcher.attach(store: store, web: web)
                    cycle.attach(store: store, web: web, watcher: watcher)
                }
        }
        .defaultSize(width: 1100, height: 720)

        // The app keeps running with its window closed — the watcher still refreshes
        // whoever signs in and still holds the offline status — so it needs somewhere to
        // live and a way back.
        MenuBarExtra("League Vault", systemImage: "shield.lefthalf.filled") {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(watcher)
                .environmentObject(web)
        }

        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Reveal Data Folder in Finder") {
                    NSWorkspace.shared.open(AccountStore.directory)
                }
            }
        }
    }
}
