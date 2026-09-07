import SwiftUI
import AppKit

@main
struct LeagueVaultApp: App {
    @StateObject private var store = AccountStore()
    @StateObject private var remote = RemoteBackup()
    @StateObject private var web = WebDashboard()

    var body: some Scene {
        WindowGroup("League Vault") {
            ContentView()
                .environmentObject(store)
                .environmentObject(remote)
                .environmentObject(web)
                .task {
                    remote.attach(to: store)
                    web.attach(to: store, remote: remote)
                }
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
