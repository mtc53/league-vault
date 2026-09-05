import SwiftUI
import AppKit

@MainActor
final class ClientModel: ObservableObject {
    @Published var credentials: LCUCredentials?
    @Published var snapshot: LCU.Snapshot?
    @Published var summoner: LCUSummoner?
    @Published var region: Region?
    @Published var status: String = "Looking for the League client…"
    @Published var isConnected = false
    @Published var busy = false
    @Published var lastError: String?
    @Published var friends: [LCU.Friend] = []
    @Published var friendProgress: String?

    func probe() async {
        busy = true
        defer { busy = false }
        lastError = nil

        guard let found = LCU.discover() else {
            credentials = nil; snapshot = nil; summoner = nil; region = nil; isConnected = false; friends = []
            status = "League client not running."
            return
        }
        credentials = found

        do {
            let snap = try await LCU.snapshot(credentials: found)
            snapshot = snap
            friends = await LCU.friends(credentials: found)
            summoner = snap.summoner
            region = snap.region
            isConnected = true
            status = "Connected on port \(found.port)."
        } catch {
            snapshot = nil
            summoner = nil
            isConnected = false
            status = "Client found, but not ready."
            lastError = error.localizedDescription
        }
    }

    func removeAllFriends() async -> (removed: Int, failed: Int) {
        guard let credentials else { return (0, 0) }
        busy = true
        defer { busy = false; friendProgress = nil }
        let result = await LCU.removeAllFriends(credentials: credentials) { done, total in
            self.friendProgress = "Removing \(done) of \(total)…"
        }
        friends = await LCU.friends(credentials: credentials)
        return result
    }

    func rename(to gameName: String, tag: String) async -> Bool {
        guard let credentials else { return false }
        busy = true
        defer { busy = false }
        do {
            try await LCU.changeRiotID(gameName: gameName, tagLine: tag, credentials: credentials)
            lastError = nil
            await probe()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

struct ClientSheet: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ClientModel()

    @State private var newName = ""
    @State private var newTag = ""
    @State private var confirmRename = false
    @State private var toast: String?
    @State private var showDiagnostics = false
    @State private var probePath = "/lol-inventory/v1/wallet"
    @State private var probeResult = ""
    @State private var probing = false
    @State private var confirmRemoveFriends = false

    /// The vault entry, if any, that matches the signed-in account.
    private var linkedAccount: Account? {
        guard let puuid = model.summoner?.puuid else { return nil }
        return store.accounts.first { $0.puuid == puuid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("League Client")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    Task { await model.probe() }
                } label: {
                    if model.busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.busy)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusBlock

                    if model.isConnected, let me = model.summoner {
                        Divider()
                        signedInBlock(me)
                        Divider()
                        renameBlock(me)
                        Divider()
                        vaultBlock(me)
                        Divider()
                        friendsBlock
                        Divider()
                        diagnosticsBlock
                    } else {
                        Divider()
                        helpBlock
                    }
                }
                .padding(20)
            }
            .frame(height: 470)

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
        .frame(width: 580)
        .task { await model.probe() }
        .alert("Change your Riot ID?", isPresented: $confirmRename) {
            Button("Cancel", role: .cancel) { }
            Button("Change Riot ID") {
                Task {
                    let from = model.summoner?.riotID ?? ""
                    if await model.rename(to: newName.trimmingCharacters(in: .whitespaces),
                                          tag: newTag.trimmingCharacters(in: .whitespaces)) {
                        syncVaultAfterRename()
                        toast = "Changed \(from) → \(model.summoner?.riotID ?? "")"
                    }
                }
            }
        } message: {
            Text("This renames the account signed in to the League client right now — \(model.summoner?.riotID ?? "")  →  \(newName)#\(newTag).\n\nRiot limits how often a Riot ID can change, and the old one is released. The client, not this app, decides whether to accept it.")
        }
    }

    // MARK: Blocks

