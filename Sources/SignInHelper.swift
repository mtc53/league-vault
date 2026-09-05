import SwiftUI
import AppKit

/// Gets the Riot Client to the login screen with the right account's details on hand.
/// It deliberately stops short of typing the password in and pressing enter — the last
/// step stays with you.
struct SignInHelperSheet: View {
    var account: Account

    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .start
    @State private var toast: String?
    @State private var clientRunning = false
    @State private var countdown = 0
    @State private var filling = false
    @State private var permitted = Autofill.isPermitted
    @State private var selfTestField = ""
    @State private var selfTestCountdown = 0
    @State private var selfTestResult: String?
    @FocusState private var selfTestFocused: Bool

    enum Step { case start, clientReady, usernameCopied, passwordCopied }

    private var stepCount: Int { 4 }

    private static let riotClientPath = "/Users/Shared/Riot Games/Riot Client.app"

    private var riotClient: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").hasPrefix("Riot Client")
                || ($0.bundleIdentifier ?? "").contains("riotgames.RiotClient")
        }
    }

    private var leagueClient: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").contains("League of Legends")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepOne
                    Divider()
                    autofillStep
                    Divider()
                    stepTwo
                    Divider()
                    stepThree
                    Divider()
                    selfTest
                    Divider()
                    note
                }
                .padding(20)
            }
            .frame(height: 420)

            Divider()
            HStack {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .onAppear {
            clientRunning = riotClient != nil
            permitted = Autofill.isPermitted
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings is exactly when this changes.
            permitted = Autofill.isPermitted
            clientRunning = riotClient != nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProfileIconView(iconId: account.profileIconId,
                            initials: String(account.displayName.prefix(1)).uppercased(),
                            tint: account.soloRank.effectiveTier.color,
                            size: 40, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in as \(account.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                if !account.loginUsername.isEmpty {
                    Text(account.loginUsername)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Steps

    private var stepOne: some View {
        stepBlock(number: 1, title: "Get to the login screen") {
            if clientRunning {
                Text("The Riot Client is already running, so it is signed in to another account. Quitting it returns you to the login screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Quit Riot Client") {
                        leagueClient?.terminate()
                        riotClient?.terminate()
                        toast = "Asked the client to quit."
                        // Give it a moment to go away before offering to relaunch.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            clientRunning = riotClient != nil
                            if !clientRunning { step = .clientReady }
                        }
                    }
                    Button("Recheck") { clientRunning = riotClient != nil }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Button("Open Riot Client") {
                        let url = URL(fileURLWithPath: Self.riotClientPath)
                        NSWorkspace.shared.open(url)
                        step = .clientReady
                        toast = "Opening the Riot Client."
                    }
                    Text("Not currently running.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// Types the credentials into the client the way a password manager would.
    private var autofillStep: some View {
        stepBlock(number: 2, title: "Fill the login form") {
            if account.loginUsername.isEmpty && account.encryptedPassword == nil {
                Text("Nothing saved to fill. Add a username and password in Edit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Text("Click into the client's username field, then press this. It types the username, tabs to the password field, and types the password. It does not press return — sign-in stays your call.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        beginFill()
                    } label: {
                        if countdown > 0 {
                            Text("Filling in \(countdown)…")
                        } else if filling {
                            Text("Typing…")
                        } else {
                            Label("Fill username & password", systemImage: "keyboard")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(filling || countdown > 0)

                    if countdown > 0 {
                        Button("Cancel") {
                            countdown = 0
                            toast = "Cancelled."
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    Spacer()
                }

                if countdown > 0 {
                    Text("Switching to the Riot Client — click the username field now.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }

                if !permitted {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS is not currently letting League Vault send keystrokes.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                        Text("If League Vault already appears ticked under Privacy & Security → Accessibility, the entry belongs to an older build: **remove it with the − button and add it again**. Accessibility permission is tied to the app's code signature, and every rebuild produces a new one.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Open Accessibility settings") { Autofill.openAccessibilitySettings() }
                                .buttonStyle(.link)
                            Button("Reveal app in Finder") {
                                NSWorkspace.shared.selectFile("/Applications/League Vault.app",
                                                              inFileViewerRootedAtPath: "/Applications")
                            }
                            .buttonStyle(.link)
                            Button("Ask macOS") { Autofill.requestPermission() }
                                .buttonStyle(.link)
                            Button("Recheck") { permitted = Autofill.isPermitted }
                                .buttonStyle(.link)
                            Spacer()
                        }
                        .font(.system(size: 11))
                        Text("The button above still works — try it. This warning can be wrong; the keystrokes are the real test.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
                }
            }
        }
    }

    private func beginFill() {
        guard let password = account.encryptedPassword == nil ? "" : store.password(for: account) else {
            toast = "Could not decrypt the password."
            return
        }
        Autofill.focusRiotClient()
        countdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor in
                guard countdown > 0 else { timer.invalidate(); return }
                countdown -= 1
                guard countdown == 0 else { return }
                timer.invalidate()
                filling = true
                // Off the main actor: typing sleeps between keystrokes.
                DispatchQueue.global(qos: .userInitiated).async {
                    Autofill.fillCredentials(username: account.loginUsername, password: password)
                    DispatchQueue.main.async {
                        filling = false
                        step = .passwordCopied
                        toast = "Filled. Press return in the client when you are ready."
                    }
                }
            }
        }
    }

    private var stepTwo: some View {
        stepBlock(number: 3, title: "Or copy the username by hand") {
            if account.loginUsername.isEmpty {
                Text("No username saved for this account. Add one in Edit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    Text(account.loginUsername)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        Clipboard.copy(account.loginUsername)
                        step = .usernameCopied
                        toast = "Username copied — paste it into the client."
                    }
                    Spacer()
                }
            }
        }
    }

    private var stepThree: some View {
        stepBlock(number: 4, title: "Or copy the password by hand") {
            if account.encryptedPassword == nil {
                Text("No password saved for this account. Add one in Edit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    Button("Copy password") {
                        guard let password = store.password(for: account) else {
                            toast = "Could not decrypt the password."
                            return
                        }
                        Clipboard.copy(password, clearAfter: 45)
                        step = .passwordCopied
                        toast = "Password copied — clipboard clears in 45 seconds."
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Paste into the client and press return.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// Types into a field inside this very window. Posting synthetic key events needs
    /// the same Accessibility permission whatever the target, so if text lands here the
    /// permission is genuinely working and any failure is about focus or the client.
    private var selfTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Self-test")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Press Test, then click the box. If “autofill-ok” appears, keystroke permission is working and the problem is which window or field is focused — not permission.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(selfTestCountdown > 0 ? "Typing in \(selfTestCountdown)…" : "Test") {
                    selfTestField = ""
                    selfTestResult = nil
                    selfTestFocused = true
                    selfTestCountdown = 2
                    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                        Task { @MainActor in
                            selfTestCountdown -= 1
                            guard selfTestCountdown <= 0 else { return }
                            timer.invalidate()
                            DispatchQueue.global(qos: .userInitiated).async {
                                Autofill.type("autofill-ok")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    selfTestResult = selfTestField.contains("autofill-ok")
                                        ? "Keystrokes work. Permission is fine — if the client stays empty, the field there was not focused."
                                        : "No keystrokes arrived. macOS is blocking them: remove League Vault from Accessibility with −, add it again, and retry."
                                }
                            }
                        }
                    }
                }
                .disabled(selfTestCountdown > 0)

                TextField("click here", text: $selfTestField)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 160)
                    .focused($selfTestFocused)

                Text(permitted ? "AXIsProcessTrusted: yes" : "AXIsProcessTrusted: no")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(permitted ? .green : .orange)
                Spacer()
            }

            if let selfTestResult {
                Text(selfTestResult)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selfTestResult.hasPrefix("Keystrokes work") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How the filling works")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Keystrokes are synthesised into whichever app is frontmost, which is why macOS asks for Accessibility permission and why the client has to be focused with the username field clicked. The password is read from the vault at the moment you press the button and is never put on the clipboard. Return is never sent — the form is filled, submitting is yours.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepBlock<Content: View>(number: Int, title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(doneThrough(number) ? Color.green : Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium))
                content()
            }
            Spacer()
        }
    }

    private func doneThrough(_ number: Int) -> Bool {
        switch step {
        case .start:          return false
        case .clientReady:    return number <= 1
        case .usernameCopied: return number <= 3
        case .passwordCopied: return number <= 4
        }
    }
}
