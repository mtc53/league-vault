import Foundation

// A plain .txt of Riot IDs to rename accounts to, one per line:
//
//     === Some Album (2021) ===
//     always alivë#LAN1
//     tonka#LAN1
//
// Section headers and blank lines are ignored. A name is removed from the file once it
// has been used, so the same one is never handed out twice.

struct PoolName: Equatable {
    var gameName: String
    var tagLine: String
    /// The line exactly as it appears in the file, so it can be found again to delete.
    var line: String

    var riotID: String { tagLine.isEmpty ? gameName : "\(gameName)#\(tagLine)" }
}

enum NamePool {

    /// A line is a name unless it is blank or a `=== section ===` header. The tag is
    /// whatever follows the *last* "#", since a name may contain one.
    static func parse(_ text: String) -> [PoolName] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("==="), !line.hasPrefix("//") else { return nil }

            guard let hash = line.lastIndex(of: "#") else {
                // No tag at all — still usable, the client keeps the current tag.
                return PoolName(gameName: line, tagLine: "", line: line)
            }
            let name = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
            let tag = String(line[line.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return PoolName(gameName: name, tagLine: tag, line: line)
        }
    }

    static func load(from url: URL) throws -> [PoolName] {
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else {
            text = try String(contentsOf: url, encoding: .isoLatin1)
        }
        return parse(text)
    }

    /// Rewrites the file without `name`'s line, leaving every other line — headers and
    /// spacing included — exactly as it was. Only the first match is removed.
    static func remove(_ name: PoolName, from url: URL) throws {
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else {
            text = try String(contentsOf: url, encoding: .isoLatin1)
        }

        var removed = false
        let kept = text.components(separatedBy: "\n").filter { line in
            guard !removed else { return true }
            if line.trimmingCharacters(in: .whitespaces) == name.line {
                removed = true
                return false
            }
            return true
        }
        guard removed else { return }       // already gone; nothing to write
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
