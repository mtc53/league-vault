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

    enum Step { case start, clientReady, usernameCopied, passwordCopied }

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
                    stepTwo
                    Divider()
                    stepThree
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
        .onAppear { clientRunning = riotClient != nil }
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

    private var stepTwo: some View {
        stepBlock(number: 2, title: "Username") {
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
        stepBlock(number: 3, title: "Password") {
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

    private var note: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why not one click?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Typing a password into a login form and submitting it is the one thing this app will not automate. The clipboard hand-off keeps the final keystroke yours, and the password is wiped from the clipboard after 45 seconds. If you want true one-click sign-in, a password manager's autofill is built for exactly that and integrates with the Riot Client properly.")
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
        case .usernameCopied: return number <= 2
        case .passwordCopied: return number <= 3
        }
    }
}
