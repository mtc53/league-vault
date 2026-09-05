import SwiftUI
import AppKit

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All fields"
    case champion = "Champion"
    var id: String { rawValue }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case rank = "Rank"
    case lastPlayed = "Last played"
    case activity = "Games (3mo)"
    case region = "Region"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var store: AccountStore

    @State private var selection: UUID?
    @State private var search = ""
    @State private var scope: SearchScope = .all
    @State private var dropTarget: String?
    @State private var championOnly: String?
    @State private var showChampionPicker = false
    @State private var championQuery = ""
    @State private var sort: SortOrder = .name
    @State private var penaltiesOnly = false
    @State private var groupByFolder = true
    @State private var editing: Account?
    @State private var creatingNew = false
    @State private var showSettings = false
    @State private var showClient = false
    @State private var refreshingIDs: Set<UUID> = []
    @State private var banner: Banner?
    @State private var confirmDelete: Account?
    @State private var newFolderTarget: Account?
    @State private var renamingFolder: String?

    struct Banner: Identifiable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    // MARK: Derived data

    private var filtered: [Account] {
        var list = store.accounts

        if penaltiesOnly { list = list.filter(\.hasActivePenalty) }
        if let championOnly {
            list = list.filter { account in
                account.ownedChampions.contains {
                    $0.name.compare(championOnly, options: .caseInsensitive) == .orderedSame
                }
            }
        }

        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, scope == .champion {
            list = list.filter { $0.owns(championMatching: q) }
        } else if !q.isEmpty {
            list = list.filter {
                $0.matchesAccessToken(q)
                || $0.label.lowercased().contains(q)
                || $0.riotID.lowercased().contains(q)
                || $0.loginUsername.lowercased().contains(q)
                || $0.region.display.lowercased().contains(q)
                || $0.folder.lowercased().contains(q)
                || $0.notes.lowercased().contains(q)
            }
        }
        return sorted(list)
    }

    private func sorted(_ input: [Account]) -> [Account] {
        var list = input
        switch sort {
        case .name:
            list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .region:
            list.sort { ($0.region.display, $0.displayName) < ($1.region.display, $1.displayName) }
        case .rank:
            list.sort { rankWeight($0) > rankWeight($1) }
        case .lastPlayed:
            list.sort { ($0.lastGame?.playedAt ?? .distantPast) > ($1.lastGame?.playedAt ?? .distantPast) }
        case .activity:
            // Never-counted accounts sort last rather than pretending to be zero.
            list.sort { ($0.recentGames ?? -1) > ($1.recentGames ?? -1) }
        }
        return list
    }

    private func rankWeight(_ a: Account) -> Int {
        let r = a.soloRank
        guard r.tier != .unranked else {
            // Unranked: order by peak, but always beneath anyone currently ranked.
            return (Tier.allCases.firstIndex(of: r.peakTier) ?? 0) * 100
        }
        let tierIndex = Tier.allCases.firstIndex(of: r.tier) ?? 0
        let divisionIndex = r.tier.isApex ? 4 : (4 - (Division.allCases.firstIndex(of: r.division) ?? 0))
        return tierIndex * 10_000 + divisionIndex * 1_000 + r.lp
    }

    /// Folder name → accounts, unfiled last.
    private var folderGroups: [(name: String, accounts: [Account])] {
        let grouped = Dictionary(grouping: filtered) { $0.folder }
        let names = grouped.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return names.map { ($0, grouped[$0] ?? []) }
    }

    /// Champion → number of accounts that own it, across the whole vault.
    private var championIndex: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for account in store.accounts {
            // One account counts once per champion even if listed twice.
            for name in Set(account.ownedChampions.map(\.name)) {
                counts[name, default: 0] += 1
            }
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every folder that exists across the whole library, for the Move-to menu.
    private var allFolders: [String] {
        Array(Set(store.accounts.map(\.folder).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Body

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 400)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $creatingNew) {
            AccountEditor(account: Account(), isNew: true, knownFolders: allFolders) { saved in
                store.add(saved)
                selection = saved.id
            }
            .environmentObject(store)
        }
        .sheet(item: $editing) { account in
            AccountEditor(account: account, isNew: false, knownFolders: allFolders) { saved in
                store.update(saved)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .sheet(isPresented: $showClient) {
            ClientSheet().environmentObject(store)
        }
        .sheet(item: $newFolderTarget) { account in
            NameFolderSheet(title: "New Folder", initial: "") { name in
                var updated = account
                updated.folder = name
                store.update(updated)
                banner = Banner(text: "Moved \(updated.displayName) to “\(name)”.", isError: false)
            }
        }
        .sheet(item: Binding(
            get: { renamingFolder.map { FolderName(name: $0) } },
            set: { renamingFolder = $0?.name }
        )) { wrapper in
            NameFolderSheet(title: "Rename Folder", initial: wrapper.name) { name in
                store.renameFolder(from: wrapper.name, to: name)
                banner = Banner(text: "Renamed folder to “\(name)”.", isError: false)
            }
        }
        .alert(item: $confirmDelete) { account in
            Alert(
                title: Text("Delete “\(account.displayName)”?"),
                message: Text("This removes the account and its stored password from this Mac. It does not affect the Riot account itself."),
                primaryButton: .destructive(Text("Delete")) {
                    if selection == account.id { selection = nil }
                    store.delete(id: account.id)
                },
                secondaryButton: .cancel()
            )
        }
        .overlay(alignment: .bottom) { bannerView }
        .frame(minWidth: 980, minHeight: 640)
    }

    struct FolderName: Identifiable { var name: String; var id: String { name } }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if groupByFolder {
                    ForEach(folderGroups, id: \.name) { group in
                        Section {
                            ForEach(group.accounts) { account in
                                row(account)
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Image(systemName: group.name.isEmpty ? "tray" : "folder")
                                    .font(.system(size: 9))
                                Text(group.name.isEmpty ? "Unfiled" : group.name)
                                Spacer()
                                Text("\(group.accounts.count)")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(dropTarget == group.name ? Color.accentColor.opacity(0.3) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        dropTarget == group.name ? Color.accentColor : .clear,
                                        style: StrokeStyle(lineWidth: 1, dash: [3])
                                    )
                            )
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { payloads, _ in
                                receiveDrop(payloads, into: group.name)
                            } isTargeted: { targeted in
                                dropTarget = targeted ? group.name : nil
                            }
                            .contextMenu {
                                if !group.name.isEmpty {
                                    Button("Rename Folder…") { renamingFolder = group.name }
                                    Button("Empty Folder") {
                                        store.renameFolder(from: group.name, to: "")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(filtered) { account in
                        row(account)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(spacing: 5) {
                if let championOnly {
                    HStack(spacing: 6) {
                        Image(systemName: "person.3.fill").font(.system(size: 9))
                        Text("Owns \(championOnly)")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button {
                            self.championOnly = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                    )
                    .padding(.horizontal, 10)
                }

                HStack(spacing: 10) {
                    Toggle(isOn: $penaltiesOnly) {
                        Label("Penalties", systemImage: "exclamationmark.triangle")
                    }
                    .toggleStyle(.checkbox)

                    Toggle("Folders", isOn: $groupByFolder)
                        .toggleStyle(.checkbox)

                    Button {
                        showChampionPicker = true
                    } label: {
                        Label("Champion", systemImage: "person.3")
                    }
                    .buttonStyle(.link)
                    .popover(isPresented: $showChampionPicker, arrowEdge: .top) {
                        championPicker
                    }

                    Spacer()

                    Text("\(filtered.count)/\(store.accounts.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 7)
        }
        .searchable(text: $search, placement: .sidebar, prompt: searchPrompt)
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    /// Pick a champion and the sidebar narrows to accounts that own it.
    private var championPicker: some View {
        let all = championIndex
        let matches = championQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(championQuery) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Show accounts that own")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Viktor", text: $championQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            if all.isEmpty {
                Text("No champion lists yet. Refresh an account with the League client signed in to pull its inventory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240)
            } else if matches.isEmpty {
                Text("No champion matches “\(championQuery)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(matches, id: \.name) { entry in
                            Button {
                                championOnly = entry.name
                                showChampionPicker = false
                                championQuery = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(entry.count)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 260)
            }

            if championOnly != nil {
                Divider()
                Button("Clear filter") {
                    championOnly = nil
                    showChampionPicker = false
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func row(_ account: Account) -> some View {
        AccountRow(account: account, isRefreshing: refreshingIDs.contains(account.id))
            .tag(account.id)
            .contextMenu { rowMenu(account) }
            .draggable(account.id.uuidString)
    }

    private var searchPrompt: String {
        scope == .champion ? "Champion the account owns" : "Search accounts"
    }

    /// Moves dragged accounts into `folder`. The payload is each account's UUID.
    ///
    /// The move is applied on the *next* runloop turn, never inline. Re-filing an
    /// account rebuilds the sidebar's sections, and doing that while AppKit is still
    /// inside the drop event frees the row its outline view is tracking — which
    /// crashes in -[NSOutlineView rowForItem:]. Returning true first lets the drag
    /// finish, then the list rebuilds on its own terms.
    private func receiveDrop(_ payloads: [String], into folder: String) -> Bool {
        let ids = payloads.compactMap { UUID(uuidString: $0) }
        guard !ids.isEmpty else { return false }

        DispatchQueue.main.async {
            var moved: [Account] = []
            for id in ids {
                guard var account = store.accounts.first(where: { $0.id == id }),
                      account.folder != folder else { continue }
                account.folder = folder
                store.update(account)
                moved.append(account)
            }
            guard let first = moved.first else { return }
            // Selection is a UUID and the account keeps its identity across the move,
            // so it survives on its own — no need to re-assert it here.
            banner = Banner(
                text: folder.isEmpty
                    ? "Moved \(first.displayName) out of its folder."
                    : "Moved \(first.displayName) to “\(folder)”.",
                isError: false
            )
        }
        return true
    }

    @ViewBuilder
    private func rowMenu(_ account: Account) -> some View {
        Button("Edit…") { editing = account }
        Button("Refresh") { Task { await refreshOne(account) } }

        Divider()

        Menu("Move to") {
            ForEach(allFolders, id: \.self) { folder in
                Button {
                    var updated = account
                    updated.folder = folder
                    store.update(updated)
                } label: {
                    if account.folder == folder {
                        Label(folder, systemImage: "checkmark")
                    } else {
                        Text(folder)
                    }
                }
            }
            if !allFolders.isEmpty { Divider() }
            Button("New Folder…") { newFolderTarget = account }
            if !account.folder.isEmpty {
                Button("Remove from Folder") {
                    var updated = account
                    updated.folder = ""
                    store.update(updated)
                }
            }
        }

        Divider()

        if let url = account.uggURL {
            Button("Copy u.gg Link") {
                Clipboard.copy(url.absoluteString)
                banner = Banner(text: "u.gg link copied.", isError: false)
            }
            Button("Open on u.gg") { NSWorkspace.shared.open(url) }
        }
        Button("Copy Riot ID") { Clipboard.copy(account.riotID) }
        if !account.loginUsername.isEmpty {
            Button("Copy Username") { Clipboard.copy(account.loginUsername) }
        }
        if account.encryptedPassword != nil {
            Button("Copy Password") {
                if let pw = store.password(for: account) {
                    Clipboard.copy(pw, clearAfter: 45)
                    banner = Banner(text: "Password copied — clipboard clears in 45s.", isError: false)
                }
            }
        }

        Divider()

        Button("Delete…", role: .destructive) { confirmDelete = account }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let account = store.accounts.first(where: { $0.id == id }) {
            AccountDetailView(
                account: account,
                isRefreshing: refreshingIDs.contains(account.id),
                onEdit: { editing = account },
                onDelete: { confirmDelete = account },
                onRefresh: { Task { await refreshOne(account) } },
                onNotify: { text, isError in banner = Banner(text: text, isError: isError) },
                onOpenClient: { showClient = true }
            )
            .environmentObject(store)
        } else if store.accounts.isEmpty {
            EmptyState(
                title: "No accounts yet",
                message: "Sign in to League on this Mac and import the account straight from the client — rank, last game, server and icon come with it, no API key needed. Or add one by hand.",
                actionTitle: "Import from League Client",
                action: { showClient = true },
                secondaryTitle: "Add Manually",
                secondaryAction: { creatingNew = true }
            )
        } else {
            EmptyState(
                title: "Select an account",
                message: "Pick an account from the list to see its details.",
                actionTitle: nil,
                action: nil
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Sort", selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Button {
                Task { await refreshAll() }
            } label: {
                Label("Refresh All", systemImage: "arrow.clockwise")
            }
            .disabled(store.accounts.isEmpty || !refreshingIDs.isEmpty)
            .help("Update every account — from the running League client, or the web API if a key is set")

            Button { showClient = true } label: {
                Label("League Client", systemImage: "bolt.horizontal.circle")
            }
            .help("Connect to the running League client: rename your Riot ID, or import the signed-in account")

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button { creatingNew = true } label: {
                Label("Add Account", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            HStack(spacing: 8) {
                Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                Text(banner.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { self.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(banner.isError ? Color.red.opacity(0.92) : Color.accentColor.opacity(0.95))
            )
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: banner.isError ? 9_000_000_000 : 4_000_000_000)
                withAnimation { self.banner = nil }
            }
        }
    }

    // MARK: Refresh

    enum RefreshOutcome {
        case updated(String)
        case skipped(String)
        case failed(String)
    }

    /// Does the running client's signed-in account correspond to this vault entry?
    private func isSameAccount(_ account: Account, _ me: LCUSummoner) -> Bool {
        if let puuid = account.puuid, !puuid.isEmpty { return puuid == me.puuid }
        // An entry added with only a login adopts whoever is signed in, which is the
        // point of adding one that way.
        if account.isUnidentified { return true }
        guard !account.gameName.isEmpty else { return false }
        return account.riotID.compare(me.riotID, options: .caseInsensitive) == .orderedSame
    }

    private func apply(_ snapshot: LCU.Snapshot, to account: Account) -> Account? {
        guard var current = store.accounts.first(where: { $0.id == account.id }) else { return nil }
        let me = snapshot.summoner
        current.puuid = me.puuid
        current.applyRiotID(gameName: me.gameName, tagLine: me.tagLine)
        current.summonerLevel = me.summonerLevel
        if let icon = me.profileIconId { current.profileIconId = icon }
        if let region = snapshot.region { current.region = region }
        for entry in snapshot.ranks { current.setRank(entry) }
        if let game = snapshot.lastGame { current.lastGame = game }
        if !snapshot.champions.isEmpty { current.ownedChampions = snapshot.champions }
        if let be = snapshot.blueEssence { current.blueEssence = be }
        if let rp = snapshot.riotPoints { current.riotPoints = rp }
        if let count = snapshot.recentGames {
            current.recentGames = count
            current.recentGamesAsOf = Date()
        }
        if let honor = snapshot.honor {
            current.honorLevel = honor.level
            // Only client-reported penalties are replaced; hand-entered ones stay.
            current.replaceClientPenalties(with: LCU.penalties(from: snapshot.behaviour ?? LCU.BehaviourSnapshot(honor: honor)))
        }
        current.lastRefreshed = Date()
        store.update(current)
        return current
    }

    /// Everything comes from the running League client. No keys, no rate limits,
    /// and nothing leaves this Mac.
    @discardableResult
    private func refresh(_ account: Account) async -> RefreshOutcome {
        refreshingIDs.insert(account.id)
        defer { refreshingIDs.remove(account.id) }

        guard let credentials = LCU.discover() else {
            return .skipped(account.isUnidentified
                ? "Open the League client and sign in as \(account.displayName) — the first refresh links this entry to it."
                : "Open the League client and sign in to \(account.displayName) to refresh it.")
        }

        let snapshot: LCU.Snapshot
        do {
            snapshot = try await LCU.snapshot(credentials: credentials)
        } catch {
            return .failed("\(account.displayName): \(error.localizedDescription)")
        }

        guard isSameAccount(account, snapshot.summoner) else {
            return .skipped("The client is signed in as \(snapshot.summoner.riotID), not \(account.displayName). Log into that account to refresh it.")
        }

        let before = account.riotID
        let wasUnidentified = account.isUnidentified
        guard let updated = apply(snapshot, to: account) else {
            return .failed("\(account.displayName): vanished mid-refresh.")
        }
        if wasUnidentified {
            return .updated("Linked to \(updated.riotID) and filled in.")
        }
        if !before.isEmpty && before != updated.riotID {
            return .updated("Riot ID changed: \(before) → \(updated.riotID).")
        }
        return .updated("Updated \(updated.displayName) from the League client.")
    }

    private func refreshOne(_ account: Account) async {
        switch await refresh(account) {
        case .updated(let message): banner = Banner(text: message, isError: false)
        case .skipped(let message): banner = Banner(text: message, isError: true)
        case .failed(let message):  banner = Banner(text: message, isError: true)
        }
    }

    private func refreshAll() async {
        var updated = 0, skipped = 0, failed = 0
        var lastProblem: String?

        for account in store.accounts {
            switch await refresh(account) {
            case .updated: updated += 1
            case .skipped(let m): skipped += 1; lastProblem = m
            case .failed(let m):  failed += 1;  lastProblem = m
            }
            // Only the web-API path is rate limited; a short pause is harmless either way.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        var parts: [String] = ["Updated \(updated)"]
        if skipped > 0 { parts.append("\(skipped) not signed in to the client") }
        if failed > 0 { parts.append("\(failed) failed") }
        var text = parts.joined(separator: ", ") + "."
        if updated == 0, let lastProblem { text = lastProblem }
        banner = Banner(text: text, isError: updated == 0 && (skipped + failed) > 0)
    }
}

// MARK: - Row

struct AccountRow: View {
    var account: Account
    var isRefreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProfileIconView(iconId: account.profileIconId,
                            initials: initials,
                            tint: account.soloRank.effectiveTier.color,
                            size: 34,
                            corner: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let worst = account.worstActivePenalty {
                        Image(systemName: worst.kind == .queueDelay
                              ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: worst.kind.isCritical ? 11 : 10,
                                          weight: worst.kind.isCritical ? .bold : .regular))
                            .foregroundStyle(worst.kind.accent)
                            .help(account.activePenalties.map { "\($0.kind.rawValue): \($0.detail)" }
                                    .joined(separator: "\n"))
                    }
                }
                HStack(spacing: 5) {
                    Text(account.region.display)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    if account.access != .unknown {
                        Text(account.access.short)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(account.access == .fullAccess ? .green : .orange)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(account.soloRank.displayWithFallback)
                        .font(.system(size: 11))
                        .foregroundStyle(account.soloRank.tier == .unranked
                                         ? (account.soloRank.hasPeak ? account.soloRank.peakTier.color.opacity(0.85) : Color.secondary)
                                         : account.soloRank.tier.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let label = account.recentGamesLabel {
                        // Activity over the last three months, so a dormant smurf is
                        // obvious without opening it.
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(account.isDormant ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill((account.isDormant ? Color.secondary : Color.accentColor)
                                    .opacity(0.15))
                            )
                            .help(account.recentGamesAsOf.map {
                                "Games in the last 3 months, counted \($0.relativeDisplay)"
                            } ?? "Games in the last 3 months")
                    }
                }
            }

            Spacer(minLength: 0)

            if isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.vertical, 3)
    }

    private var initials: String {
        let source = account.label.isEmpty ? account.gameName : account.label
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Folder naming sheet

struct NameFolderSheet: View {
    var title: String
    var initial: String
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            TextField("Main, Smurfs, Duo accounts…", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onCommit(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = initial }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .controlSize(.large)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}
