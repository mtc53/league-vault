import SwiftUI

struct AccountEditor: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Account
    @State private var password: String = ""
    @State private var passwordLoaded = false
    @State private var showPassword = false
    @State private var hasLastGame: Bool
    @State private var lastGame: LastGame
    @State private var tab: Tab = .identity
    @State private var folderChoice: String = ""
    @State private var newFolderName: String = ""

    private let isNew: Bool
    private let knownFolders: [String]
    private let onSave: (Account) -> Void

    private static let newFolderToken = "\u{0000}new"

    enum Tab: String, CaseIterable, Identifiable {
        case identity = "Account"
        case rank = "Rank"
        case game = "Last Game"
        case penalties = "Penalties"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .identity: return "person.text.rectangle"
            case .rank: return "rosette"
            case .game: return "gamecontroller"
            case .penalties: return "exclamationmark.shield"
            }
        }
    }

    init(account: Account, isNew: Bool, knownFolders: [String], onSave: @escaping (Account) -> Void) {
        var seeded = account
        seeded.normalize()
        _draft = State(initialValue: seeded)
        _hasLastGame = State(initialValue: account.lastGame != nil)
        _lastGame = State(initialValue: account.lastGame ?? LastGame())
        _folderChoice = State(initialValue: account.folder)
        self.isNew = isNew
        self.knownFolders = knownFolders
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Account" : "Edit Account")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            Divider().padding(.top, 12)

            ScrollView {
                Group {
                    switch tab {
                    case .identity:  identityForm
                    case .rank:      rankForm
                    case .game:      gameForm
                    case .penalties: penaltiesForm
                    }
                }
                .padding(20)
            }
            .frame(height: 420)

            Divider()

            HStack {
                if tab == .penalties {
                    Button {
                        draft.penalties.append(Penalty())
                    } label: {
                        Label("Add Penalty", systemImage: "plus")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Account" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.label.trimmingCharacters(in: .whitespaces).isEmpty
                              && draft.gameName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620)
        .onAppear(perform: loadPassword)
    }

    // MARK: Identity

    private var identityForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            FormSection("Identity") {
                HStack(spacing: 10) {
                    Field("Nickname") {
                        TextField("Main, Smurf, ADC alt…", text: $draft.label)
                    }
                    Field("Folder") {
                        Picker("", selection: $folderChoice) {
                            Text("Unfiled").tag("")
                            if !folderOptions.isEmpty { Divider() }
                            ForEach(folderOptions, id: \.self) { Text($0).tag($0) }
                            Divider()
                            Text("New Folder…").tag(Self.newFolderToken)
                        }
                        .labelsHidden()
                    }
                }
                if folderChoice == Self.newFolderToken {
                    Field("New folder name") {
                        TextField("Smurfs", text: $newFolderName)
                    }
                }
                HStack(spacing: 10) {
                    Field("Riot ID") {
                        TextField("GameName", text: $draft.gameName)
                    }
                    Field("Tag") {
                        HStack(spacing: 2) {
                            Text("#").foregroundStyle(.secondary)
                            TextField("NA1", text: $draft.tagLine)
                        }
                    }
                    .frame(width: 130)
                }
                Field("Server / Region") {
                    Picker("", selection: $draft.region) {
                        ForEach(Region.allCases) { region in
                            Text("\(region.display) — \(region.longName)").tag(region)
                        }
                    }
                    .labelsHidden()
                }
            }

            FormSection("Login") {
                HStack(spacing: 10) {
                    Field("Username or email") {
                        TextField("", text: $draft.loginUsername)
                    }
                    Field("Access") {
                        Picker("", selection: $draft.access) {
                            ForEach(AccessLevel.allCases) { Text($0.display).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .frame(width: 200)
                }
                Field("Password") {
                    HStack(spacing: 6) {
                        if showPassword {
                            TextField("", text: $password)
                        } else {
                            SecureField("", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Encrypted with AES-GCM using a key stored in your login Keychain. Leave blank to store no password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            FormSection("Wallet") {
                HStack(spacing: 10) {
                    Field("Blue essence") {
                        TextField("—", value: $draft.blueEssence, format: .number)
                    }
                    .frame(width: 140)
                    Field("RP") {
                        TextField("—", value: $draft.riotPoints, format: .number)
                    }
                    .frame(width: 140)
                    Spacer()
                }
                Text("Refresh fills these from the client's wallet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            FormSection("Notes") {
                TextEditor(text: $draft.notes)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
            }
        }
    }

    // MARK: Rank

    private var rankForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(RankedQueue.allCases) { queue in
                if let idx = draft.ranks.firstIndex(where: { $0.queue == queue }) {
                    FormSection(queue.display) {
                        HStack(spacing: 10) {
                            Field("Tier") {
                                Picker("", selection: $draft.ranks[idx].tier) {
                                    ForEach(Tier.allCases) { Text($0.display).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Field("Division") {
                                Picker("", selection: $draft.ranks[idx].division) {
                                    ForEach(Division.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .disabled(draft.ranks[idx].tier.isApex || draft.ranks[idx].tier == .unranked)
                            }
                            .frame(width: 100)
                            Field("LP") {
                                TextField("0", value: $draft.ranks[idx].lp, format: .number)
                            }
                            .frame(width: 80)
                        }
                        HStack(spacing: 10) {
                            Field("Wins") {
                                TextField("0", value: $draft.ranks[idx].wins, format: .number)
                            }
                            .frame(width: 90)
                            Field("Losses") {
                                TextField("0", value: $draft.ranks[idx].losses, format: .number)
                            }
                            .frame(width: 90)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Field("Peak tier") {
                                Picker("", selection: $draft.ranks[idx].peakTier) {
                                    ForEach(Tier.allCases) { Text($0 == .unranked ? "None" : $0.display).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Field("Peak division") {
                                Picker("", selection: $draft.ranks[idx].peakDivision) {
                                    ForEach(Division.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .disabled(draft.ranks[idx].peakTier.isApex || draft.ranks[idx].peakTier == .unranked)
                            }
                            .frame(width: 110)
                            Field("When") {
                                TextField("S13 split 2", text: $draft.ranks[idx].peakNote)
                            }
                        }
                    }
                }
            }
            Text("Refresh fills the current rank from the League client. Peak rank is yours to record — Riot exposes no peak-rank endpoint — and it is what the sidebar shows for an unranked account.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Last game

    private var gameForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Track a last played game", isOn: $hasLastGame)

            if hasLastGame {
                FormSection("Last Game") {
                    HStack(spacing: 10) {
                        Field("Champion") { TextField("Ahri", text: $lastGame.champion) }
                        Field("Queue") { TextField("Ranked Solo/Duo", text: $lastGame.queue) }
                    }
                    HStack(spacing: 10) {
                        Field("Result") {
                            Picker("", selection: $lastGame.result) {
                                ForEach(LastGame.Result.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                        }
                        .frame(width: 130)
                        Field("K") { TextField("0", value: $lastGame.kills, format: .number) }.frame(width: 60)
                        Field("D") { TextField("0", value: $lastGame.deaths, format: .number) }.frame(width: 60)
                        Field("A") { TextField("0", value: $lastGame.assists, format: .number) }.frame(width: 60)
                        Field("Length (min)") {
                            TextField("0", value: Binding(
                                get: { lastGame.durationSeconds / 60 },
                                set: { lastGame.durationSeconds = $0 * 60 }
                            ), format: .number)
                        }
                        .frame(width: 100)
                    }
                    Field("Played at") {
                        DatePicker("", selection: $lastGame.playedAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
            } else {
                Text("No game is tracked for this account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Penalties

    private var penaltiesForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.penalties.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No penalties recorded.")
                        .font(.system(size: 13, weight: .medium))
                    Text("Riot publishes no API for bans, chat restrictions or low-priority queue, so record them here by hand. The app marks one active until its end date passes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach($draft.penalties) { $penalty in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Field("Type") {
                            Picker("", selection: $penalty.kind) {
                                ForEach(PenaltyKind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                        }
                        Spacer()
                        Chip(text: penalty.statusDisplay,
                             color: penalty.isActive ? .orange : .secondary,
                             filled: penalty.isActive)
                        Button {
                            draft.penalties.removeAll { $0.id == penalty.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }

                    Field("Detail") {
                        TextField("10 games · verbal abuse", text: $penalty.detail)
                    }

                    HStack(spacing: 12) {
                        Field("Started") {
                            DatePicker("", selection: $penalty.startedAt, displayedComponents: [.date])
                                .labelsHidden()
                        }
                        Field("Ends") {
                            HStack(spacing: 6) {
                                Toggle("", isOn: Binding(
                                    get: { penalty.expiresAt != nil },
                                    set: { penalty.expiresAt = $0 ? (penalty.expiresAt ?? Date().addingTimeInterval(14 * 86400)) : nil }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(penalty.kind.isPermanentByNature)

                                if let end = penalty.expiresAt, !penalty.kind.isPermanentByNature {
                                    DatePicker("", selection: Binding(
                                        get: { end },
                                        set: { penalty.expiresAt = $0 }
                                    ), displayedComponents: [.date])
                                    .labelsHidden()
                                } else {
                                    Text(penalty.kind.isPermanentByNature ? "Permanent" : "No end date")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Toggle("Served", isOn: $penalty.resolved)
                            .toggleStyle(.checkbox)
                            .disabled(penalty.kind.isPermanentByNature)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    // MARK: Actions

    /// Existing folders, plus this account's own folder if it is not in the list yet.
    private var folderOptions: [String] {
        var set = Set(knownFolders)
        if !draft.folder.isEmpty { set.insert(draft.folder) }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func loadPassword() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        password = store.password(for: draft) ?? ""
    }

    private func save() {
        var out = draft
        out.gameName = out.gameName.trimmingCharacters(in: .whitespaces)
        out.tagLine = out.tagLine.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        out.label = out.label.trimmingCharacters(in: .whitespaces)
        out.loginUsername = out.loginUsername.trimmingCharacters(in: .whitespaces)
        if folderChoice == Self.newFolderToken {
            out.folder = newFolderName.trimmingCharacters(in: .whitespaces)
        } else {
            out.folder = folderChoice
        }
        out.lastGame = hasLastGame ? lastGame : nil
        out.encryptedPassword = password.isEmpty ? nil : store.encrypt(password)
        for i in out.penalties.indices where out.penalties[i].kind.isPermanentByNature {
            out.penalties[i].expiresAt = nil
            out.penalties[i].resolved = false
        }
        onSave(out)
        dismiss()
    }
}

// MARK: - Form helpers

struct FormSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            content
        }
    }
}

struct Field<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            content
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
