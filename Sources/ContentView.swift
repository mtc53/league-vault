import SwiftUI
import AppKit

// The window is laid out the way the published dashboard is: a slim bar of actions, a
// hero that counts the vault up, one sticky strip of controls, then the accounts as
// splash-art cards or as a dense table. Opening one raises the same detail sheet the
// page raises. Anything the site can filter or sort by, this can too.

enum ViewMode: String, CaseIterable {
    case grid, list
}

enum SortOrder: String, CaseIterable, Identifiable {
    case rank = "Highest rank"
    case level = "Highest level"
    case champs = "Most champions"
    case be = "Most blue essence"
    case rp = "Most RP"
    case recent = "Recently played"
    case idle = "Longest idle"
    case name = "Name A–Z"
    case folder = "Folder"
    var id: String { rawValue }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case any = "Any status"
    case clean = "Nothing wrong"
    case penalised = "Has a penalty"
    case critical = "Blocked from play"
    case flagged = "Flagged by the cycle"
    var id: String { rawValue }
}

enum IdleFilter: String, CaseIterable, Identifiable {
    case any = "Any last played"
    case week = "Played this week"
    case month = "Played this month"
    case stale = "Idle 90+ days"
    case never = "Never played"
    var id: String { rawValue }
}

enum PlayerFilter: String, CaseIterable, Identifiable {
    case any = "Played by anyone"
    case me = "Last played by me"
    case someoneElse = "Last played by someone else"
    case unrecorded = "Player not recorded"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var web: WebDashboard
    @EnvironmentObject var watcher: ClientWatcher
    @EnvironmentObject var cycle: CycleRunner

    @State private var opened: OpenAccount?
    @State private var search = ""
    @State private var mode: ViewMode = .grid
    @State private var sort: SortOrder = .rank
    @State private var groupByFolder = false

    @State private var folderFilter: String?
    @State private var regionFilter: Region?
    @State private var tierFilter: Tier?
    @State private var accessFilter: AccessLevel?
    @State private var statusFilter: StatusFilter = .any
    @State private var idleFilter: IdleFilter = .any
    @State private var playerFilter: PlayerFilter = .any
    @State private var championOnly: String?
    @State private var championQuery = ""
    @State private var showChampionPicker = false

    @State private var dropTarget: String?
    @State private var editing: Account?
    @State private var creatingNew = false
    @State private var importingCombos = false
    @State private var showCycle = false
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

    /// The account the detail sheet is showing. Held by id so a refresh mid-sheet is
    /// picked up rather than frozen at the moment it opened.
    struct OpenAccount: Identifiable { var id: UUID }

    // MARK: Derived data

