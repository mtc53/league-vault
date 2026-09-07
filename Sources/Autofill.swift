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
            // Force no modifiers on every character. Otherwise a Command flag left over
            // from a Cmd-A clear turns each keystroke into a shortcut (Cmd-d, Cmd-r, …)
            // and nothing is typed at all.
            down.flags = []
            up.flags = []
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

    private static func tap(_ virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        postKey(virtualKey, down: true, flags: flags)
        usleep(30000)
        postKey(virtualKey, down: false, flags: flags)
        usleep(60000)
    }

    private static func postKey(_ virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Clears whatever is in the focused field first (Select All, Delete), so a remembered
    /// username does not get prepended to what we type.
    ///
    /// The Command key is pressed and released for real. Flagging the 'a' event with
    /// `.maskCommand` but never sending a Command key-up leaves the modifier stuck down,
    /// after which every following keystroke is read as a Command shortcut and nothing
    /// types — which is exactly what went wrong.
    static func clearField() {
        postKey(55, down: true, flags: .maskCommand)    // Command down (55 = Left Command)
        usleep(20000)
        postKey(0, down: true, flags: .maskCommand)     // 'a' down while Command is held
        usleep(12000)
        postKey(0, down: false, flags: .maskCommand)    // 'a' up
        usleep(12000)
        postKey(55, down: false, flags: [])             // Command up — releases the modifier
        usleep(40000)
        tap(51)                                          // Delete removes the selection
        usleep(20000)
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
