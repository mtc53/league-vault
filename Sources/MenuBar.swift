import SwiftUI
import AppKit

/// Keeps the app alive when its window is closed, and takes the Dock icon away while it
/// is only living in the menu bar.
///
/// Closing the window is meant to be "put it away", not "quit" — the watcher still
/// refreshes whoever signs in and still holds the offline status. Quitting is done from
/// the menu bar or ⌘Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Drops out of the Dock and the app switcher once the last real window is closed.
    ///
    /// Keyed off the window closing rather than the app losing focus: the account cycle
    /// hides League Vault while it types, and that must not be mistaken for putting it
    /// away.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            // The closing window is still listed at this point, so look past it — and do
            // it next turn, once it has actually gone.
            DispatchQueue.main.async {
                let anyLeft = NSApp.windows.contains {
                    $0 !== closing && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
                }
                if !anyLeft { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Clicking the Dock icon (when there is one) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBar.showWindow()
        return true
    }
}

enum MenuBar {
    /// Brings the app back to a normal, Dock-having, window-showing application.
    static func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // A closed WindowGroup window is reopened by the scene; nudge any existing one.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// What the menu bar icon drops down.
struct MenuBarContent: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var watcher: ClientWatcher
    @EnvironmentObject var web: WebDashboard

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(watcher.status)

        if let who = watcher.signedInAs {
            Divider()
            Text("Signed in as \(who)")
            Button("Go to \(who)") {
                open()
                watcher.wantsReveal = true
            }
        }

        Divider()

        Toggle("Refresh on sign-in", isOn: $watcher.isEnabled)
        Toggle("Appear offline", isOn: offlineBinding)
        if web.isEnabled {
            Button("Publish the page now") {
                Task { _ = await web.publish(reason: "menu bar") }
            }
            .disabled(!web.isConfigured || web.isBusy)
        }

        Divider()

        Button("Open League Vault") { open() }
        Button("Quit League Vault") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// QuickPrep keeps this in preferences rather than in an object, so it needs a
    /// binding built by hand.
    private var offlineBinding: Binding<Bool> {
        Binding(get: { QuickPrep.appearsOffline },
                set: { QuickPrep.appearsOffline = $0 })
    }

    private func open() {
        MenuBar.showWindow()
        openWindow(id: LeagueVaultApp.mainWindowID)
    }
}
