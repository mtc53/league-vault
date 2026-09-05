import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject var remote: RemoteBackup

    @State private var includePasswordsInExport = false
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var showPassphrase = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var restoreMessage: String?
    @State private var restoreIsError = false

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

                    serverSection

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

    // MARK: Remote server

    private var serverSection: some View {
        FormSection("Back up to your server") {
            Toggle("Upload automatically", isOn: $remote.isEnabled)
                .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Field("Server address") { TextField("203.0.113.10", text: $remote.host) }
                Field("Port") {
                    TextField("22", value: $remote.port, format: .number)
                }
                .frame(width: 70)
                Field("Windows username") { TextField("Administrator", text: $remote.user) }
            }
            Field("Folder on the server") {
                TextField("LeagueVaultBackups", text: $remote.remotePath)
            }

            Divider().padding(.vertical, 2)

            // The key is what lets uploads run without a password sitting in a config.
            HStack(spacing: 10) {
                if remote.hasKey {
                    Label("SSH key ready", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Button("Copy public key") {
                        Clipboard.copy(remote.publicKey)
                        restoreMessage = "Public key copied — paste it into the server's authorized_keys."
                        restoreIsError = false
                    }
                } else {
                    Button("Create key") { _ = remote.createKeyIfNeeded() }
                    Text("Needed once, then its public half goes on the server.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Field("Backup passphrase") {
                HStack(spacing: 6) {
                    if showPassphrase {
                        TextField("", text: $passphrase)
                    } else {
                        SecureField("", text: $passphrase)
                    }
                    Button { showPassphrase.toggle() } label: {
                        Image(systemName: showPassphrase ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !showPassphrase {
                Field("Confirm passphrase") { SecureField("", text: $passphraseConfirm) }
            }
            HStack(spacing: 10) {
                Button("Save passphrase") {
                    remote.passphrase = passphrase
                    restoreMessage = "Passphrase saved."
                    restoreIsError = false
                }
                .disabled(passphrase.isEmpty || (!showPassphrase && passphrase != passphraseConfirm))
                if !showPassphrase && !passphraseConfirm.isEmpty && passphrase != passphraseConfirm {
                    Text("Passphrases do not match.").font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
            }
            Text("⚠︎ Write this passphrase down somewhere that is not this Mac. Backups are encrypted with it and nothing else — lose the Mac and the passphrase together and the files cannot be opened by anyone.")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Field("Every") {
                    Picker("", selection: $remote.intervalMinutes) {
                        Text("15 minutes").tag(15)
                        Text("Hour").tag(60)
                        Text("6 hours").tag(360)
                        Text("Day").tag(1440)
                        Text("Only on change").tag(0)
                    }
                    .labelsHidden()
                }
                .frame(width: 150)
                Field("Keep") {
                    Picker("", selection: $remote.keepCount) {
                        ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) copies").tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(width: 130)
                Spacer()
            }
            Text("An upload also runs 30 seconds after any change to the vault.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button {
                    Task { testing = true; testOK = await remote.testConnection(); testing = false }
                } label: {
                    if testing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Text("Test connection") }
                }
                .disabled(testing || remote.host.isEmpty)

                Button("Upload now") {
                    Task { _ = await remote.upload(reason: "manual") }
                }
                .disabled(remote.isBusy || !remote.isConfigured)

                Button("Restore from server…") { restoreFromServer() }
                    .disabled(!remote.isConfigured)
                Spacer()
            }

            if let testOK {
                Label(testOK ? "Connected to the server." : (remote.lastError ?? "Connection failed."),
                      systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(testOK ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = remote.lastError, testOK == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let last = remote.lastUpload {
                Text("Last upload \(last.relativeDisplay)" + (remote.lastFileName.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let restoreMessage {
                Label(restoreMessage, systemImage: restoreIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(restoreIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { passphrase = remote.passphrase ?? ""; passphraseConfirm = passphrase }
    }

    private func restoreFromServer() {
        Task {
            do {
                let (envelope, records) = try await remote.fetchLatest(passphrase: remote.passphrase ?? "")
                let prompt = NSAlert()
                prompt.messageText = "Restore \(envelope.accountCount) account\(envelope.accountCount == 1 ? "" : "s")?"
                prompt.informativeText = "From \(envelope.origin), \(envelope.createdAt.shortDisplay).\n\nMerge adds accounts this Mac does not have. Replace discards the local vault entirely."
                prompt.addButton(withTitle: "Merge")
                prompt.addButton(withTitle: "Replace")
                prompt.addButton(withTitle: "Cancel")
                let choice = prompt.runModal()
                guard choice != .alertThirdButtonReturn else { return }
                let mode: AccountStore.RestoreMode = choice == .alertSecondButtonReturn ? .replace : .merge
                let result = store.restore(records, mode: mode)
                restoreIsError = false
                restoreMessage = mode == .replace
                    ? "Replaced the vault with \(result.added) accounts."
                    : "Added \(result.added), left \(result.kept) already here untouched."
            } catch {
                restoreIsError = true
                restoreMessage = error.localizedDescription
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
