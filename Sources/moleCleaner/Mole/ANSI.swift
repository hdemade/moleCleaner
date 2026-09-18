import Foundation

/// Nettoie la sortie terminal de Mole (couleurs, curseur, retours chariot).
enum ANSI {
    private static let patterns: [NSRegularExpression] = [
        "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",       // CSI
        "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", // OSC
        "\u{1B}[()][0-9A-Za-z]",              // jeux de caractères
        "\u{1B}[=>78cM]",                     // divers
    ].map { try! NSRegularExpression(pattern: $0) }

    static func strip(_ text: String) -> String {
        var s = text
        for re in patterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
    }

    /// Nettoie une ligne : escapes, `\r` (ne garde que le dernier segment affiché), caractères de contrôle.
    static func cleanLine(_ raw: String) -> String {
        var s = strip(raw)
        if s.hasSuffix("\r") { s.removeLast() }
        if let idx = s.lastIndex(of: "\r") { s = String(s[s.index(after: idx)...]) }
        s.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\t" }
        s = s.replacingOccurrences(of: "^D", with: "")
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
}

/// Découpe un flux d'octets en lignes complètes, en gardant la ligne partielle (invites sans retour à la ligne).
struct LineBuffer {
    private var pending = Data()

    /// Ajoute des octets et renvoie les lignes complètes (brutes, sans `\n`).
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    /// Ligne en cours (sans retour à la ligne).
    var tail: String { String(decoding: pending, as: UTF8.self) }

    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
