import AppKit
import ApplicationServices

// Locating and clicking controls inside another app through the Accessibility API.
//
// The Riot Client login is an Electron (Chromium) window. Bringing the window forward
// does not put the keyboard caret in the username field, which is why typing did nothing
// until the field was clicked by hand. Chromium only publishes its accessibility tree
// once asked — setting AXManualAccessibility on the app is the documented way to ask —
// after which the text fields can be found and clicked exactly where they sit.
enum AXControl {

    struct LoginFields {
        var username: CGRect?
        var password: CGRect?
        var found: Bool { username != nil || password != nil }
    }

    /// The Riot Client launcher's process id (not League, not the crash handler).
    static func riotPID() -> pid_t? {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            if n.contains("league") || b.contains("leagueoflegends") { return false }
            if n.contains("crash") { return false }
            return n.contains("riot") || b.contains("riotgames")
        }
        let target = apps.first { $0.activationPolicy == .regular } ?? apps.first
        return target?.processIdentifier
    }

    /// Asks an Electron/Chromium app to expose its accessibility tree.
    private static func enableManualAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func role(_ el: AXUIElement) -> String {
        (attr(el, kAXRoleAttribute as String) as? String) ?? ""
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posRef = attr(el, kAXPositionAttribute as String),
              let sizeRef = attr(el, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 40, size.height > 8, size.height < 120 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Depth-first walk collecting the on-screen text fields. The topmost editable field
    /// is taken as the username; a secure field (or the next field down) as the password.
    static func loginFields(pid: pid_t) -> LoginFields {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(app)

        var texts: [CGRect] = []
        var secures: [CGRect] = []

        var stack = children(app)
        var visited = 0
        while let el = stack.popLast(), visited < 6000 {
            visited += 1
            switch role(el) {
            case "AXTextField", "AXComboBox":
                if let f = frame(el) { texts.append(f) }
            case "AXSecureTextField":
                if let f = frame(el) { secures.append(f) }
            default:
                break
            }
            stack.append(contentsOf: children(el))
        }

        texts.sort { $0.minY < $1.minY }
        secures.sort { $0.minY < $1.minY }

        var fields = LoginFields()
        fields.username = texts.first
        if let secure = secures.first {
            fields.password = secure
        } else if texts.count >= 2 {
            fields.password = texts[1]
        }
        return fields
    }

    /// Retries because Chromium builds its tree a beat after being asked for it.
    static func loginFieldsWaiting(pid: pid_t, attempts: Int = 6) async -> LoginFields {
        for _ in 0..<attempts {
            let fields = loginFields(pid: pid)
            if fields.found { return fields }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return loginFields(pid: pid)
    }

    // MARK: Clicking

    private static let mouseSource = CGEventSource(stateID: .hidSystemState)

    static func click(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        usleep(30_000)
        let down = CGEvent(mouseEventSource: mouseSource, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: mouseSource, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(60_000)
        up?.post(tap: .cghidEventTap)
        usleep(90_000)
    }

    static func click(in rect: CGRect) {
        click(CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: Buttons

    private static func title(_ el: AXUIElement) -> String {
        let t = (attr(el, kAXTitleAttribute as String) as? String) ?? ""
        let d = (attr(el, kAXDescriptionAttribute as String) as? String) ?? ""
        let v = (attr(el, kAXValueAttribute as String) as? String) ?? ""
        return "\(t) \(d) \(v)"
    }

    /// The word appears as a whole token, so "play" does not match "player" or "replay".
    private static func hasWord(_ text: String, _ word: String) -> Bool {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains(Substring(word.lowercased()))
    }

    /// Finds a control whose label is (or contains, as a whole word) one of `words` and
    /// clicks it. Used for the Riot Client's Play button, which launches League.
    @discardableResult
    static func clickControl(pid: pid_t, words: [String]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(app)

        var best: (rect: CGRect, isButton: Bool)?
        var stack = children(app)
        var visited = 0
        while let el = stack.popLast(), visited < 8000 {
            visited += 1
            let label = title(el)
            if !label.trimmingCharacters(in: .whitespaces).isEmpty,
               words.contains(where: { hasWord(label, $0) }),
               let f = frame(el) {
                let isButton = role(el) == "AXButton"
                if best == nil || (isButton && !(best!.isButton)) {
                    best = (f, isButton)
                }
                if isButton { break }   // a real button is the best match; stop looking
            }
            stack.append(contentsOf: children(el))
        }
        guard let target = best else { return false }
        click(in: target.rect)
        return true
    }

    /// Clicks a control whose label contains `phrase` (e.g. "sign out"), preferring a real
    /// button over a paragraph that happens to contain the same words.
    @discardableResult
    static func clickPhrase(pid: pid_t, phrase: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(app)
        let needle = phrase.lowercased()

        var best: (rect: CGRect, isButton: Bool)?
        var stack = children(app)
        var visited = 0
        while let el = stack.popLast(), visited < 8000 {
            visited += 1
            if title(el).lowercased().contains(needle), let f = frame(el) {
                let isButton = role(el) == "AXButton"
                if best == nil || (isButton && !(best!.isButton)) { best = (f, isButton) }
                if isButton { break }
            }
            stack.append(contentsOf: children(el))
        }
        guard let target = best else { return false }
        click(in: target.rect)
        return true
    }

    /// Clicks the normal League of Legends icon in the Riot Client's left sidebar, so the
    /// main panel shows the normal League page and not the Classic (or TFT) one. Matched by
    /// label, excluding the other modes, and restricted to the far-left strip so the big
    /// centre logo and the "Launches in League of Legends" caption are not mistaken for it.
    @discardableResult
    static func clickLeagueSidebarIcon(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(app)

        var best: CGRect?
        var stack = children(app)
        var visited = 0
        while let el = stack.popLast(), visited < 8000 {
            visited += 1
            let label = title(el).lowercased()
            if label.contains("league") && label.contains("legends"),
               !label.contains("classic"), !label.contains("teamfight"),
               !label.contains("tft"), !label.contains("tactics"),
               let f = frame(el), f.midX < 140 {          // the left sidebar only
                if best == nil || f.minX < best!.minX { best = f }
            }
            stack.append(contentsOf: children(el))
        }
        guard let icon = best else { return false }
        click(in: icon)
        return true
    }

    // MARK: Windows

    private static func windowFrame(_ win: AXUIElement) -> CGRect? {
        guard let posRef = attr(win, kAXPositionAttribute as String),
              let sizeRef = attr(win, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 200, size.height > 150 else { return nil }   // a real window, not a chip
        return CGRect(origin: pos, size: size)
    }

    /// The app's main window frame, for clicking chrome (like the close button) that has no
    /// accessible label of its own.
    static func mainWindowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(app)
        if let ref = attr(app, kAXMainWindowAttribute as String),
           CFGetTypeID(ref) == AXUIElementGetTypeID(),
           let f = windowFrame(ref as! AXUIElement) {
            return f
        }
        if let windows = attr(app, kAXWindowsAttribute as String) as? [AXUIElement] {
            // The largest window is the client, not a tooltip or toast.
            return windows.compactMap(windowFrame).max { $0.width * $0.height < $1.width * $1.height }
        }
        return nil
    }
}
