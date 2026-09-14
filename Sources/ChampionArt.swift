import SwiftUI
import AppKit

/// Champion art for the account cards, fetched the same way the published page fetches
/// it: CommunityDragon for the square icons and the id→alias table, Data Dragon for the
/// splash, whose path carries no patch number. Both are public static CDNs — no key,
/// no account, nothing sent but the champion id.
private struct CatalogEntry: Decodable {
    let id: Int
    let alias: String?
}

@MainActor
final class ChampionArt: ObservableObject {
    static let shared = ChampionArt()

    @Published private(set) var images: [String: NSImage] = [:]

    /// Riot's champion id → the alias its art files are named after ("Kai'Sa" → "Kaisa").
    private var aliases: [Int: String] = [:]
    private var inFlight: Set<String> = []
    private var missing: Set<String> = []
    private var catalogLoaded = false

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LeagueVault/championart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: Keys

    private func splashKey(_ id: Int) -> String { "splash-\(id)" }
    private func squareKey(_ id: Int) -> String { "square-\(id)" }

    func splash(for id: Int?) -> NSImage? { id.flatMap { images[splashKey($0)] } }
    func square(for id: Int?) -> NSImage? { id.flatMap { images[squareKey($0)] } }

    // MARK: Fetching

    func loadSplash(_ id: Int?) async {
        guard let id else { return }
        await loadCatalog()
        guard let alias = aliases[id] else { return }
        await fetch(key: splashKey(id), ext: "jpg",
                    url: "https://ddragon.leagueoflegends.com/cdn/img/champion/splash/\(alias)_0.jpg")
    }

    func loadSquare(_ id: Int?) async {
        guard let id else { return }
        await fetch(key: squareKey(id), ext: "png",
                    url: "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/champion-icons/\(id).png")
    }

    /// Memory, then disk, then the CDN. A miss is remembered so a card that has no art
    /// does not re-ask on every redraw.
    private func fetch(key: String, ext: String, url urlString: String) async {
        guard images[key] == nil, !inFlight.contains(key), !missing.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let file = directory.appendingPathComponent("\(key).\(ext)")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[key] = image
            return
        }
        guard let url = URL(string: urlString) else { missing.insert(key); return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { missing.insert(key); return }
            try? data.write(to: file, options: .atomic)
            images[key] = image
        } catch {
            missing.insert(key)
        }
    }

    /// CommunityDragon's champion summary, kept on disk for a week. It is the only way
    /// to turn a champion id into the alias the splash path wants.
    private func loadCatalog() async {
        guard !catalogLoaded else { return }
        let file = directory.appendingPathComponent("champion-summary.json")

        if let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(stamp) < 604_800,
           let data = try? Data(contentsOf: file),
           let entries = try? JSONDecoder().decode([CatalogEntry].self, from: data) {
            adopt(entries)
            return
        }

        guard let url = URL(string: "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/champion-summary.json") else {
            catalogLoaded = true
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request)
            let entries = try JSONDecoder().decode([CatalogEntry].self, from: data)
            try? data.write(to: file, options: .atomic)
            adopt(entries)
        } catch {
            // Whatever is on disk beats nothing, however old it is.
            if let data = try? Data(contentsOf: file),
               let entries = try? JSONDecoder().decode([CatalogEntry].self, from: data) {
                adopt(entries)
            } else {
                catalogLoaded = true
            }
        }
    }

    private func adopt(_ entries: [CatalogEntry]) {
        for entry in entries where entry.id > 0 {
            if let alias = entry.alias, !alias.isEmpty { aliases[entry.id] = alias }
        }
        catalogLoaded = true
    }

    func clearDiskCache() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        images.removeAll()
        missing.removeAll()
        aliases.removeAll()
        catalogLoaded = false
    }
}

// MARK: - Views

/// The card's splash banner, faded into the panel colour exactly the way the page's
/// `.art::after` gradient does it. Shows a flat gradient until the art arrives.
struct SplashArt: View {
    var championId: Int?
    var height: CGFloat
    /// The colour the fade lands on — the panel under a card, the sheet under a banner.
    var fadeTo: Color = LV.panel
    var opacity: Double = 0.78

    @ObservedObject private var art = ChampionArt.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x171a2e), Color(hex: 0x0d0f1c)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            if let image = art.splash(for: championId) {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        // The page anchors at 20% from the top, where the face sits.
                        .offset(y: -geo.size.height * 0.10)
                        .clipped()
                        .opacity(opacity)
                }
            }

            LinearGradient(
                stops: [
                    .init(color: fadeTo.opacity(0), location: 0),
                    .init(color: fadeTo.opacity(0.32), location: 0.48),
                    .init(color: fadeTo.opacity(0.82), location: 0.78),
                    .init(color: fadeTo, location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height)
        .clipped()
        .task(id: championId) { await art.loadSplash(championId) }
    }
}

/// A champion's square portrait, for the owned-champion list.
struct ChampionSquare: View {
    var championId: Int
    var size: CGFloat = 22

    @ObservedObject private var art = ChampionArt.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LV.panel2)
            if let image = art.square(for: championId) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: championId) { await art.loadSquare(championId) }
    }
}

extension Account {
    /// The champion whose art fronts this account: the one last played, else a stable
    /// pick out of the pool so a card keeps the same face between refreshes. Matches
    /// faceChampionId() in the published page.
    var faceChampionId: Int? {
        if let game = lastGame {
            if let match = ownedChampions.first(where: {
                $0.name.compare(game.champion, options: .caseInsensitive) == .orderedSame
            }) { return match.id }
        }
        guard !ownedChampions.isEmpty else { return nil }
        var hash: UInt32 = 0
        for scalar in id.uuidString.unicodeScalars {
            hash = hash &* 31 &+ (scalar.value & 0xff)
        }
        return ownedChampions[Int(hash % UInt32(ownedChampions.count))].id
    }
}
