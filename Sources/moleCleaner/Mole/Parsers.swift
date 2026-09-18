import Foundation

// MARK: - Lignes de sortie

enum LineKind: Hashable {
    case section, success, action, warning, error, info, hint, sub, rule, plain
}

struct LogLine: Identifiable, Hashable {
    let id: Int
    let kind: LineKind
    /// Texte sans le glyphe de tête.
    let text: String

    init(id: Int, raw: String) {
        self.id = id
        let (kind, text) = MoleParse.classify(raw)
        self.kind = kind
        self.text = text
    }
}

struct MoleSummary: Hashable {
    let heading: String
    let details: [String]
}

struct OutputSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    var entries: [LogLine]
}

enum MoleParse {
    private static let glyphs: [(String, LineKind)] = [
        ("➤", .section), ("✓", .success), ("→", .action), ("◎", .warning), ("☻", .error),
        ("⊙", .hint), ("•", .info), ("ℹ", .info), ("⚙", .info), ("↳", .sub), ("○", .plain), ("●", .plain),
    ]

    static func classify(_ raw: String) -> (LineKind, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("=====") { return (.rule, "") }
        for (glyph, kind) in glyphs where trimmed.hasPrefix(glyph) {
            let text = trimmed.dropFirst(glyph.count).trimmingCharacters(in: .whitespaces)
            return (kind, text)
        }
        // Titres en majuscules (ex. « PERFORMANCE DIAGNOSIS »)
        if trimmed.count > 3, trimmed == trimmed.uppercased(), trimmed.rangeOfCharacter(from: .lowercaseLetters) == nil,
           trimmed.rangeOfCharacter(from: .letters) != nil, !trimmed.contains(":") {
            return (.section, trimmed.capitalized)
        }
        return (.plain, trimmed)
    }

    /// Bloc résumé encadré par des lignes de `=`.
    static func summary(from lines: [String]) -> MoleSummary? {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let end = cleaned.lastIndex(where: { $0.hasPrefix("=====") }),
              let start = cleaned[..<end].lastIndex(where: { $0.hasPrefix("=====") }) else { return nil }
        let body = cleaned[(start + 1)..<end].filter { !$0.isEmpty }
        guard let heading = body.first else { return nil }
        return MoleSummary(heading: heading, details: Array(body.dropFirst()))
    }

    /// Découpe la sortie en sections `➤ Titre`. Les lignes avant la première section vont dans `preamble`.
    static func sections(from lines: [String]) -> (preamble: [LogLine], sections: [OutputSection]) {
        var preamble: [LogLine] = []
        var sections: [OutputSection] = []
        var inSummary = false
        for (index, raw) in lines.enumerated() {
            let line = LogLine(id: index, raw: raw)
            if line.kind == .rule { inSummary.toggle(); continue }
            if inSummary || line.text.isEmpty { continue }
            if line.kind == .section {
                sections.append(OutputSection(title: line.text, entries: []))
            } else if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].entries.append(line)
            }
        }
        return (preamble, sections)
    }

    private static let sizeRegex = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s?(B|KB|MB|GB|TB)\\b")

    /// Dernière taille trouvée dans le texte (« 476.1MB » → octets, base 1000 comme le Finder).
    static func bytes(in text: String) -> Int64? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = sizeRegex.matches(in: text, range: range).last,
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange]) else { return nil }
        let multiplier: Double
        switch text[unitRange] {
        case "KB": multiplier = 1e3
        case "MB": multiplier = 1e6
        case "GB": multiplier = 1e9
        case "TB": multiplier = 1e12
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }
}

// MARK: - Clean

struct CleanEntry: Identifiable, Hashable {
    let id = UUID()
    let kind: LineKind
    let label: String
    let detail: String
    let bytes: Int64?
}

struct CleanCategory: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let entries: [CleanEntry]
    var totalBytes: Int64 { entries.filter { $0.kind == .action }.compactMap(\.bytes).reduce(0, +) }
    var isEmpty: Bool { !entries.contains { $0.kind == .action || $0.kind == .warning || $0.kind == .hint } }
}

struct CleanPreview: Hashable {
    var categories: [CleanCategory] = []
    var summary: MoleSummary?
    var potentialText: String?
    var itemCount: Int?
    var freeSpace: String?
    var systemIncluded = false
    var whitelist: [String] = []
}

struct CleanListGroup: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let paths: [PathEntry]

    struct PathEntry: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let size: String
    }
}

extension MoleParse {
    static func cleanPreview(from lines: [String]) -> CleanPreview {
        var preview = CleanPreview()
        let (preamble, sections) = self.sections(from: lines)
        for line in preamble {
            if line.kind == .sub { preview.whitelist.append(line.text) }
            if line.text.contains("Admin access available") { preview.systemIncluded = true }
            if let range = line.text.range(of: "Free space: ") {
                preview.freeSpace = String(line.text[range.upperBound...])
            }
        }
        preview.categories = sections.map { section in
            CleanCategory(title: section.title, entries: section.entries.compactMap { line in
                guard line.kind != .sub else { return nil }
                let parts = line.text.components(separatedBy: " · ")
                let label = parts.first ?? line.text
                var detail = parts.dropFirst().joined(separator: " · ")
                if detail.hasSuffix(" dry") { detail = String(detail.dropLast(4)) }
                return CleanEntry(kind: line.kind, label: label, detail: detail, bytes: bytes(in: detail))
            })
        }
        preview.summary = summary(from: lines)
        if let stats = preview.summary?.details.first(where: { $0.hasPrefix("Potential space:") }) {
            let fields = stats.components(separatedBy: " | ")
            preview.potentialText = fields.first?.replacingOccurrences(of: "Potential space: ", with: "")
            if let items = fields.first(where: { $0.hasPrefix("Items: ") }) {
                preview.itemCount = Int(items.dropFirst(7))
            }
        }
        return preview
    }

