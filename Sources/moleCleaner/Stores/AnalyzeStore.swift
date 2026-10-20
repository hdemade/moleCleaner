import Foundation
import Observation

// MARK: - Analyse du disque (`mo analyze --json [chemin]`)

struct AnalyzeResult: Decodable {
    var scan_status: String?
    var path: String
    var overview: Bool?
    var entries: [Entry]
    var large_files: [LargeFile]?
    var total_size: Int64?
    var total_files: Int?

    struct Entry: Decodable, Identifiable, Hashable {
        var scan_status: String?
        var name: String
        var path: String
        var size: Int64
        var is_dir: Bool?
        var insight: Bool?
        var id: String { path }
        var isDirectory: Bool { is_dir ?? false }
        var isInsight: Bool { insight ?? false }
    }

    struct LargeFile: Decodable, Identifiable, Hashable {
        var name: String
        var path: String
        var size: Int64
        var id: String { path }
    }

    var isPartial: Bool { scan_status == "partial" }
}

/// Capacité du volume de démarrage, telle que l'affiche le Finder (l'espace purgeable compte comme libre).
struct VolumeCapacity {
    let total: Int64
    let available: Int64
    var used: Int64 { max(total - available, 0) }

    static func read(path: String = "/") -> VolumeCapacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeCapacity(total: Int64(total), available: available)
    }
}

/// Navigation dans l'analyse : vue d'ensemble du Mac, puis dossiers ouverts un à un.
/// Chaque résultat est gardé en mémoire : revenir en arrière ne relance pas Mole.
@Observable
@MainActor
final class AnalyzeStore {
    /// `nil` = vue d'ensemble de la machine.
    private(set) var path: String?
    private(set) var backStack: [String?] = []
    private(set) var results: [String: AnalyzeResult] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var capacity: VolumeCapacity?
    /// Dates de modification lues dans le système de fichiers : Mole ne les fournit pas.
    private(set) var modified: [String: Date] = [:]

    private let moPath: String

    init(moPath: String) {
        self.moPath = moPath
    }

    private static func key(_ path: String?) -> String { path ?? "" }

    var current: AnalyzeResult? { results[Self.key(path)] }
    var isLoading: Bool { loading.contains(Self.key(path)) }
    var lastError: String? { errors[Self.key(path)] }
    var isOverview: Bool { path == nil }

    /// Premier affichage de la page : lance la vue d'ensemble si elle n'a jamais été chargée.
    func start() async {
        if current == nil && !isLoading { await load(path, refine: true) }
    }

    func open(_ newPath: String?) {
        guard newPath != path else { return }
        backStack.append(path)
        path = newPath
        if results[Self.key(newPath)] == nil { Task { await load(newPath, refine: true) } }
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        path = previous
        if results[Self.key(previous)] == nil { Task { await load(previous, refine: true) } }
    }

    func refresh() {
        let target = path
        Task { await load(target, refine: true) }
    }

    /// La vue d'ensemble de Mole est une estimation rapide, parfois très inférieure à la réalité
    /// (le dossier personnel peut être compté à moitié). On analyse donc chacun de ses emplacements
    /// comme un dossier : les tailles affichées sont alors celles que l'on retrouve en l'ouvrant.
    private func refineOverview(_ overview: AnalyzeResult, force: Bool) async {
        let paths = overview.entries
            .filter { !$0.isInsight && $0.isDirectory && $0.size > 0 }
            .map(\.path)
            .filter { force || results[$0] == nil }
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { await self.load(path) }
            }
        }
    }

    private func readModificationDates(_ result: AnalyzeResult) async {
        let paths = result.entries.map(\.path) + (result.large_files ?? []).map(\.path)
        let dates = await Task.detached(priority: .utility) {
            var dates: [String: Date] = [:]
            for path in paths {
                let url = URL(fileURLWithPath: path)
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    dates[path] = date
                }
            }
            return dates
        }.value
        modified.merge(dates) { _, new in new }
    }

    /// Taille d'un emplacement de la vue d'ensemble : celle de son analyse détaillée dès qu'elle existe.
    func refinedSize(of entry: AnalyzeResult.Entry) -> Int64 {
        results[entry.path]?.total_size ?? entry.size
    }

    func isRefining(_ path: String) -> Bool { loading.contains(path) }

    /// `refine` : pour la vue d'ensemble, relance aussi l'analyse détaillée de chaque emplacement.
    private func load(_ target: String?, refine: Bool = false) async {
        let key = Self.key(target)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        errors[key] = nil
        capacity = VolumeCapacity.read()
        defer { loading.remove(key) }

        var arguments = ["analyze", "--json"]
        if let target { arguments.append(target) }
        let result = await ProcessRunner.run(moPath, arguments, includeStderr: false)
        // La sortie doit être un objet JSON : on ignore un éventuel texte avant l'accolade.
        guard let start = result.output.firstIndex(of: "{"),
              let decoded = try? JSONDecoder().decode(AnalyzeResult.self, from: Data(result.output[start...].utf8)) else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            errors[key] = "mo analyze n'a pas renvoyé de résultat lisible" + (detail.isEmpty ? "." : " : \(detail.prefix(300))")
            return
        }
        results[key] = decoded
        await readModificationDates(decoded)
        if target == nil && refine {
            loading.remove(key)
            await refineOverview(decoded, force: true)
        }
    }
}
