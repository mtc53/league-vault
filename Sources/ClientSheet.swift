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

    /// Icon, challenge reset, and optionally friends — in one pass.
    func runQuickPrep(setIcon: Bool, iconId: Int, clearChallenges: Bool,
                      removeFriends: Bool, appearOffline: Bool) async -> [String] {
        guard let credentials else { return ["Not connected to the client."] }
        busy = true
        defer { busy = false; friendProgress = nil }

        let outcome = await LCU.runQuickPrep(credentials: credentials,
                                             setIcon: setIcon, iconId: iconId,
                                             clearChallenges: clearChallenges,
                                             removeFriends: removeFriends,
                                             renameFrom: QuickPrep.renames ? QuickPrep.namePoolURL : nil,
                                             availability: appearOffline ? .offline : nil) { text in
            self.friendProgress = text
        }

        var report: [String] = []
        if let rename = outcome.rename {
            if let picked = rename.renamedTo {
                report.append("Renamed to \(picked.riotID), confirmed — name removed from the list.")
            } else if !rename.attempts.isEmpty {
                report.append("Rename did not take for "
                    + rename.attempts.map { "“\($0.name)”" }.joined(separator: " and ")
                    + " — Riot ID left alone.")
            }
            if let problem = rename.poolError { report.append(problem) }
        }
        if let error = outcome.iconError {
            report.append("Icon failed: \(error)")
        } else if let set = outcome.iconSet {
            report.append(outcome.iconFellBack
                ? "Icon \(outcome.iconRequested ?? set) is not owned — set \(set) instead."
                : "Icon set to \(set).")
        }

        if let reset = outcome.challenges {
            if reset.allSucceeded {
                report.append("Challenge badges, title and banner cleared.")
            } else {
                var done: [String] = []
                if reset.badgesCleared { done.append("badges") }
                if reset.titleCleared { done.append("title") }
                if reset.bannerCleared { done.append("banner") }
                report.append(done.isEmpty
                    ? "Challenge reset was refused by the client."
                    : "Cleared \(done.joined(separator: ", ")); the rest was refused.")
            }
        }

        if let wanted = outcome.availabilityWanted {
            report.append(outcome.availability == wanted
                ? "Chat set to \(wanted.display.lowercased())."
                : "Chat would not stay \(wanted.display.lowercased()) — it is \(outcome.availability?.display.lowercased() ?? "unknown").")
        }
        if let removed = outcome.friendsRemoved {
            let failed = outcome.friendsFailed ?? 0
            report.append(failed == 0
                ? "Removed \(removed) friends."
                : "Removed \(removed) friends, \(failed) failed.")
        }

        await probe()
        return report
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
    @State private var showIconPicker = false
    @State private var prepSetIcon = QuickPrep.setsIcon
    @State private var prepIconId = QuickPrep.iconId
    @State private var prepClearChallenges = QuickPrep.clearsChallenges
    @State private var prepRemoveFriends = QuickPrep.removesFriends
    @State private var prepRenames = QuickPrep.renames
    @State private var prepOffline = QuickPrep.appearsOffline
    @State private var confirmPrep = false
    @State private var prepReport: [String] = []
    @State private var scanning = false
    @State private var scan: LCU.BehaviourScan?
    @State private var scanned = false

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
                        behaviourBlock
                        Divider()
                        quickPrepBlock
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
        .background(LV.bg2)
        .tint(LV.accent)
        .task { await model.probe() }
        .sheet(isPresented: $showIconPicker) {
            if let credentials = model.credentials {
                IconPickerSheet(credentials: credentials,
                                currentIconId: model.summoner?.profileIconId) { applied in
                    toast = "Profile icon set to \(applied)."
                    Task { await model.probe() }
                }
            }
        }
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
                                tint: LV.accent,
                                size: 48,
                                corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(me.riotID)
                            .font(.system(size: 15, weight: .semibold))
                            .textSelection(.enabled)
                        Button("Change icon…") { showIconPicker = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    HStack(spacing: 6) {
                        if let region = model.region {
                            Chip(text: region.display, color: .secondary)
                        }
                        if let level = me.summonerLevel {
                            Chip(text: "Level \(level)", color: .secondary)
                        }
                        if let honor = model.snapshot?.honor?.level {
                            Chip(text: "Honor \(honor)", color: honor >= 3 ? .green : .orange)
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
                            Chip(text: "In vault: \(linked.displayName)", color: LV.accent)
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

    /// The client shows behaviour penalties in its own UI, so an endpoint exists for
    /// them. Rather than hard-code a guess, ask the client's /help catalogue.
    private var behaviourBlock: some View {
        FormSection("Behaviour & penalties") {
            Text("The client knows your honor standing and active penalties. This asks it which endpoints serve that, then reads each one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task {
                        scanning = true
                        defer { scanning = false }
                        if let credentials = model.credentials {
                            scan = await LCU.scanBehaviourEndpoints(credentials: credentials)
                            scanned = true
                        }
                    }
                } label: {
                    if scanning {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Label("Scan for penalty endpoints", systemImage: "magnifyingglass")
                    }
                }
                .disabled(scanning)

                if scanned {
                    Button("Reveal report in Finder") {
                        NSWorkspace.shared.selectFile(
                            LCU.diagnosticsDirectory.appendingPathComponent("scan.txt").path,
                            inFileViewerRootedAtPath: LCU.diagnosticsDirectory.path)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                if let scan, !scan.withData.isEmpty || !scan.empty.isEmpty {
                    Button("Copy all") {
                        var text = "catalogue: \(scan.helpWorked ? "\(scan.catalogueSize) matching paths" : "unavailable")"
                        text += " · \(scan.totalEndpoints) endpoints total\n"
                        text += scan.catalogueLog.map { "  " + $0 }.joined(separator: "\n") + "\n"
                        if !scan.plugins.isEmpty {
                            text += "\nbehaviour-ish plugins: " + scan.plugins.joined(separator: ", ") + "\n"
                        }
                        text += "\n"
                        text += scan.withData.map { "=== \($0.path) ===\n\($0.body)" }.joined(separator: "\n\n")
                        if !scan.empty.isEmpty {
                            text += "\n\n=== exists but empty ===\n" + scan.empty.joined(separator: "\n")
                        }
                        if !scan.missing.isEmpty {
                            text += "\n\n=== not present ===\n" + scan.missing.joined(separator: "\n")
                        }
                        if !scan.snippets.isEmpty {
                            text += "\n\n=== catalogue context ===\n" + scan.snippets.joined(separator: "\n")
                        }
                        Clipboard.copy(text)
                        toast = "Copied \(scan.withData.count) responses."
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                Spacer()
            }

            if let scan {
                VStack(alignment: .leading, spacing: 1) {
                    Text(scan.totalEndpoints > 0
                         ? "Catalogue: \(scan.totalEndpoints) endpoints, \(scan.catalogueSize) matching."
                         : "No catalogue answered — only the known paths were tried.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !scan.plugins.isEmpty {
                        Text("Plugins: " + scan.plugins.joined(separator: ", "))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(scan.catalogueLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if scanned, let scan, scan.withData.isEmpty {
                Text("Nothing returned data. Penalty endpoints may only answer while a game session is active.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let scan, !scan.empty.isEmpty {
                Text("Exists but empty: " + scan.empty.joined(separator: ", "))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let scan, !scan.missing.isEmpty {
                Text("Not present: \(scan.missing.count) paths")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if scanned {
                Text("Written to ~/Library/Application Support/LeagueVault/diagnostics/")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let scan, !scan.snippets.isEmpty {
                Text("\(scan.snippets.count) catalogue matches — included in Copy all")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if let scan, !scan.withData.isEmpty {
                Text("\(scan.withData.count) endpoint\(scan.withData.count == 1 ? "" : "s") returned data:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scan.withData, id: \.path) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.path)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(result.body.count > 900
                                     ? String(result.body.prefix(900)) + "…"
                                     : result.body)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(LV.panel))
            }
        }
    }

    private var prepSummary: [String] {
        var steps: [String] = []
        if prepSetIcon {
            steps.append(prepIconId == QuickPrep.preferredIconId
                         ? "set the profile icon to 6923, falling back to 1151 then 29"
                         : "set the profile icon to \(prepIconId), falling back through the rest of the chain")
        }
        if prepRenames && QuickPrep.namePoolURL != nil { steps.append("rename it from the name list") }
        if prepOffline { steps.append("set chat to appear offline") }
        if prepClearChallenges { steps.append("clear the challenge badges, title and banner") }
        if prepRemoveFriends { steps.append("remove all \(model.friends.count) friends — permanently") }
        return steps
    }

    private var quickPrepBlock: some View {
        FormSection("Quick prep") {
            Text("One button to make an account look untouched.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                ProfileIconView(iconId: prepSetIcon ? prepIconId : model.summoner?.profileIconId,
                                initials: "?", tint: LV.accent, size: 46, corner: 9)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("Set profile icon", isOn: $prepSetIcon)
                            .toggleStyle(.checkbox)
                        Picker("", selection: $prepIconId) {
                            Text("6923 — preferred").tag(QuickPrep.preferredIconId)
                            Text("1151 — second choice").tag(QuickPrep.secondIconId)
                            Text("29 — always owned").tag(QuickPrep.fallbackIconId)
                        }
                        .labelsHidden()
                        .frame(width: 165)
                        .disabled(!prepSetIcon)
                    }
                    if prepSetIcon && prepIconId == QuickPrep.preferredIconId {
                        Text("If the account does not own 6923 it tries 1151, then 29 — Riot resets an unowned icon server-side.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Clear challenge badges, title and banner", isOn: $prepClearChallenges)
                        .toggleStyle(.checkbox)

                    Toggle("Rename from the name list", isOn: $prepRenames)
                        .toggleStyle(.checkbox)
                        .disabled(QuickPrep.namePoolURL == nil)
                    if QuickPrep.namePoolURL == nil {
                        Text("Choose a name list first, in Cycle Accounts.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else if prepRenames, let left = QuickPrep.namesRemaining {
                        Text("\(left) name\(left == 1 ? "" : "s") left; the one used is deleted from the file. Two refusals and the Riot ID is left alone.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Appear offline in chat", isOn: $prepOffline)
                        .toggleStyle(.checkbox)
                    if prepOffline {
                        Text("Sets the client's own chat status to offline, and puts it back whenever Riot resets it — which it does on entering a lobby or a game.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(model.friends.isEmpty
                           ? "Remove all friends"
                           : "Remove all \(model.friends.count) friends",
                           isOn: $prepRemoveFriends)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(prepRemoveFriends ? Color.orange : Color.primary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    confirmPrep = true
                } label: {
                    if model.busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Label("Run Quick Prep", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || prepSummary.isEmpty)

                if let progress = model.friendProgress {
                    Text(progress).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !prepReport.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(prepReport, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if prepRemoveFriends {
                Text("Friend removal cannot be undone. Everything else here can be set back by hand.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: prepSetIcon) { _, v in QuickPrep.setsIcon = v }
        .onChange(of: prepIconId) { _, v in QuickPrep.iconId = v }
        .onChange(of: prepClearChallenges) { _, v in QuickPrep.clearsChallenges = v }
        .onChange(of: prepRemoveFriends) { _, v in QuickPrep.removesFriends = v }
        .onChange(of: prepRenames) { _, v in QuickPrep.renames = v }
        .onChange(of: prepOffline) { _, v in QuickPrep.appearsOffline = v }
        .alert("Run quick prep on \(model.summoner?.riotID ?? "this account")?", isPresented: $confirmPrep) {
            Button("Cancel", role: .cancel) { }
            Button(prepRemoveFriends ? "Run — removes friends" : "Run",
                   role: prepRemoveFriends ? .destructive : nil) {
                Task {
                    prepReport = await model.runQuickPrep(setIcon: prepSetIcon,
                                                          iconId: prepIconId,
                                                          clearChallenges: prepClearChallenges,
                                                          removeFriends: prepRemoveFriends,
                                                          appearOffline: prepOffline)
                }
            }
        } message: {
            Text("This will " + prepSummary.joined(separator: ", then ") + ".")
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
                .background(RoundedRectangle(cornerRadius: 6).fill(LV.panel))

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
                    .background(RoundedRectangle(cornerRadius: 6).fill(LV.panel))

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
            for entry in snapshot.ranks { account.applyLiveRank(entry) }
            if let honor = snapshot.honor {
                account.honorLevel = honor.level
                account.replaceClientPenalties(with: LCU.penalties(from: snapshot.behaviour ?? LCU.BehaviourSnapshot(honor: honor)))
            }
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
