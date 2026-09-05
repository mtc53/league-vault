import SwiftUI
import AppKit

/// Downloads and caches summoner profile icons from Riot's Data Dragon CDN.
/// Data Dragon is public static content — no API key involved.
@MainActor
final class ProfileIconCache: ObservableObject {
    static let shared = ProfileIconCache()

    @Published private(set) var images: [Int: NSImage] = [:]

    private var inFlight: Set<Int> = []
    private var missing: Set<Int> = []
    private var version: String?

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LeagueVault/profileicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    func image(for id: Int) -> NSImage? { images[id] }

    /// Loads from memory, then disk, then the CDN.
    func load(_ id: Int) async {
        guard images[id] == nil, !inFlight.contains(id), !missing.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let file = directory.appendingPathComponent("\(id).png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[id] = image
            return
        }

        guard let version = await resolveVersion() else { missing.insert(id); return }
        let urlString = "https://ddragon.leagueoflegends.com/cdn/\(version)/img/profileicon/\(id).png"
        guard let url = URL(string: urlString) else { missing.insert(id); return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else {
                missing.insert(id)
                return
            }
            try? data.write(to: file, options: .atomic)
            images[id] = image
        } catch {
            missing.insert(id)
        }
    }

    /// Data Dragon's patch list, cached for a day so we aren't asking on every launch.
    private func resolveVersion() async -> String? {
        if let version { return version }

        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: "ddragonVersion"),
           let stamp = defaults.object(forKey: "ddragonVersionDate") as? Date,
           Date().timeIntervalSince(stamp) < 86_400 {
            version = cached
            return cached
        }

        guard let url = URL(string: "https://ddragon.leagueoflegends.com/api/versions.json") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let list = try? JSONDecoder().decode([String].self, from: data),
                  let latest = list.first else { return defaults.string(forKey: "ddragonVersion") }
            defaults.set(latest, forKey: "ddragonVersion")
            defaults.set(Date(), forKey: "ddragonVersionDate")
            version = latest
            return latest
        } catch {
            // Fall back to whatever we saw last time rather than showing nothing.
            return defaults.string(forKey: "ddragonVersion")
        }
    }

    func clearDiskCache() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        images.removeAll()
        missing.removeAll()
    }
}

/// The account's summoner icon, falling back to tinted initials until it loads.
struct ProfileIconView: View {
    var iconId: Int?
    var initials: String
    var tint: Color
    var size: CGFloat
    var corner: CGFloat

    @ObservedObject private var cache = ProfileIconCache.shared

    var body: some View {
        ZStack {
            if let iconId, let image = cache.image(for: iconId) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(0.18))
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .task(id: iconId) {
            if let iconId { await cache.load(iconId) }
        }
    }
}