    private var filtered: [Account] {
        var list = store.accounts

        if let folderFilter { list = list.filter { $0.folder == folderFilter } }
        if let regionFilter { list = list.filter { $0.region == regionFilter } }
        if let tierFilter { list = list.filter { $0.soloRank.effectiveTier == tierFilter } }
        if let accessFilter { list = list.filter { $0.access == accessFilter } }

        switch statusFilter {
        case .any: break
        case .clean: list = list.filter { !$0.hasActivePenalty && !$0.isFlagged }
        case .penalised: list = list.filter(\.hasActivePenalty)
        case .critical: list = list.filter(\.hasCriticalPenalty)
        case .flagged: list = list.filter(\.isFlagged)
        }

        switch idleFilter {
        case .any: break
        case .week: list = list.filter { ($0.daysSinceLastGame ?? .max) <= 7 }
        case .month: list = list.filter { ($0.daysSinceLastGame ?? .max) <= 30 }
        case .stale: list = list.filter { ($0.daysSinceLastGame ?? -1) >= 90 }
        case .never: list = list.filter { $0.daysSinceLastGame == nil }
        }

        switch playerFilter {
        case .any: break
        case .me: list = list.filter { $0.lastGamePlayer == .me }
        case .someoneElse: list = list.filter { $0.lastGamePlayer == .someoneElse }
        case .unrecorded: list = list.filter { $0.lastGame != nil && $0.lastGamePlayer == .unknown }
        }

        if let championOnly {
            list = list.filter { account in
                account.ownedChampions.contains {
                    $0.name.compare(championOnly, options: .caseInsensitive) == .orderedSame
                }
            }
        }

        // One box, everything in it — the same fields the page searches.
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.matchesAccessToken(q)
                || $0.label.lowercased().contains(q)
                || $0.riotID.lowercased().contains(q)
                || $0.loginUsername.lowercased().contains(q)
                || $0.region.display.lowercased().contains(q)
                || $0.folder.lowercased().contains(q)
                || $0.notes.lowercased().contains(q)
                || $0.owns(championMatching: q)
            }
        }
        return sorted(list)
    }

    private func sorted(_ input: [Account]) -> [Account] {
        var list = input
        switch sort {
        case .name:
            list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .folder:
            list.sort { ($0.folder.isEmpty ? "\u{10FFFF}" : $0.folder, $0.displayName)
                      < ($1.folder.isEmpty ? "\u{10FFFF}" : $1.folder, $1.displayName) }
        case .rank:
            list.sort { $0.soloRank.sortWeight > $1.soloRank.sortWeight }
        case .level:
            list.sort { ($0.summonerLevel ?? 0) > ($1.summonerLevel ?? 0) }
        case .champs:
            list.sort { $0.ownedChampions.count > $1.ownedChampions.count }
        case .be:
            list.sort { ($0.blueEssence ?? 0) > ($1.blueEssence ?? 0) }
        case .rp:
            list.sort { ($0.riotPoints ?? 0) > ($1.riotPoints ?? 0) }
        case .recent:
            list.sort { ($0.lastGame?.playedAt ?? .distantPast) > ($1.lastGame?.playedAt ?? .distantPast) }
        case .idle:
            // Longest-sitting first. Accounts with no game on record sort last rather
            // than pretending to have been idle forever.
            list.sort { ($0.daysSinceLastGame ?? -1) > ($1.daysSinceLastGame ?? -1) }
        }
        return list
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

    /// How many accounts the cycle has given up on twice running.
    private var flaggedCount: Int { store.accounts.filter(\.isFlagged).count }

    /// Every folder that exists across the whole library, for the Move-to menu.
    private var allFolders: [String] {
        Array(Set(store.accounts.map(\.folder).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var hasFilters: Bool {
        folderFilter != nil || regionFilter != nil || tierFilter != nil || accessFilter != nil
        || statusFilter != .any || idleFilter != .any || playerFilter != .any
        || championOnly != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clearFilters() {
        folderFilter = nil; regionFilter = nil; tierFilter = nil; accessFilter = nil
        statusFilter = .any; idleFilter = .any; playerFilter = .any
        championOnly = nil; search = ""
    }

    // MARK: Body

    var body: some View {
        ZStack {
            LV.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topbar
                Rectangle().fill(LV.lineSoft).frame(height: 1)

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        hero
                        Section {
                            results.padding(.horizontal, 22).padding(.bottom, 40)
                        } header: {
                            controls
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .preferredColorScheme(.dark)
        .tint(LV.accent)
        .onChange(of: watcher.lastMessage) { _, message in
            guard let message else { return }
            banner = Banner(text: message.text, isError: message.isError)
        }
        .onChange(of: watcher.wantsReveal) { _, wants in
            guard wants else { return }
            watcher.wantsReveal = false
            revealSignedInAccount()
        }
        .sheet(item: $opened) { wrapper in
            detailSheet(for: wrapper.id)
        }
        .sheet(isPresented: $creatingNew) {
            AccountEditor(account: Account(), isNew: true, knownFolders: allFolders) { saved in
                store.add(saved)
                opened = OpenAccount(id: saved.id)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $importingCombos) {
            ComboImportSheet(knownFolders: allFolders) { result in
                banner = Banner(text: comboImportSummary(result),
                                isError: result.added == 0 && result.malformed > 0)
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
        .sheet(isPresented: $showCycle) {
            CycleSheet()
                .environmentObject(store)
                .environmentObject(cycle)
                .environmentObject(web)
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
                    if opened?.id == account.id { opened = nil }
                    store.delete(id: account.id)
                },
                secondaryButton: .cancel()
            )
        }
        .overlay(alignment: .bottom) { bannerView }
        .frame(minWidth: 980, minHeight: 640)
    }

    struct FolderName: Identifiable { var name: String; var id: String { name } }

    // MARK: Topbar

    private var topbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [LV.accent, Color(hex: 0x7a4bff)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)

                Text(web.title.isEmpty ? "League Vault" : web.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(LV.text)

                Text("Private")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(LV.dim)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(LV.line).frame(width: 1, height: 13)
                    }
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Button { revealSignedInAccount() } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.lvIcon)
                .disabled(signedInAccount == nil)
                .keyboardShortcut("l", modifiers: .command)
                .help(watcher.signedInAs.map { "Jump to \($0), signed in to the client right now" }
                      ?? "Nobody is signed in to the League client")

                Button { Task { await refreshAll() } } label: {
                    if refreshingIDs.isEmpty {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
                .buttonStyle(.lvIcon)
                .disabled(store.accounts.isEmpty || !refreshingIDs.isEmpty)
                .help("Update every account from the running League client")

                Button { showClient = true } label: {
                    Image(systemName: "bolt.horizontal.circle")
                }
                .buttonStyle(.lvIcon)
                .help("Connect to the running League client: rename your Riot ID, or import the signed-in account")

                Button { showCycle = true } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.lvIcon)
                .help("Sign into every account in turn, refresh it and run quick prep")

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.lvIcon)
                .help("Settings")

                Menu {
                    Button { creatingNew = true } label: {
                        Label("Add one account…", systemImage: "person.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    Button { importingCombos = true } label: {
                        Label("Import combo list…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("Add")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.lvPrimary)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add one account, or import a username;password combo list")
            }

            stamp
        }
        // The title bar is hidden, so the traffic lights sit inside this row.
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .frame(height: 56)
        .background(LV.bg)
    }

    private var stamp: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold, design: LV.mono))
                .foregroundStyle(LV.muted)
            Text(web.lastPublish.map { "published \($0.relativeDisplay)" } ?? "not published yet")
                .font(.system(size: 10, design: LV.mono))
                .foregroundStyle(LV.dim)
        }
        .help(web.siteURL.isEmpty ? "Set a site under Settings → Publish a web dashboard" : web.siteURL)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("My League ") + Text("accounts").foregroundColor(LV.accent))
                .font(.system(size: 30, weight: .heavy))
                .kerning(1.2)
                .textCase(.uppercase)
                .foregroundStyle(LV.text)

            Text("Every account in the vault — rank, champion pool, wallet, how long it has sat untouched, and anything currently holding it back. Read out of the League client, published from this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(LV.muted)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            totals.padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x0b0c18), LV.bg], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [LV.accent.opacity(0.20), .clear],
                               center: .init(x: 0.12, y: -0.3), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color(hex: 0x506eff).opacity(0.16), .clear],
                               center: .init(x: 0.88, y: -0.1), startRadius: 0, endRadius: 460)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LV.lineSoft).frame(height: 1) }
    }

    private var totals: some View {
        let accounts = store.accounts
        let ranked = accounts.filter { $0.soloRank.tier != .unranked }.count
        let champs = accounts.reduce(0) { $0 + $1.ownedChampions.count }
        let be = accounts.compactMap(\.blueEssence).reduce(0, +)
        let rp = accounts.compactMap(\.riotPoints).reduce(0, +)
        let penalised = accounts.filter(\.hasActivePenalty).count
        let dormant = accounts.filter { ($0.daysSinceLastGame ?? -1) >= 90 }.count

        return HStack(spacing: 10) {
            StatTotal(value: "\(accounts.count)", label: "Accounts")
            StatTotal(value: "\(ranked)", label: "Ranked")
            StatTotal(value: "\(champs)", label: "Champions")
            StatTotal(value: be.compact, label: "Blue essence")
            StatTotal(value: rp.compact, label: "RP")
            StatTotal(value: "\(dormant)", label: "Idle 90d+",
                      tint: dormant > 0 ? LV.warn : LV.text)
            StatTotal(value: "\(penalised)", label: "Penalised",
                      tint: penalised > 0 ? LV.bad : LV.text)
            if flaggedCount > 0 {
                StatTotal(value: "\(flaggedCount)", label: "Flagged", tint: LV.bad)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                SearchField(prompt: "Search a name, login, folder or champion — try “Viktor”", text: $search)

                viewToggle

                Button { groupByFolder.toggle() } label: {
                    Image(systemName: groupByFolder ? "folder.fill" : "folder")
                        .foregroundStyle(groupByFolder ? LV.accent : LV.dim)
                }
                .buttonStyle(IconButtonStyle(size: 38))
                .help("Group the results by folder, and drop accounts on a heading to file them")

                SelectMenu(title: "Sort", value: sort.rawValue) {
                    ForEach(SortOrder.allCases) { option in
                        Button(option.rawValue) { sort = option }
                    }
                }
                .frame(width: 158)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 9)], spacing: 9) {
                SelectMenu(title: "Any folder", value: folderFilter.map { $0.isEmpty ? "Unfiled" : $0 }) {
                    Button("Any folder") { folderFilter = nil }
                    Divider()
                    ForEach(allFolders, id: \.self) { name in
                        Button(name) { folderFilter = name }
                    }
                    Button("Unfiled") { folderFilter = "" }
                }
                SelectMenu(title: "Any server", value: regionFilter?.display) {
                    Button("Any server") { regionFilter = nil }
                    Divider()
                    ForEach(regionsInUse, id: \.self) { region in
                        Button("\(region.display) — \(region.longName)") { regionFilter = region }
                    }
                }
                SelectMenu(title: "Any rank", value: tierFilter?.display) {
                    Button("Any rank") { tierFilter = nil }
                    Divider()
                    ForEach(Tier.allCases.reversed()) { tier in
                        Button(tier.display) { tierFilter = tier }
                    }
                }
                SelectMenu(title: "FA and NFA", value: accessFilter.map(\.short)) {
                    Button("FA and NFA") { accessFilter = nil }
                    Divider()
                    Button("FA — full access") { accessFilter = .fullAccess }
                    Button("NFA — not full access") { accessFilter = .notFullAccess }
                    Button("Not recorded") { accessFilter = .unknown }
                }
                SelectMenu(title: StatusFilter.any.rawValue,
                           value: statusFilter == .any ? nil : statusFilter.rawValue) {
                    ForEach(StatusFilter.allCases) { option in
                        Button(option.rawValue) { statusFilter = option }
                    }
                }
                SelectMenu(title: IdleFilter.any.rawValue,
                           value: idleFilter == .any ? nil : idleFilter.rawValue) {
                    ForEach(IdleFilter.allCases) { option in
                        Button(option.rawValue) { idleFilter = option }
                    }
                }
                SelectMenu(title: PlayerFilter.any.rawValue,
                           value: playerFilter == .any ? nil : playerFilter.rawValue) {
                    ForEach(PlayerFilter.allCases) { option in
                        Button(option.rawValue) { playerFilter = option }
                    }
                }
                championSelect
            }

            if hasFilters { chips }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .background(LV.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(LV.lineSoft).frame(height: 1) }
    }

    private var regionsInUse: [Region] {
        let used = Set(store.accounts.map(\.region))
        return Region.allCases.filter { used.contains($0) }
    }

    private var viewToggle: some View {
        HStack(spacing: 3) {
            ForEach(ViewMode.allCases, id: \.self) { option in
                Button { mode = option } label: {
                    Image(systemName: option == .grid ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mode == option ? LV.text : LV.dim)
                        .frame(width: 36, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(mode == option ? LV.panel2 : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 38)
        .panel(radius: LV.control)
    }

    private var championSelect: some View {
        Button { showChampionPicker = true } label: {
            HStack(spacing: 6) {
                Text(championOnly ?? "Any champion")
                    .font(.system(size: 12))
                    .foregroundStyle(championOnly == nil ? LV.muted : LV.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LV.dim)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .contentShape(Rectangle())
            .panel(radius: 9)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showChampionPicker, arrowEdge: .bottom) { championPicker }
    }

    private var chips: some View {
        FlowRow(spacing: 7) {
            if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                FilterChip(text: "“\(search)”") { search = "" }
            }
            if let folderFilter {
                FilterChip(text: folderFilter.isEmpty ? "Unfiled" : folderFilter) { self.folderFilter = nil }
            }
            if let regionFilter {
                FilterChip(text: regionFilter.display) { self.regionFilter = nil }
            }
            if let tierFilter {
                FilterChip(text: tierFilter.display) { self.tierFilter = nil }
            }
            if let accessFilter {
                FilterChip(text: accessFilter == .unknown ? "Access not recorded" : accessFilter.short) {
                    self.accessFilter = nil
                }
            }
            if statusFilter != .any {
                FilterChip(text: statusFilter.rawValue) { statusFilter = .any }
            }
            if idleFilter != .any {
                FilterChip(text: idleFilter.rawValue) { idleFilter = .any }
            }
            if playerFilter != .any {
                FilterChip(text: playerFilter.rawValue) { playerFilter = .any }
            }
            if let championOnly {
                FilterChip(text: "Owns \(championOnly)") { self.championOnly = nil }
            }
            Button("Clear all") { clearFilters() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(LV.dim)
                .underline()
                .padding(.leading, 2)
        }
    }

    /// Pick a champion and the results narrow to accounts that own it.
    private var championPicker: some View {
        let all = championIndex
        let matches = championQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(championQuery) }

        return VStack(alignment: .leading, spacing: 9) {
            Text("Show accounts that own").sectionLabel()

            SearchField(prompt: "Viktor", text: $championQuery)

            if all.isEmpty {
                Text("No champion lists yet. Refresh an account with the League client signed in to pull its inventory.")
                    .font(.system(size: 11))
                    .foregroundStyle(LV.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if matches.isEmpty {
                Text("No champion matches “\(championQuery)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(LV.muted)
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
                                        .foregroundStyle(LV.text)
                                    Spacer()
                                    Text("\(entry.count)")
                                        .font(.system(size: 10, weight: .semibold, design: LV.mono))
                                        .foregroundStyle(LV.dim)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
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
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(LV.accent)
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(LV.bg2)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if store.accounts.isEmpty {
            EmptyState(
                title: "No accounts yet",
                message: "Sign in to League on this Mac and import the account straight from the client — rank, last game, server and icon come with it, no API key needed. Or add one by hand.",
                actionTitle: "Import from League Client",
                action: { showClient = true },
                secondaryTitle: "Add Manually",
                secondaryAction: { creatingNew = true }
            )
            .padding(.top, 40)
        } else if filtered.isEmpty {
            EmptyState(
                title: "Nothing matches",
                message: "No account in the vault fits those filters.",
                actionTitle: "Clear filters",
                action: { clearFilters() }
            )
            .padding(.top, 40)
        } else if groupByFolder {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(folderGroups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        folderHeader(group)
                        body(for: group.accounts)
                    }
                }
            }
            .padding(.top, 20)
        } else {
            body(for: filtered).padding(.top, 20)
        }
    }

    @ViewBuilder
    private func body(for accounts: [Account]) -> some View {
        if mode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 430), spacing: 16)],
                      alignment: .leading, spacing: 16) {
                ForEach(accounts) { account in
                    AccountCard(account: account, isRefreshing: refreshingIDs.contains(account.id))
                        .onTapGesture { opened = OpenAccount(id: account.id) }
                        .contextMenu { rowMenu(account) }
                        .draggable(account.id.uuidString)
                }
            }
        } else {
            VStack(spacing: 0) {
                AccountTableHeader()
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AccountTableRow(account: account,
                                    isRefreshing: refreshingIDs.contains(account.id),
                                    isLast: index == accounts.count - 1)
                        .onTapGesture { opened = OpenAccount(id: account.id) }
                        .contextMenu { rowMenu(account) }
                        .draggable(account.id.uuidString)
                }
            }
            .panel()
            .clipShape(RoundedRectangle(cornerRadius: LV.radius, style: .continuous))
        }
    }

    private func folderHeader(_ group: (name: String, accounts: [Account])) -> some View {
        HStack(spacing: 7) {
            Image(systemName: group.name.isEmpty ? "tray" : "folder")
                .font(.system(size: 10, weight: .bold))
            Text(group.name.isEmpty ? "Unfiled" : group.name)
                .font(.system(size: 10, weight: .bold))
                .kerning(1.5)
                .textCase(.uppercase)
            Text("\(group.accounts.count)")
                .font(.system(size: 10, weight: .semibold, design: LV.mono))
                .foregroundStyle(LV.dim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(LV.panel))
            Spacer()
        }
        .foregroundStyle(dropTarget == group.name ? LV.accent : LV.muted)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(dropTarget == group.name ? LV.accent.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(dropTarget == group.name ? LV.accent : .clear,
                          style: StrokeStyle(lineWidth: 1, dash: [3])))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { payloads, _ in
            receiveDrop(payloads, into: group.name)
        } isTargeted: { targeted in
            dropTarget = targeted ? group.name : nil
        }
        .contextMenu {
            if !group.name.isEmpty {
                Button("Rename Folder…") { renamingFolder = group.name }
                Button("Empty Folder") { store.renameFolder(from: group.name, to: "") }
            }
        }
    }

    /// Moves dragged accounts into `folder`. The payload is each account's UUID.
    ///
    /// The move is applied on the *next* runloop turn, never inline, so the drag can
    /// finish before the results rebuild underneath it.
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
        Button("Open") { opened = OpenAccount(id: account.id) }
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
    private func detailSheet(for id: UUID) -> some View {
        if let account = store.accounts.first(where: { $0.id == id }) {
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
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { opened = nil }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            HStack(spacing: 9) {
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
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(banner.isError ? LV.bad : LV.accent))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: banner.isError ? 9_000_000_000 : 4_000_000_000)
                withAnimation { self.banner = nil }
            }
        }
    }

    // MARK: Combo import

    private func comboImportSummary(_ r: AccountStore.ComboImportResult) -> String {
        if r.added == 0 {
            if r.total > 0 { return "Nothing new — all \(r.total) accounts were already in the vault." }
            if r.malformed > 0 { return "No accounts imported — no line was in username;password form." }
            return "No accounts found in that file."
        }
        var text = "Imported \(r.added) account\(r.added == 1 ? "" : "s")."
        var skipped: [String] = []
        if r.duplicates > 0 { skipped.append("\(r.duplicates) already here") }
        if r.malformed > 0 { skipped.append("\(r.malformed) malformed") }
        if !skipped.isEmpty { text += " Skipped " + skipped.joined(separator: ", ") + "." }
        text += " Sign in to each in the client to fill in the rest."
        return text
    }

    // MARK: The signed-in account

    /// Opens whichever account the League client is signed in to, so it can be read
    /// without hunting for it.
    private func revealSignedInAccount() {
        guard let match = signedInAccount else {
            banner = Banner(text: watcher.signedInAs.map {
                "The client is signed in as \($0), which matches no entry here."
            } ?? "Nobody is signed in to the League client.", isError: false)
            return
        }
        clearFilters()
        opened = OpenAccount(id: match.id)
    }

    /// The vault entry for whoever is signed in, by identity then Riot ID.
    private var signedInAccount: Account? {
        if let puuid = watcher.signedInPuuid, !puuid.isEmpty,
           let match = store.accounts.first(where: { $0.puuid == puuid }) {
            return match
        }
        guard let riotID = watcher.signedInAs else { return nil }
        return store.accounts.first {
            !$0.gameName.isEmpty && $0.riotID.compare(riotID, options: .caseInsensitive) == .orderedSame
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
        current.applySnapshot(snapshot)
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

// MARK: - Idle badge

/// How long an account has sat untouched, worded and coloured the way the page words
/// and colours it: quiet when you played the last game yourself, amber once nobody has
/// touched it for three months, a dashed outline before any game is on record.
struct IdlePill: View {
    var account: Account

    var body: some View {
        Group {
            if let label = account.idleLabel {
                Pill(text: label,
                     color: tint,
                     dot: account.idleIsSelfInflicted,
                     ghost: account.idleIsSelfInflicted)
            } else {
                Text("Never played")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(LV.dim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LV.line, style: StrokeStyle(lineWidth: 1, dash: [2.5])))
                    .fixedSize()
            }
        }
        .help(help)
    }

    private var tint: Color {
        if account.idleIsSelfInflicted { return LV.dim }
        return account.isDormant ? LV.warn : LV.muted
    }

    private var help: String {
        guard let described = account.idleDescription else {
            return "No game on record — refresh this account with the client signed in to it."
        }
        switch account.lastGamePlayer {
        case .me:
            return described + ", played by you — so this says nothing about whether anyone else has been on it."
        case .someoneElse:
            return described + ", played by someone else."
        case .unknown:
            return described + ". Who played it has not been recorded."
        }
    }
}

// MARK: - Card

/// One account as the page draws it: splash art behind a folder tag, a level tag and
/// the rank pills, then the name, the numbers that matter and a row of status pills.
struct AccountCard: View {
    var account: Account
    var isRefreshing: Bool

    @State private var hovering = false

    private var critical: Penalty? {
        account.activePenalties.first { $0.kind.isCritical }
    }

    var body: some View {
        VStack(spacing: 0) {
            art
            body_
        }
        .background(LV.panel)
        .clipShape(RoundedRectangle(cornerRadius: LV.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LV.radius, style: .continuous)
            .strokeBorder(critical != nil ? LV.bad.opacity(0.45) : (hovering ? Color(hex: 0x33365a) : LV.line),
                          lineWidth: 1))
        .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 17, y: 7)
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: LV.radius, style: .continuous))
    }

    private var art: some View {
        SplashArt(championId: account.faceChampionId, height: 142,
                  opacity: hovering ? 0.94 : 0.78)
            .overlay(alignment: .top) {
                if let critical {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .black))
                        Text("\(critical.kind.rawValue) · \(critical.statusDisplay)")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.9)
                            .textCase(.uppercase)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(LinearGradient(colors: [Color(hex: 0xff2d3c), Color(hex: 0xbe192d)],
                                               startPoint: .leading, endPoint: .trailing))
                }
            }
            .overlay(alignment: .topLeading) {
                if !account.folder.isEmpty {
                    Text(account.folder)
                        .font(.system(size: 10, weight: .semibold, design: LV.mono))
                        .kerning(1)
                        .textCase(.uppercase)
                        .foregroundStyle(LV.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LV.bg.opacity(0.72)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LV.line, lineWidth: 1))
                        .padding(10)
                        .padding(.top, critical == nil ? 0 : 26)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.6) }
                    if account.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LV.bad)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(LV.bg.opacity(0.72)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LV.line, lineWidth: 1))
                            .help(account.flagDescription ?? "The account cycle keeps failing on this one.")
                    }
                    if let level = account.summonerLevel {
                        Text("LVL \(level)")
                            .font(.system(size: 11, weight: .bold, design: LV.mono))
                            .foregroundStyle(LV.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(LV.bg.opacity(0.72)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LV.line, lineWidth: 1))
                    }
                }
                .padding(10)
                .padding(.top, critical == nil ? 0 : 26)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    RankPill(entry: account.soloRank)
                    if account.flexRank.tier != .unranked {
                        RankPill(entry: account.flexRank)
                    }
                }
                .padding(10)
            }
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProfileIconView(iconId: account.profileIconId,
                                initials: account.initials,
                                tint: account.soloRank.effectiveTier.color,
                                size: 38, corner: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LV.text)
                        .lineLimit(1)
                    Text(account.riotID.isEmpty
                         ? (account.loginUsername.isEmpty ? "not signed in yet" : account.loginUsername)
                         : account.riotID)
                        .font(.system(size: 11, design: LV.mono))
                        .foregroundStyle(LV.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                stat("\(account.ownedChampions.count)", "champs")
                stat(account.blueEssence.map(\.grouped) ?? "—", "BE")
                stat(account.riotPoints.map(\.grouped) ?? "—", "RP")
                Spacer(minLength: 0)
            }
            .padding(.top, 11)

            Rectangle().fill(LV.lineSoft).frame(height: 1).padding(.top, 11)

            FlowRow(spacing: 6) {
                Pill(text: account.region.display, color: Color(hex: 0x6b8ce6))
                if account.access != .unknown {
                    Pill(text: account.access.short,
                         color: account.access == .fullAccess ? LV.good : LV.warn)
                }
                IdlePill(account: account)
                if let worst = account.worstActivePenalty, critical == nil {
                    Pill(text: worst.kind.rawValue, color: LV.warn)
                }
            }
            .padding(.top, 11)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 14)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: LV.mono))
                .foregroundStyle(LV.text)
            Text(label)
                .font(.system(size: 11.5, design: LV.mono))
                .foregroundStyle(LV.muted)
        }
    }
}

