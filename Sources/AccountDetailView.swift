import SwiftUI
import AppKit

struct AccountDetailView: View {
    @EnvironmentObject var store: AccountStore

    var account: Account
    var isRefreshing: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onRefresh: () -> Void
    var onNotify: (String, Bool) -> Void
    var onOpenClient: () -> Void

    @State private var revealPassword = false
    @State private var championFilter = ""
    @State private var showAllChampions = false
    @State private var showSignIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if account.hasActivePenalty { penaltyBanner }
                rankCard
                championsCard
                lastGameCard
                penaltiesCard
                credentialsCard
                if !account.notes.isEmpty { notesCard }
                footer
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(isPresented: $showSignIn) {
            SignInHelperSheet(account: account).environmentObject(store)
        }
        .onChange(of: account.id) { _, _ in
            revealPassword = false
            championFilter = ""
            showAllChampions = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ProfileIconView(iconId: account.profileIconId,
                            initials: initials,
                            tint: account.soloRank.tier.color,
                            size: 60,
                            corner: 12)

            VStack(alignment: .leading, spacing: 5) {
                Text(account.displayName)
                    .font(.system(size: 22, weight: .bold))
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    if !account.gameName.isEmpty {
                        Text(account.riotID)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            Clipboard.copy(account.riotID)
                            onNotify("Riot ID copied.", false)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 6) {
                    Chip(text: "\(account.region.display) · \(account.region.longName)", color: .secondary)
                    if !account.folder.isEmpty {
                        Chip(text: account.folder, color: .accentColor)
                    }
                    if account.access != .unknown {
                        Chip(text: account.access.short,
                             color: account.access == .fullAccess ? .green : .orange,
                             filled: true)
                            .help(account.access.explanation)
                    }
                    if let level = account.summonerLevel {
                        Chip(text: "Level \(level)", color: .secondary)
                    }
                    if let described = account.idleDescription {
                        Chip(text: described,
                             color: account.idleIsSelfInflicted ? .secondary
                                    : (account.isDormant ? .orange : .accentColor))
                            .help(account.idleIsSelfInflicted
                                  ? "You played it, so this says nothing about whether anyone else has been on the account."
                                  : "Days since the last game the client reported.")
                    } else {
                        Chip(text: "Never played", color: .secondary)
                    }
                    if let honor = account.honorLevel {
                        Chip(text: "Honor \(honor)", color: honor >= 3 ? .green : .orange)
                            .help(honor >= 3 ? "Honor is in good standing." : "Honor is below 3 — rewards may be locked.")
                    }
                    if let be = account.blueEssence {
                        Chip(text: "\(be.grouped) BE", color: Color(red: 0.35, green: 0.62, blue: 0.92))
                    }
                    if let rp = account.riotPoints {
                        Chip(text: "\(rp.grouped) RP", color: Color(red: 0.90, green: 0.55, blue: 0.30))
                    }
                    if let worst = account.worstActivePenalty {
                        Chip(text: account.activePenalties.count == 1
                             ? worst.kind.rawValue
                             : "\(account.activePenalties.count) active penalties",
                             color: worst.kind.accent,
                             filled: true)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onRefresh) {
                        if isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)

                    Button {
                        showSignIn = true
                    } label: {
                        Label("Sign in", systemImage: "person.badge.key")
                    }
                    .help("Get the Riot Client to the login screen with this account's details ready")

                    Button("Edit", action: onEdit)

                    if let ugg = account.uggURL {
                        Button {
                            Clipboard.copy(ugg.absoluteString)
                            onNotify("u.gg link copied.", false)
                        } label: {
                            Label("Copy u.gg", systemImage: "link")
                        }
                        .help(ugg.absoluteString)
                    }

                    Menu {
                        if let ugg = account.uggURL {
                            Button("Open on u.gg") { NSWorkspace.shared.open(ugg) }
                            Button("Copy u.gg Link") {
                                Clipboard.copy(ugg.absoluteString)
                                onNotify("u.gg link copied.", false)
                            }
                            Divider()
                        }
                        Button("Change Riot ID via League Client…") { onOpenClient() }
                        Button("Change Riot ID on the web…") {
                            if let url = URL(string: "https://account.riotgames.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Divider()
                        Button("Delete Account…", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
        }
    }

    private var initials: String {
        let source = account.label.isEmpty ? account.gameName : account.label
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var penaltyBanner: some View {
        let accent = account.worstActivePenalty?.kind.accent ?? .orange
        let delays = account.activeQueueDelays

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: delays.isEmpty ? "exclamationmark.triangle.fill" : "exclamationmark.octagon.fill")
                .font(.system(size: delays.isEmpty ? 15 : 19))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 3) {
                if let delay = delays.first {
                    // Queue delay costs time on every single game, so it leads.
                    Text(delays.count == 1 ? "Queue delay active" : "\(delays.count) queue delays active")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                    Text(delay.detail)
                        .font(.system(size: 12, weight: .medium))
                    let others = account.activePenalties.filter { $0.kind != .queueDelay }
                    if !others.isEmpty {
                        Text("Also: " + others.map { $0.kind.rawValue }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(account.activePenalties.count == 1
                         ? "1 active penalty"
                         : "\(account.activePenalties.count) active penalties")
                        .font(.system(size: 13, weight: .semibold))
                    Text(account.activePenalties.map { $0.kind.rawValue }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(delays.isEmpty ? 0.12 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent.opacity(delays.isEmpty ? 0.35 : 0.7), lineWidth: delays.isEmpty ? 1 : 2)
        )
    }

    // MARK: Cards

    private var rankCard: some View {
        Card(title: "Rank", systemImage: "rosette") {
            HStack(spacing: 12) {
                ForEach(account.ranks) { entry in
                    rankTile(entry)
                }
            }
        }
    }

    private func rankTile(_ entry: RankEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.queue.display)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(entry.shortDisplay)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(entry.tier == .unranked ? Color.secondary : entry.tier.color)

            if let peak = entry.peakDisplay {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 9, weight: .bold))
                    Text("Peak \(peak)")
                        .font(.system(size: 11, weight: .medium))
                    if !entry.peakNote.isEmpty {
                        Text("· \(entry.peakNote)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(entry.peakTier.color)
            }

            if entry.games > 0 {
                HStack(spacing: 6) {
                    Text("\(entry.wins)W \(entry.losses)L")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", entry.winrate))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.winrate >= 50 ? .green : .red)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.25))
                        Capsule()
                            .fill(Color.green.opacity(0.6))
                            .frame(width: geo.size.width * entry.winrate / 100)
                    }
                }
                .frame(height: 4)
            } else {
                Text("No games recorded")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(height: 20, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.effectiveTier.color.opacity(entry.tier == .unranked ? 0.06 : 0.10))
        )
    }

    private var filteredChampions: [OwnedChampion] {
        let q = championFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return account.ownedChampions }
        return account.ownedChampions.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder
    private var championsCard: some View {
        Card(title: "Champions", systemImage: "person.3",
             accessory: AnyView(
                Text(account.ownedChampions.isEmpty ? "" : "\(account.ownedChampions.count) owned")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
             )) {
            if account.ownedChampions.isEmpty {
                Text("No champion list yet. Refresh with the League client signed in to this account to pull its inventory.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        TextField("Filter champions", text: $championFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !championFilter.isEmpty {
                            Button { championFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                            Text("\(filteredChampions.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                    )

                    if filteredChampions.isEmpty {
                        Text("No champion matches “\(championFilter)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        let shown = showAllChampions || !championFilter.isEmpty
                            ? filteredChampions
                            : Array(filteredChampions.prefix(24))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                            ForEach(shown) { champ in
                                Text(champ.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                                    )
                                    .help(champ.name)
                            }
                        }

                        if championFilter.isEmpty && filteredChampions.count > 24 {
                            Button(showAllChampions
                                   ? "Show fewer"
                                   : "Show all \(filteredChampions.count)") {
                                withAnimation { showAllChampions.toggle() }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lastGameCard: some View {
        Card(title: "Last Played Game", systemImage: "gamecontroller") {
            if let game = account.lastGame {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Chip(text: game.result.rawValue,
                             color: game.result == .victory ? .green : (game.result == .defeat ? .red : .secondary),
                             filled: true)
                        Text(game.champion.isEmpty ? "Unknown champion" : game.champion)
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(game.playedAt.relativeDisplay)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help(game.playedAt.shortDisplay)
                    }

                    HStack(spacing: 26) {
                        LabeledValue(label: "Queue", value: game.queue.isEmpty ? "—" : game.queue)
                        LabeledValue(label: "KDA", value: game.kda, monospaced: true)
                        LabeledValue(label: "Ratio", value: String(format: "%.2f", game.kdaRatio), monospaced: true)
                        LabeledValue(label: "Duration", value: game.durationDisplay, monospaced: true)
                        LabeledValue(label: "Played", value: game.playedAt.shortDisplay)
                    }

                    Divider()

                    // The client cannot tell a game you played from one someone else
                    // played, so this is recorded by hand. It decides whether the idle
                    // counter on the sidebar means anything.
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Who played it")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Picker("", selection: playerBinding) {
                            ForEach(LastGame.Player.allCases) { who in
                                Label(who.display, systemImage: who.symbol).tag(who)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 340)
                        Text(game.player == .me
                             ? "Marked as yours, so the idle counter is greyed out — it only tells you when you last played it."
                             : (game.player == .someoneElse
                                ? "Marked as someone else's, so the idle counter tracks how long since anyone was on it."
                                : "Say who played it and the idle counter is tinted to match."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !game.matchId.isEmpty {
                        Text(game.matchId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("No game recorded yet. Refresh with the League client signed in to this account, or add one in Edit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Writes through immediately — this is a live control, not part of the editor.
    private var playerBinding: Binding<LastGame.Player> {
        Binding(
            get: { account.lastGame?.player ?? .unknown },
            set: { who in
                guard var updated = store.accounts.first(where: { $0.id == account.id }),
                      updated.lastGame != nil else { return }
                updated.lastGame?.player = who
                store.update(updated)
            })
    }

    private var penaltiesCard: some View {
        Card(title: "Penalties", systemImage: "exclamationmark.shield",
             accessory: AnyView(dodgeButton)) {
            if account.penalties.isEmpty {
                Text("No penalties recorded. Refresh imports what the client reports; anything it does not expose you can add by hand in Edit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(account.penalties.sorted { a, b in
                        if a.isActive != b.isActive { return a.isActive }
                        if a.kind.severityRank != b.kind.severityRank {
                            return a.kind.severityRank < b.kind.severityRank
                        }
                        return a.startedAt > b.startedAt
                    }) { penalty in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: penalty.kind.symbol)
                                .font(.system(size: penalty.isActive && penalty.kind.isCritical ? 14 : 12,
                                              weight: penalty.isActive && penalty.kind.isCritical ? .bold : .regular))
                                .foregroundStyle(penalty.isActive ? penalty.kind.accent : Color.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(penalty.kind.rawValue)
                                        .font(.system(size: 13, weight: .medium))
                                    if penalty.source == .client {
                                        Chip(text: "from client", color: .secondary)
                                    }
                                    Chip(text: penalty.statusDisplay,
                                         color: penalty.isActive ? penalty.kind.accent : .secondary,
                                         filled: penalty.isActive)
                                }
                                if !penalty.detail.isEmpty {
                                    Text(penalty.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Text("Started \(penalty.startedAt.shortDisplay)"
                                     + (penalty.expiresAt.map { " · Ends \($0.shortDisplay)" } ?? ""))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(penalty.isActive ? penalty.kind.accent.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(penalty.isActive && penalty.kind.isCritical
                                              ? penalty.kind.accent.opacity(0.55) : .clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
    }

    /// Dodging costs a flat 24-hour wait that nothing in the client reports, so it is
    /// started by hand the moment it happens.
    @ViewBuilder
    private var dodgeButton: some View {
        if let running = account.activeDodgeTimer {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.red)
                Text(running.expiresAt.map { countdown(to: $0) } ?? "running")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                Button("Clear") {
                    var updated = account
                    updated.penalties.removeAll { $0.kind == .dodgeTimer && $0.isActive }
                    store.update(updated)
                    onNotify("Dodge timer cleared.", false)
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }
        } else {
            Button {
                startDodge(hours: 24)
            } label: {
                Label("24h dodge timer", systemImage: "arrow.uturn.backward.circle")
            }
            .help("Start a 24-hour dodge timer on this account")
        }
    }

    private func startDodge(hours: Int) {
        var updated = account
        updated.startDodgeTimer(hours: hours)
        store.update(updated)
        onNotify("24-hour dodge timer started.", false)
    }

    /// Live-ish countdown; the view redraws whenever the vault changes.
    private func countdown(to date: Date) -> String {
        let remaining = Int(date.timeIntervalSinceNow)
        guard remaining > 0 else { return "expired" }
        let h = remaining / 3600, m = (remaining % 3600) / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }

    private var credentialsCard: some View {
        Card(title: "Login", systemImage: "key") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LabeledValue(label: "Username", value: account.loginUsername.isEmpty ? "—" : account.loginUsername, monospaced: true)
                    if !account.loginUsername.isEmpty {
                        Button {
                            Clipboard.copy(account.loginUsername)
                            onNotify("Username copied.", false)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy username")
                    }
                    Spacer()
                }

                Divider()

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PASSWORD")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        if account.encryptedPassword == nil {
                            Text("—").font(.system(size: 13))
                        } else if revealPassword, let pw = store.password(for: account) {
                            Text(pw)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                        } else if revealPassword {
                            Text("Could not decrypt — the vault key is missing from your Keychain.")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        } else {
                            Text(String(repeating: "•", count: 12))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if account.encryptedPassword != nil {
                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealPassword ? "Hide password" : "Reveal password")

                        Button {
                            if let pw = store.password(for: account) {
                                Clipboard.copy(pw, clearAfter: 45)
                                onNotify("Password copied — clipboard clears in 45 seconds.", false)
                            } else {
                                onNotify("Could not decrypt the password.", true)
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy password (clipboard clears after 45 seconds)")
                    }

                    Spacer()
                }

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: account.access == .fullAccess ? "checkmark.seal.fill"
                          : (account.access == .notFullAccess ? "exclamationmark.triangle.fill" : "questionmark.circle"))
                        .foregroundStyle(account.access == .fullAccess ? .green
                                         : (account.access == .notFullAccess ? .orange : .secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.access.display)
                            .font(.system(size: 13, weight: .medium))
                        Text(account.access.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Text("Stored encrypted on this Mac with a key held in your login Keychain. This app never signs in anywhere for you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var notesCard: some View {
        Card(title: "Notes", systemImage: "note.text") {
            Text(account.notes)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let refreshed = account.lastRefreshed {
                Text("Last refreshed \(refreshed.relativeDisplay)")
            } else {
                Text("Never refreshed from Riot")
            }
            Text("·")
            Text("Added \(account.createdAt.shortDisplay)")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
}
