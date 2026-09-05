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

    /// Virtual key codes: Tab is 48, Return is 36 (unused — filling is not submitting).
    static func pressTab() {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        usleep(30000)
        up.post(tap: .cghidEventTap)
        usleep(60000)
    }

    /// Brings the Riot Client forward so the keystrokes land in it.
    @discardableResult
    static func focusRiotClient() -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").hasPrefix("Riot Client")
                || ($0.bundleIdentifier ?? "").contains("riotgames.RiotClient")
        }) else { return false }
        return app.activate()
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
}