// MARK: - Table

struct AccountTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            cell("Account", width: nil, alignment: .leading)
            cell("Rank", width: 152, alignment: .leading)
            cell("Lvl", width: 54, alignment: .trailing)
            cell("Champs", width: 76, alignment: .trailing)
            cell("BE", width: 86, alignment: .trailing)
            cell("RP", width: 76, alignment: .trailing)
            cell("Last played", width: 104, alignment: .leading)
            cell("Server", width: 92, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(LV.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(LV.line).frame(height: 1) }
    }

    private func cell(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .kerning(1.3)
            .textCase(.uppercase)
            .foregroundStyle(LV.dim)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

struct AccountTableRow: View {
    var account: Account
    var isRefreshing: Bool
    var isLast: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ProfileIconView(iconId: account.profileIconId,
                                initials: account.initials,
                                tint: account.soloRank.effectiveTier.color,
                                size: 28, corner: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(account.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LV.text)
                            .lineLimit(1)
                        if account.isFlagged {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(LV.bad)
                        }
                        if let worst = account.worstActivePenalty {
                            Image(systemName: worst.kind.isCritical
                                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(worst.kind.accent)
                                .help("\(worst.kind.rawValue): \(worst.detail)")
                        }
                    }
                    Text(account.riotID.isEmpty ? account.loginUsername : account.riotID)
                        .font(.system(size: 10.5, design: LV.mono))
                        .foregroundStyle(LV.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.55) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(account.soloRank.displayWithFallback)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(account.soloRank.tier == .unranked ? LV.muted : account.soloRank.tier.color)
                .lineLimit(1)
                .frame(width: 152, alignment: .leading)

            num(account.summonerLevel.map { "\($0)" }, width: 54)
            num("\(account.ownedChampions.count)", width: 76)
            num(account.blueEssence.map(\.grouped), width: 86)
            num(account.riotPoints.map(\.grouped), width: 76)

            HStack(spacing: 0) { IdlePill(account: account) }
                .frame(width: 104, alignment: .leading)

            HStack(spacing: 5) {
                Text(account.region.display)
                    .font(.system(size: 11, weight: .bold, design: LV.mono))
                    .foregroundStyle(LV.muted)
                if account.access != .unknown {
                    Text(account.access.short)
                        .font(.system(size: 9.5, weight: .black))
                        .foregroundStyle(account.access == .fullAccess ? LV.good : LV.warn)
                }
            }
            .frame(width: 92, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(hovering ? LV.panel2 : Color.clear)
        .overlay(alignment: .leading) {
            if account.hasCriticalPenalty {
                Rectangle().fill(LV.bad).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(LV.lineSoft).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func num(_ value: String?, width: CGFloat) -> some View {
        Text(value ?? "—")
            .font(.system(size: 11.5, weight: value == nil ? .regular : .semibold, design: LV.mono))
            .foregroundStyle(value == nil ? LV.dim : LV.text)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

extension Account {
    /// Two letters to stand in for a profile icon that has not loaded.
    var initials: String {
        let source = label.isEmpty ? gameName : label
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Flow layout

/// Wraps its children onto as many lines as they need — the `flex-wrap` the pill rows
/// and filter chips are built with on the page.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
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
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LV.text)
            TextField("Main, Smurfs, Duo accounts…", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.lv)
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onCommit(trimmed)
                    dismiss()
                }
                .buttonStyle(.lvPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .background(LV.bg2)
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
        VStack(spacing: 11) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(LV.dim)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LV.muted)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(LV.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.lvPrimary)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction).buttonStyle(.lv)
                }
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
