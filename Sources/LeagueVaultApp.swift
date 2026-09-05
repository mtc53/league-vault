import SwiftUI
import AppKit

@main
struct LeagueVaultApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        WindowGroup("League Vault") {
            ContentView()
                .environmentObject(store)
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
