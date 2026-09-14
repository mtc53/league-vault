import SwiftUI

/// Browse every profile icon Data Dragon knows about — not just the ones you own —
/// and set one on the signed-in account.
struct IconPickerSheet: View {
    var credentials: LCUCredentials
    var currentIconId: Int?
    var onApplied: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cache = ProfileIconCache.shared

    @State private var search = ""
    @State private var selected: Int?
    @State private var applying = false
    @State private var error: String?
    @State private var loading = true

    private var matches: [Int] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cache.catalog }
        // Icons have no names in Data Dragon, so id is what there is to search by.
        return cache.catalog.filter { String($0).contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 660, height: 560)
        .background(LV.bg2)
        .tint(LV.accent)
        .task {
            await cache.loadCatalog()
            loading = false
            if selected == nil { selected = currentIconId }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Profile Icon")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Icon id", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 110)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(LV.panel))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading the icon catalogue…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cache.catalog.isEmpty {
            VStack(spacing: 8) {
                Text("Could not load the icon list.")
                    .font(.system(size: 13, weight: .medium))
                Text("Data Dragon was unreachable. You can still type an id below and apply it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                    ForEach(matches, id: \.self) { id in
                        cell(id)
                    }
                }
                .padding(16)
            }
        }
    }

    private func cell(_ id: Int) -> some View {
        VStack(spacing: 3) {
            ProfileIconView(iconId: id, initials: "\(id)", tint: .secondary, size: 56, corner: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected == id ? LV.accent : .clear, lineWidth: 3)
                )
            Text("\(id)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(selected == id ? AnyShapeStyle(LV.accent) : AnyShapeStyle(.tertiary))
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = id }
        .help("Icon \(id)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if let selected {
                    ProfileIconView(iconId: selected, initials: "?", tint: LV.accent, size: 34, corner: 7)
                    Text("Icon \(selected)")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Pick an icon, or type its id above.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(matches.count) icons")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await apply() }
                } label: {
                    if applying {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Text("Set Icon")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil || applying)
            }
            Text("Any icon works, owned or not — the client takes the id without checking your inventory. Riot may reset it server-side; if it snaps back, that is Riot's doing, not the app's.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func apply() async {
        guard let selected else { return }
        applying = true
        defer { applying = false }
        do {
            try await LCU.setProfileIcon(id: selected, credentials: credentials)
            onApplied(selected)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
