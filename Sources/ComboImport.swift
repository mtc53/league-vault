import Foundation

/// Parses a combo list — one `username;password` per line — into accounts.
///
/// The file is exactly what its name says and nothing more: a login and a password,
/// separated by a semicolon. Everything else about each account (Riot ID, rank, server,
/// champions) fills itself in the first time that account signs in to the client and is
/// refreshed, the same as an account added by hand with only a login.
enum ComboImport {

    struct Pair: Equatable {
        var username: String
        var password: String
    }

    struct Parsed {
        /// Ready to import, in file order, with within-file duplicates already removed.
        var pairs: [Pair] = []
        /// Lines that were not blank, not a comment, and had no separator.
        var malformed: [Int] = []
        /// Lines dropped because an earlier line in the same file had the same username.
        var duplicateLines: Int = 0
        /// Every non-blank, non-comment line seen.
        var considered: Int = 0
    }

    /// The separator the format uses. A password may itself contain semicolons, so only
    /// the first one splits the line.
    static let separator: Character = ";"

    static func parse(_ text: String) -> Parsed {
        var result = Parsed()
        var seen = Set<String>()

        // Handles \n, \r\n and lone \r line endings.
        let lines = text.split(whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.considered += 1

            guard let sep = line.firstIndex(of: separator) else {
                result.malformed.append(index + 1)
                continue
            }

            let username = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
            let password = String(line[line.index(after: sep)...])
            // The username is required; the password may legitimately be empty, and the
            // leading/trailing spaces of a password are left alone in case they are real.
            guard !username.isEmpty else {
                result.malformed.append(index + 1)
                continue
            }

            let key = username.lowercased()
            if seen.contains(key) {
                result.duplicateLines += 1
                continue
            }
            seen.insert(key)
            result.pairs.append(Pair(username: username, password: password))
        }
        return result
    }
}
