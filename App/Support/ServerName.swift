import Foundation

/// Splits a leading flag emoji off a server name, e.g. "🇳🇱 Netherlands [ Tunnel ]".
struct ServerName: Equatable, Sendable {
    let flag: String?
    let title: String

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A flag is two regional indicator symbols (U+1F1E6…U+1F1FF).
        let scalars = Array(trimmed.unicodeScalars.prefix(2))
        let isFlag = scalars.count == 2 && scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard isFlag else {
            flag = nil
            title = trimmed.isEmpty ? raw : trimmed
            return
        }
        flag = String(String.UnicodeScalarView(scalars))
        let rest = String(trimmed.unicodeScalars.dropFirst(2))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|·:")))
        title = rest.isEmpty ? trimmed : rest
    }
}
