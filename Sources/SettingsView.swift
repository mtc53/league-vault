import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var includePasswordsInExport = false

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
            .frame(height: 430)

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
        .frame(width: 560)
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
