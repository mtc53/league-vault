import SwiftUI
import AppKit

@main
struct LeagueVaultApp: App {
    @StateObject private var store = AccountStore()
    @StateObject private var remote = RemoteServer()
    @StateObject private var web = WebDashboard()
    @StateObject private var watcher = ClientWatcher()

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
        WindowGroup("League Vault") {
            ContentView()
                .environmentObject(store)
                .environmentObject(remote)
                .environmentObject(web)
                .environmentObject(watcher)
                .task { web.attach(to: store, remote: remote) }
        }
        .defaultSize(width: 1100, height: 720)
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