    static func cleanList(from text: String) -> [CleanListGroup] {
        var groups: [CleanListGroup] = []
        var title: String?
        var paths: [CleanListGroup.PathEntry] = []
        func close() {
            if let title, !paths.isEmpty { groups.append(CleanListGroup(title: title, paths: paths)) }
            paths = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("==="), trimmed.hasSuffix("===") {
                close()
                title = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
            } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                let parts = trimmed.components(separatedBy: "  # ")
                paths.append(.init(path: parts[0], size: parts.count > 1 ? parts[1] : ""))
            }
        }
        close()
        return groups
    }
}

// MARK: - Purge

extension MoleParse {
    /// `✓ [DRY RUN] ~/Projets/app/node_modules, 72.4MB`
    static func purgeItems(from lines: [String]) -> [DiskItem] {
        lines.compactMap { raw in
            let line = LogLine(id: 0, raw: raw)
            guard line.kind == .success, line.text.hasPrefix("[DRY RUN] ") else { return nil }
            let body = String(line.text.dropFirst("[DRY RUN] ".count))
            guard let comma = body.range(of: ", ", options: .backwards) else { return nil }
            let path = expandTilde(String(body[..<comma.lowerBound]))
            let size = String(body[comma.upperBound...])
            return DiskItem(path: path, sizeText: size, bytes: bytes(in: size) ?? 0, source: projectName(for: path))
        }
    }

    private static func projectName(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

// MARK: - Plan de désinstallation (`mo uninstall --dry-run`)

/// Catégorie déduite du chemin : Mole ne les étiquette pas, il ne donne que des chemins.
enum PlanCategory: Int, CaseIterable, Hashable {
    case application, appSupport, containers, caches, logs, preferences, httpStorage, savedState, launchAgents, other

    var label: String {
        switch self {
        case .application: "Application"
        case .appSupport: "Données de l'app"
        case .containers: "Conteneurs"
        case .caches: "Caches"
        case .logs: "Journaux"
        case .preferences: "Préférences"
        case .httpStorage: "Stockage web"
        case .savedState: "État enregistré"
        case .launchAgents: "Agents de lancement"
        case .other: "Autres fichiers"
        }
    }

    var symbol: String {
        switch self {
        case .application: "app.badge"
        case .appSupport: "folder"
        case .containers: "shippingbox"
        case .caches: "tray.full"
        case .logs: "doc.text"
        case .preferences: "slider.horizontal.3"
        case .httpStorage: "globe"
        case .savedState: "clock.arrow.circlepath"
        case .launchAgents: "bolt.badge.clock"
        case .other: "doc"
        }
    }

    static func of(_ path: String) -> PlanCategory {
        if path.hasSuffix(".app") { return .application }
        if path.contains("/Application Support/") { return .appSupport }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .containers }
        if path.contains("/Caches/") || path.contains("/Caches") { return .caches }
        if path.contains("/Logs/") || path.contains("/Logs") { return .logs }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/HTTPStorages/") { return .httpStorage }
        if path.contains("/Saved Application State/") { return .savedState }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgents }
        return .other
    }
}

struct RemovalPlan: Hashable {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case remove, system, reviewOnly }
        let id = UUID()
        let path: String
        let sizeText: String
        let bytes: Int64
        let kind: Kind
        var category: PlanCategory { PlanCategory.of(path) }
    }

    var entries: [Entry] = []
    /// Avertissements de Mole (ex. restes partagés laissés en place).
    var notes: [String] = []
    /// Mole a réduit le plan au bundle : il n'a pas pu exclure un autre exemplaire de l'app.
    var narrowed = false
    var summary: String?

    var totalBytes: Int64 { entries.filter { $0.kind != .reviewOnly }.map(\.bytes).reduce(0, +) }

    var groups: [(category: PlanCategory, entries: [Entry])] {
        PlanCategory.allCases.compactMap { category in
            let matching = entries.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}

extension MoleParse {
    static func removalPlan(from lines: [String]) -> RemovalPlan {
        var plan = RemovalPlan()
        var inFileList = false
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Files to be removed") { inFileList = true; continue }
            if trimmed.contains("left in place") || trimmed.contains("could not be read") {
                plan.narrowed = true
                // L'invite « Proceed with uninstallation? [y/N] » n'a pas de retour à la ligne :
                // elle se colle au début de l'avertissement.
                var note = trimmed
                if let prompt = note.range(of: "[y/N] ") { note = String(note[prompt.upperBound...]) }
                plan.notes.append(note)
                continue
            }
            if trimmed.hasPrefix("Would remove") || trimmed.hasPrefix("Would free") {
                plan.summary = trimmed
                continue
            }
            guard inFileList else { continue }
            let line = LogLine(id: 0, raw: raw)
            var text = line.text
            var kind = RemovalPlan.Entry.Kind.remove
            for (prefix, value) in [("System:", RemovalPlan.Entry.Kind.system), ("Review only:", .reviewOnly)]
            where text.hasPrefix(prefix) {
                kind = value
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            guard text.hasPrefix("/") || text.hasPrefix("~") else { continue } // en-tête d'app, pas un fichier
            var path = text
            var sizeText = ""
            if let separator = text.range(of: " , ", options: .backwards) {
                path = String(text[..<separator.lowerBound])
                sizeText = String(text[separator.upperBound...])
            }
            plan.entries.append(RemovalPlan.Entry(path: expandTilde(path), sizeText: sizeText,
                                                  bytes: bytes(in: sizeText) ?? 0, kind: kind))
        }
        return plan
    }
}