    private var statusBlock: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.system(size: 13, weight: .medium))
                if let error = model.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private func signedInBlock(_ me: LCUSummoner) -> some View {
        FormSection("Signed in as") {
            HStack(spacing: 12) {
                ProfileIconView(iconId: me.profileIconId,
                                initials: String(me.gameName.prefix(1)).uppercased(),
                                tint: .accentColor,
                                size: 48,
                                corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(me.riotID)
                        .font(.system(size: 15, weight: .semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let region = model.region {
                            Chip(text: region.display, color: .secondary)
                        }
                        if let level = me.summonerLevel {
                            Chip(text: "Level \(level)", color: .secondary)
                        }
                        if let count = model.snapshot?.champions.count, count > 0 {
                            Chip(text: "\(count) champions", color: .secondary)
                        }
                        if let be = model.snapshot?.blueEssence {
                            Chip(text: "\(be.grouped) BE", color: Color(red: 0.35, green: 0.62, blue: 0.92))
                        }
                        if let rp = model.snapshot?.riotPoints {
                            Chip(text: "\(rp.grouped) RP", color: Color(red: 0.90, green: 0.55, blue: 0.30))
                        }
                        if let snapshot = model.snapshot,
                           snapshot.blueEssence == nil, snapshot.riotPoints == nil {
                            Chip(text: "wallet unavailable", color: .orange)
                        }
                        if let linked = linkedAccount {
                            Chip(text: "In vault: \(linked.displayName)", color: .accentColor)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func renameBlock(_ me: LCUSummoner) -> some View {
        FormSection("Change Riot ID") {
            HStack(spacing: 10) {
                Field("Game name") { TextField(me.gameName, text: $newName) }
                Field("Tag") {
                    HStack(spacing: 2) {
                        Text("#").foregroundStyle(.secondary)
                        TextField(me.tagLine, text: $newTag)
                    }
                }
                .frame(width: 130)
            }

            HStack(spacing: 10) {
                Button("Change Riot ID") { confirmRename = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || !renameIsValid)
                Text(renameIsValid
                     ? "\(me.riotID)  →  \(newName.trimmingCharacters(in: .whitespaces))#\(newTag.trimmingCharacters(in: .whitespaces))"
                     : "Enter a new name and tag.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("Goes to the running client over 127.0.0.1 (POST /lol-summoner/v1/save-alias) — the same call the client's own settings make. Riot enforces availability and cooldown server-side. This is an unofficial client API, so a patch can change or remove it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func vaultBlock(_ me: LCUSummoner) -> some View {
        FormSection("Vault") {
            if let linked = linkedAccount {
                HStack(spacing: 10) {
                    Button("Update “\(linked.displayName)” from client") {
                        applyToVault(existing: linked, me: me)
                        toast = "Updated \(linked.displayName)."
                    }
                    Spacer()
                }
                Text("Copies the Riot ID, region, level, profile icon, both ranked queues, the last game, the champion list and the wallet across.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    Button("Add this account to the vault") {
                        applyToVault(existing: nil, me: me)
                        toast = "Added \(me.riotID)."
                    }
                    Spacer()
                }
                Text("No vault entry matches this PUUID yet. Adding it fills in the Riot ID, region, level, profile icon, rank, last game, owned champions and wallet straight from the client.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var friendsBlock: some View {
        FormSection("Friends") {
            if model.friends.isEmpty {
                Text("No friends on this account, or the client did not return the list.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.friends.count) friend\(model.friends.count == 1 ? "" : "s") on \(model.summoner?.riotID ?? "this account").")
                    .font(.system(size: 12))

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.friends) { friend in
                            Text(friend.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(model.friends.count) * 16 + 12, 96))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        confirmRemoveFriends = true
                    } label: {
                        Text("Remove All Friends…")
                    }
                    .disabled(model.busy)

                    if let progress = model.friendProgress {
                        Text(progress)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text("Deletes every friend from the signed-in account's list. The client offers no undo — re-adding means sending each request again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Remove all \(model.friends.count) friends?", isPresented: $confirmRemoveFriends) {
            Button("Cancel", role: .cancel) { }
            Button("Remove \(model.friends.count)", role: .destructive) {
                Task {
                    let result = await model.removeAllFriends()
                    toast = result.failed == 0
                        ? "Removed \(result.removed) friends."
                        : "Removed \(result.removed), \(result.failed) failed."
                }
            }
        } message: {
            Text("This removes every friend from \(model.summoner?.riotID ?? "the signed-in account"). It cannot be undone, and it affects your real account immediately.")
        }
    }

    private var diagnosticsBlock: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reads any LCU path and shows the raw reply. Useful when a field above comes back empty because this build guessed the wrong endpoint.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("/lol-inventory/v1/wallet", text: $probePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { Task { await runProbe() } }
                    Button {
                        Task { await runProbe() }
                    } label: {
                        if probing {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(probing || probePath.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 6) {
                    Text("Wallet candidates:")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(LCU.walletPaths.enumerated()), id: \.offset) { index, path in
                        Button("\(index + 1)") {
                            probePath = path
                            Task { await runProbe() }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .help(path)
                    }
                    Button("summoner") {
                        probePath = "/lol-summoner/v1/current-summoner"
                        Task { await runProbe() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }

                if !probeResult.isEmpty {
                    ScrollView {
                        Text(probeResult)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

                    Button("Copy response") {
                        Clipboard.copy(probeResult)
                        toast = "Response copied."
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Diagnostics")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
        }
    }

    private func runProbe() async {
        guard let credentials = model.credentials else { return }
        probing = true
        defer { probing = false }
        probeResult = await LCU.probe(path: probePath.trimmingCharacters(in: .whitespaces), credentials: credentials)
    }

    private var helpBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To use this, open League of Legends and sign in, then press Reconnect.")
                .font(.system(size: 12))
            Text("This app finds the client's local API by reading the port and token from the running client's own command line. Nothing is sent anywhere — the connection is to 127.0.0.1 on your Mac, and the token dies when the client closes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open League of Legends") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/League of Legends.app"))
            }
            .padding(.top, 2)
        }
    }

    // MARK: Helpers

    private var renameIsValid: Bool {
        let n = newName.trimmingCharacters(in: .whitespaces)
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !t.isEmpty else { return false }
        return "\(n)#\(t)" != (model.summoner?.riotID ?? "")
    }

    private func applyToVault(existing: Account?, me: LCUSummoner) {
        var account = existing ?? Account()
        account.applyRiotID(gameName: me.gameName, tagLine: me.tagLine)
        account.puuid = me.puuid
        account.summonerLevel = me.summonerLevel
        account.profileIconId = me.profileIconId
        if let region = model.region { account.region = region }
        if let snapshot = model.snapshot {
            for entry in snapshot.ranks { account.setRank(entry) }
            if let game = snapshot.lastGame { account.lastGame = game }
            if !snapshot.champions.isEmpty { account.ownedChampions = snapshot.champions }
            if let be = snapshot.blueEssence { account.blueEssence = be }
            if let rp = snapshot.riotPoints { account.riotPoints = rp }
        }
        account.lastRefreshed = Date()
        if account.label.isEmpty { account.label = me.gameName }
        if existing == nil {
            store.add(account)
        } else {
            store.update(account)
        }
    }

    /// After a successful rename, bring the matching vault entry along.
    private func syncVaultAfterRename() {
        guard let me = model.summoner, var linked = linkedAccount else { return }
        linked.applyRiotID(gameName: me.gameName, tagLine: me.tagLine)
        store.update(linked)
    }
}
