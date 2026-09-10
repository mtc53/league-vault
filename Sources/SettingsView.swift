import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject var remote: RemoteServer
    @EnvironmentObject var web: WebDashboard
    @EnvironmentObject var watcher: ClientWatcher

    @State private var includePasswordsInExport = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var appearOffline = QuickPrep.appearsOffline
    @State private var serverMessage: String?
    @State private var serverIsError = false

    @State private var webPassphrase = ""
    @State private var showWebPassphrase = false
    @State private var webMessage: String?
    @State private var webIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FormSection("Where your data comes from") {
                        VStack(alignment: .leading, spacing: 5) {
                            capability("Rank, LP, wins and losses", available: true)
                            capability("Last played game — champion, queue, result, KDA", available: true)
                            capability("Riot ID, server, summoner level, profile icon", available: true)
                            capability("Changing your Riot ID", available: true)
                            capability("Bans, chat restrictions, low-priority queue", available: false)
                        }
                        Text("Everything is read from your running League client over 127.0.0.1 — no account, no API key, no rate limit, and nothing leaves this Mac. The client only knows the account signed in right now, so Refresh works on that one.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Riot exposes no endpoint for penalties anywhere, so those stay under your own control in each account's Penalties tab.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    FormSection("Data") {
                        Text("Accounts live in \(AccountStore.directory.path)/accounts.json — passwords in that file are encrypted.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(
                                    AccountStore.directory.appendingPathComponent("accounts.json").path,
                                    inFileViewerRootedAtPath: AccountStore.directory.path
                                )
                            }
                            Button("Export…") { exportData() }
                            Spacer()
                        }

                        Toggle("Include decrypted passwords in the export", isOn: $includePasswordsInExport)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        if includePasswordsInExport {
                            Text("The exported file will contain readable passwords. Save it somewhere you trust.")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }

                    Divider()

                    watcherSection

                    Divider()

                    serverSection

                    Divider()

                    webSection

                    Divider()

                    FormSection("Cache") {
                        HStack(spacing: 10) {
                            Button("Clear profile icon cache") {
                                ProfileIconCache.shared.clearDiskCache()
                            }
                            Spacer()
                        }
                        Text("Profile icons are cached under ~/Library/Caches/LeagueVault. They redownload on the next refresh.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .frame(height: 560)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
    }

    // MARK: Web dashboard

    private var webSection: some View {
        FormSection("Publish a web dashboard") {
            Text("Turns the vault into one browsable page — cards, filters, ranks, champion pools — and drops it on the same server as your backups, for whatever web server you already point at that folder.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Republish whenever the vault changes", isOn: $web.isEnabled)
                .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Field("Page title") { TextField("League Vault", text: $web.title) }
                Field("Address to open") { TextField("http://4098.duckdns.org:8080", text: $web.siteURL) }
            }
            Field("Folder the web server serves") {
                TextField("C:/LeagueVaultWeb", text: $web.remotePath)
            }
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("The page is written to \(web.resolvedWindowsPath)\\index.html")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            Text("It reuses the server address, username and SSH key from the backup section above, so there is nothing else to set up on this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Toggle("Lock the page behind a passphrase", isOn: $web.isLocked)
                .toggleStyle(.checkbox)
            Text(web.isLocked
                 ? "What sits on the server is encrypted — the browser asks for the passphrase and decrypts the page locally. Anyone who finds the address sees only a lock screen."
                 : "⚠︎ The page will be readable by anyone who reaches that address: every account name, rank, server and penalty, in the clear.")
                .font(.system(size: 11))
                .foregroundStyle(web.isLocked ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if web.isLocked {
                Field("Page passphrase") {
                    HStack(spacing: 6) {
                        if showWebPassphrase {
                            TextField("", text: $webPassphrase)
                        } else {
                            SecureField("", text: $webPassphrase)
                        }
                        Button { showWebPassphrase.toggle() } label: {
                            Image(systemName: showWebPassphrase ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 10) {
                    Button("Save passphrase") {
                        web.passphrase = webPassphrase
                        webMessage = "Page passphrase saved."
                        webIsError = false
                    }
                    .disabled(webPassphrase.isEmpty)
                    if web.hasPassphrase {
                        Label("A passphrase is saved", systemImage: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                Toggle("Include login names on the page", isOn: $web.includeLogins)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            Text("Passwords are never written into the page, locked or not.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Button {
                    Task {
                        let ok = await web.publish(reason: "manual")
                        webIsError = !ok
                        webMessage = ok ? "Published \(store.accounts.count) accounts." : web.lastError
                    }
                } label: {
                    if web.isBusy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Text("Publish now") }
                }
                .disabled(web.isBusy || !web.isConfigured)

                Button("Preview on this Mac") {
                    if let file = web.writePreview() {
                        NSWorkspace.shared.open(file)
                        webIsError = false
                        webMessage = nil
                    } else {
                        webIsError = true
                        webMessage = web.lastError
                    }
                }

                if let url = URL(string: web.siteURL), !web.siteURL.isEmpty {
                    Button("Open site") { NSWorkspace.shared.open(url) }
                }
                Spacer()
            }

            if !web.isConfigured {
                Text(remote.hasServerAccess
                     ? "Set a page passphrase, or turn the lock off, before publishing."
                     : "Fill in the server address, username and SSH key above first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let webMessage {
                Label(webMessage, systemImage: webIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(webIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let last = web.lastPublish {
                Text("Last published \(last.relativeDisplay)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { webPassphrase = web.passphrase ?? "" }
    }

    // MARK: Automatic refresh

    private var watcherSection: some View {
        FormSection("Refresh by itself") {
            Toggle("Refresh whichever account signs in to the League client", isOn: $watcher.isEnabled)
                .toggleStyle(.checkbox)
            Text("League Vault watches for the client and refreshes the matching entry the moment somebody signs in — rank, last game, champions, wallet, penalties. Switching accounts inside the client refreshes the new one too.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Circle()
                    .fill(watcher.isClientRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(watcher.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if watcher.isEnabled && watcher.isClientRunning {
                    Button("Refresh now") { watcher.forgetHandled() }
                        .controlSize(.small)
                }
            }

            if let last = watcher.lastHandled {
                Text("Last picked up a sign-in \(last.relativeDisplay).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(web.isEnabled
                 ? "The web dashboard is republished straight after each automatic refresh."
                 : "Turn on “Republish whenever the vault changes” below to have the page follow along.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Toggle("Keep accounts showing as offline in chat", isOn: $appearOffline)
                .toggleStyle(.checkbox)
                .onChange(of: appearOffline) { _, v in QuickPrep.appearsOffline = v }
            Text("Sets the client's own chat status to offline and puts it back whenever Riot resets it — which it does on entering a lobby or a game. It is the same switch the client's status menu offers, not a chat proxy: League still connects to Riot normally, it just reports you as offline. Someone already in a lobby with you can still see you there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appearOffline, let restored = watcher.lastOfflineRestore {
                Text("Last put back to offline \(restored.relativeDisplay).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.vertical, 2)

            Text("An entry added with only a login adopts whoever signs in, as long as it is the only one waiting. With two of them waiting League Vault will not guess — refresh one by hand to link it.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The server

    private var serverSection: some View {
        FormSection("Your server") {
            Text("Where the web dashboard is published. League Vault reaches it over SSH with a key, the same way you would from Terminal — nothing else is sent to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Field("Server address") { TextField("4098.duckdns.org", text: $remote.host) }
                Field("Port") {
                    TextField("22", value: $remote.port, format: .number)
                }
                .frame(width: 70)
                Field("Windows username") { TextField("Administrator", text: $remote.user) }
            }

            // The key is what lets publishing run without a password sitting in a config.
            HStack(spacing: 10) {
                if remote.hasKey {
                    Label("SSH key ready", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Button("Copy public key") {
                        Clipboard.copy(remote.publicKey)
                        serverMessage = "Public key copied — paste it into the server's authorized_keys."
                        serverIsError = false
                    }
                } else {
                    Button("Create key") { _ = remote.createKeyIfNeeded() }
                    Text("Needed once, then its public half goes on the server.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { testing = true; testOK = await remote.testConnection(); testing = false }
                } label: {
                    if testing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Text("Test connection") }
                }
                .disabled(testing || remote.host.isEmpty)
                Spacer()
            }

            if let testOK {
                Label(testOK ? "Connected to the server." : (remote.lastError ?? "Connection failed."),
                      systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(testOK ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = remote.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let serverMessage {
                Label(serverMessage, systemImage: serverIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(serverIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capability(_ text: String, available: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(available ? .green : .secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(available ? .primary : .secondary)
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "league-accounts.json"
        panel.allowedContentTypes = [.json]
        panel.message = includePasswordsInExport
            ? "This export contains readable passwords."
            : "Passwords are excluded from this export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportJSON(includePasswords: includePasswordsInExport)
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
