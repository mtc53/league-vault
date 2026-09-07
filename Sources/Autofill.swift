import AppKit
import ApplicationServices

/// Types into whatever app is frontmost, the way a password manager's autofill does.
/// Posting synthetic keystrokes to another application needs Accessibility permission,
/// which macOS grants per-app and the user must approve in System Settings.
enum Autofill {
    /// Re-queried every time; the answer changes the moment permission is granted or,
    /// more often, the moment a rebuild invalidates it.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// True when macOS lists the app under Accessibility but the signature no longer
    /// matches — the toggle looks on while the permission is dead.
    static var looksStale: Bool { !AXIsProcessTrusted() }

    /// Shows macOS's own "grant accessibility" prompt.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Sends a string as unicode key events. Characters go one at a time with a small
    /// gap — Electron-based clients drop input posted faster than they can process it.
    static func type(_ text: String, characterDelay: UInt32 = 9000) {
        for unit in Array(text.utf16) {
            var buffer = unit
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
            down.post(tap: .cghidEventTap)
            usleep(characterDelay / 3)
            up.post(tap: .cghidEventTap)
            usleep(characterDelay)
        }
    }

    /// Virtual key codes: Tab is 48, Return is 36.
    static func pressTab() { tap(48) }

    /// Submits the form. Used only by the account cycle, which the user drives knowingly —
    /// the one-off Sign in sheet still fills without ever pressing this.
    static func pressReturn() { tap(36) }

    private static func tap(_ virtualKey: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        usleep(30000)
        up.post(tap: .cghidEventTap)
        usleep(60000)
    }

    /// Clears whatever is in the focused field first (Cmd-A, Delete), so a half-typed or
    /// remembered username does not get prepended to what we type.
    static func clearField() {
        guard let downA = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let upA = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        downA.flags = .maskCommand; upA.flags = .maskCommand
        // 0 is 'a'.
        downA.post(tap: .cghidEventTap); usleep(20000); upA.post(tap: .cghidEventTap); usleep(40000)
        tap(51)   // Delete
    }

    /// The Riot Client launcher — not League, not the crash handler. Matched loosely
    /// because the visible app has been named "Riot Client" and "RiotClientUx" across
    /// versions, and its bundle id is com.riotgames.RiotGames.RiotClient.
    private static func isRiotLauncher(_ app: NSRunningApplication) -> Bool {
        let name = (app.localizedName ?? "").lowercased()
        let bid = (app.bundleIdentifier ?? "").lowercased()
        if name.contains("league") || bid.contains("leagueoflegends") { return false }
        if name.contains("crash") { return false }
        return name.contains("riot") || bid.contains("riotgames")
    }

    private static func riotLauncher() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter(isRiotLauncher)
        // A window-bearing app first; helpers only as a last resort.
        return apps.first { $0.activationPolicy == .regular } ?? apps.first
    }

    /// Brings the Riot Client forward so the keystrokes land in it. Returns whether it is
    /// now frontmost — `activate()`'s own return value is unreliable, so this checks.
    @discardableResult
    static func focusRiotClient() -> Bool {
        guard riotLauncher() != nil else { return false }
        for _ in 0..<6 {
            guard let app = riotLauncher() else { return false }
            app.unhide()
            app.activate(options: [.activateAllWindows])
            usleep(450_000)
            if let front = NSWorkspace.shared.frontmostApplication, isRiotLauncher(front) {
                return true
            }
        }
        // Found it but could not confirm it came forward; let the caller decide.
        return false
    }

    /// True when the Riot Client is the frontmost app right now.
    static var riotClientIsFrontmost: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return isRiotLauncher(front)
    }

    /// Fills the login form: username, Tab, password. Never presses Return — submitting
    /// stays a deliberate act by the person at the keyboard.
    static func fillCredentials(username: String, password: String) {
        if !username.isEmpty {
            type(username)
            pressTab()
        }
        if !password.isEmpty {
            type(password)
        }
    }

    /// Fills and submits, clearing each field first. Used by the account cycle only.
    static func signIn(username: String, password: String) {
        if !username.isEmpty {
            clearField()
            type(username)
            pressTab()
        }
        if !password.isEmpty {
            clearField()
            type(password)
        }
        usleep(150000)
        pressReturn()
    }
}
