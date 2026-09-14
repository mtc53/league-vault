import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Picks a combo-list .txt, shows what is in it, and imports the new accounts.
struct ComboImportSheet: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    /// Folders that already exist, plus "New folder…".
    var knownFolders: [String]
    /// Reports back how it went, for the banner.
    var onDone: (AccountStore.ComboImportResult) -> Void

    @State private var fileURL: URL?
    @State private var parsed: ComboImport.Parsed?
    @State private var readError: String?

    @State private var folderChoice = ""
    @State private var newFolderName = ""

    private static let newFolderToken = "\u{0001}new"

    /// New to this vault: their username is not already stored.
    private var newCount: Int {
        guard let parsed else { return 0 }
        let known = Set(store.accounts.map { $0.loginUsername.lowercased() })
        return parsed.pairs.filter { !known.contains($0.username.lowercased()) }.count
    }

    private var alreadyHave: Int { (parsed?.pairs.count ?? 0) - newCount }

    private var resolvedFolder: String {
        folderChoice == Self.newFolderToken
            ? newFolderName.trimmingCharacters(in: .whitespaces)
            : folderChoice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a combo list")
                .font(.system(size: 15, weight: .semibold))

            Text("A plain .txt file, one account per line, in the form **username;password**. Blank lines and lines starting with # are ignored. Only the username and password are read — everything else fills itself in when the account signs in and is refreshed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    chooseFile()
                } label: {
                    Label(fileURL == nil ? "Choose .txt…" : "Choose a different file…",
                          systemImage: "doc.text")
                }
                if let fileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if let readError {
                Label(readError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let parsed {
                summary(parsed)

                if newCount > 0 {
                    Divider()
                    HStack(spacing: 10) {
                        Text("File under")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $folderChoice) {
                            Text("Unfiled").tag("")
                            if !knownFolders.isEmpty { Divider() }
                            ForEach(knownFolders, id: \.self) { Text($0).tag($0) }
                            Divider()
                            Text("New folder…").tag(Self.newFolderToken)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        if folderChoice == Self.newFolderToken {
                            TextField("Imported", text: $newFolderName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                        Spacer()
                    }
                }
            }

            Divider()

            HStack {
                Text("Passwords are encrypted on the way in, the same as any other stored password.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(newCount > 0 ? "Import \(newCount)" : "Import") {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newCount == 0)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(LV.bg2)
        .tint(LV.accent)
    }

    @ViewBuilder
    private func summary(_ parsed: ComboImport.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("\(newCount)", "new account\(newCount == 1 ? "" : "s") to import",
                color: newCount > 0 ? .green : .secondary)
            if alreadyHave > 0 {
                row("\(alreadyHave)", "already in the vault — skipped", color: .secondary)
            }
            if parsed.duplicateLines > 0 {
                row("\(parsed.duplicateLines)", "repeated inside the file — skipped", color: .secondary)
            }
            if !parsed.malformed.isEmpty {
                row("\(parsed.malformed.count)",
                    "line\(parsed.malformed.count == 1 ? "" : "s") without a “;” — skipped"
                    + malformedTail(parsed.malformed),
                    color: .orange)
            }
            if parsed.considered == 0 {
                Text("No account lines found in that file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(LV.panel))
    }

    private func row(_ number: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(minWidth: 26, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func malformedTail(_ lines: [Int]) -> String {
        let shown = lines.prefix(5).map(String.init).joined(separator: ", ")
        return lines.count > 5 ? " (lines \(shown), …)" : " (line\(lines.count == 1 ? "" : "s") \(shown))"
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a combo list — one username;password per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        readError = nil
        parsed = nil
        // Combo lists are ASCII in practice but not always tagged; fall back to Latin-1
        // so an odd byte does not throw the whole file away.
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin1
        } else {
            readError = "That file could not be read as text."
            fileURL = url
            return
        }
        fileURL = url
        parsed = ComboImport.parse(text)
    }

    private func performImport() {
        guard let parsed else { return }
        let result = store.importCombos(parsed, folder: resolvedFolder)
        onDone(result)
        dismiss()
    }
}
