import AppKit
import CryptoKit
import Foundation
import Observation

// MARK: - Recherche de doublons
// Mole n'a pas de commande pour les doublons : l'app les cherche elle-même, en trois passes de
// plus en plus coûteuses. On regroupe d'abord par taille, puis on compare le début et la fin des
// fichiers, et seuls les fichiers encore identiques sont lus en entier (empreinte SHA-256).

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    let modified: Date?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let size: Int64
    var files: [DuplicateFile]
    /// Place libérée en ne gardant qu'un exemplaire.
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

enum DuplicateScanner {
    enum Phase: Sendable {
        case listing, quickCompare, fullCompare
    }

    struct Progress: Sendable {
        var phase: Phase
        var filesSeen = 0
        var done: Int64 = 0
        var total: Int64 = 0
        var fraction: Double? { total > 0 ? min(Double(done) / Double(total), 1) : nil }
    }

    private struct Candidate {
        let url: URL
        let size: Int64
        let modified: Date?
    }

    /// Dossiers de dépendances et de build, régénérables et pleins de copies voulues : les parcourir
    /// rallonge beaucoup la recherche pour des résultats inutiles (Projets s'en occupe déjà).
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "DerivedData", "bower_components", "__pycache__"]

    private static let edgeLength = 64 * 1024
    private static let chunkLength = 1024 * 1024

    /// Bloquant : à lancer hors du thread principal. S'arrête (CancellationError) si la tâche est annulée.
    static func scan(roots: [URL], excluding: [String], minSize: Int64,
                     report: @escaping @Sendable (Progress) -> Void) throws -> [DuplicateGroup] {
        var progress = Progress(phase: .listing)
        var lastReport = Date.distantPast
        func tick(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.15 {
                lastReport = now
                report(progress)
            }
        }

        // 1. Liste des fichiers, regroupés par taille.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .fileResourceIdentifierKey, .isUbiquitousItemKey,
                                      .ubiquitousItemDownloadingStatusKey]
        let keySet = Set(keys)
        var bySize: [Int64: [Candidate]] = [:]
        var seenFiles = Set<NSObject>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                // Les paquets (apps, photothèques…) ne sont pas ouverts : on n'y supprime rien fichier par fichier.
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let path = url.path
                if excluding.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if values.isDirectory == true {
                    if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, Int64(size) >= minSize else { continue }
                // Un fichier iCloud non téléchargé serait rapatrié rien que pour être lu.
                if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded { continue }
                // Liens physiques : un même fichier sous deux noms n'est pas un doublon.
                if let identifier = values.fileResourceIdentifier as? NSObject {
                    guard seenFiles.insert(identifier).inserted else { continue }
                }
                bySize[Int64(size), default: []].append(Candidate(url: url, size: Int64(size), modified: values.contentModificationDate))
                progress.filesSeen += 1
                tick()
            }
        }

        // 2. Comparaison rapide : début et fin des fichiers de même taille.
        let sameSize = bySize.values.filter { $0.count > 1 }
        progress.phase = .quickCompare
        progress.done = 0
        progress.total = Int64(sameSize.map(\.count).reduce(0, +))
        tick(force: true)
        var quickGroups: [[Candidate]] = []
        for group in sameSize {
            var byEdges: [String: [Candidate]] = [:]
            for candidate in group {
                try Task.checkCancellation()
                if let key = edgesHash(candidate.url, size: candidate.size) {
                    byEdges[key, default: []].append(candidate)
                }
                progress.done += 1
                tick()
            }
            quickGroups += byEdges.values.filter { $0.count > 1 }
        }

        // 3. Lecture complète des fichiers encore identiques.
        progress.phase = .fullCompare
        progress.done = 0
        progress.total = quickGroups.flatMap { $0 }.map(\.size).reduce(0, +)
        tick(force: true)
        var result: [DuplicateGroup] = []
        for group in quickGroups {
            var byHash: [String: [Candidate]] = [:]
            for candidate in group {
                let hash: String?
                if candidate.size <= Int64(2 * edgeLength) {
                    // Fichier déjà lu entièrement par la passe rapide : inutile de le relire.
                    hash = edgesHash(candidate.url, size: candidate.size)
                    progress.done += candidate.size
                } else {
                    hash = try fullHash(candidate.url) { read in
                        progress.done += read
                        tick()
                    }
                }
                if let hash { byHash[hash, default: []].append(candidate) }
            }
            for (hash, files) in byHash where files.count > 1 {
                let sorted = files
                    .map { DuplicateFile(path: $0.url.path, modified: $0.modified) }
                    .sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                result.append(DuplicateGroup(id: hash, size: group[0].size, files: sorted))
            }
        }
        tick(force: true)
        return result.sorted { $0.wasted > $1.wasted }
    }

    private static func edgesHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: edgeLength) else { return nil }
        hasher.update(data: head)
        if size > Int64(2 * edgeLength) {
            guard (try? handle.seek(toOffset: UInt64(size) - UInt64(edgeLength))) != nil,
                  let tail = try? handle.read(upToCount: edgeLength) else { return nil }
            hasher.update(data: tail)
        } else if let rest = try? handle.readToEnd() {
            // Petit fichier : le reste est lu ici, l'empreinte couvre donc tout son contenu.
            hasher.update(data: rest)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(_ url: URL, onRead: (Int64) -> Void) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            // `read` renvoie nil en fin de fichier ; une erreur de lecture écarte le fichier.
            let read: Result<Data?, Error> = autoreleasepool { Result { try handle.read(upToCount: chunkLength) } }
            guard case .success(let data) = read else { return nil }
            guard let chunk = data, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            onRead(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@Observable
@MainActor
final class DuplicatesStore {
    enum Scope: String, Hashable { case home, folder }
    enum Phase { case idle, scanning, ready, trashing }

    struct TrashReport {
        let count: Int
        let bytes: Int64
        let failures: [String]
    }

    var scope: Scope = .home
    private(set) var folder: URL?
    var minSize: Int64 {
        didSet { UserDefaults.standard.set(minSize, forKey: "duplicatesMinSize") }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: DuplicateScanner.Progress?
    private(set) var groups: [DuplicateGroup] = []
    /// Ce qui a été analysé, pour l'afficher au-dessus des résultats.
    private(set) var scannedLabel: String?
    var selection: Set<String> = []
    var lastError: String?
    private(set) var report: TrashReport?

    private let lock: TaskLock
    private var task: Task<Void, Never>?

    static let home = URL(fileURLWithPath: NSHomeDirectory())
    /// Recherche globale : le dossier personnel, sans la Bibliothèque (données internes des apps,
    /// caches, iCloud Drive) où supprimer un fichier en double casserait l'app qui l'utilise.
    static let homeExclusions = [NSHomeDirectory() + "/Library"]

    init(lock: TaskLock) {
        self.lock = lock
        let stored = (UserDefaults.standard.object(forKey: "duplicatesMinSize") as? NSNumber)?.int64Value
        minSize = stored ?? 1_000_000
    }

    var canStart: Bool { scope == .home || folder != nil }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Choisis le dossier dans lequel chercher des doublons."
        panel.directoryURL = folder ?? Self.home
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            scope = .folder
        }
    }

    func start() {
        guard phase != .scanning, phase != .trashing else { return }
        let roots: [URL]
        let exclusions: [String]
        switch scope {
        case .home:
            roots = [Self.home]
            exclusions = Self.homeExclusions
            scannedLabel = "Dossier personnel, hors Bibliothèque"
        case .folder:
            guard let folder else { return }
            roots = [folder]
            exclusions = []
            scannedLabel = AnalyzeView.shortPath(folder.path)
        }
        let minSize = minSize
        phase = .scanning
        groups = []
        selection = []
        report = nil
        lastError = nil
        progress = DuplicateScanner.Progress(phase: .listing)

        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try DuplicateScanner.scan(roots: roots, excluding: exclusions, minSize: minSize) { progress in
                    // Le magasin vit aussi longtemps que l'app : capture forte sans risque.
                    Task { @MainActor in
                        guard self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
            }
            let outcome = await withTaskCancellationHandler {
                await work.result
            } onCancel: {
                work.cancel()
            }
            switch outcome {
            case .success(let found):
                groups = found
                phase = .ready
            case .failure:
                // Annulation : on revient à l'écran de départ.
                phase = groups.isEmpty ? .idle : .ready
            }
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Sélection

    var totalWasted: Int64 { groups.map(\.wasted).reduce(0, +) }

    var selectedBytes: Int64 {
        groups.flatMap { group in group.files.filter { selection.contains($0.path) }.map { _ in group.size } }.reduce(0, +)
    }

    /// Groupes dont tous les exemplaires sont cochés : les supprimer ferait perdre le fichier.
    var fullySelectedGroups: Int {
        groups.filter { group in group.files.allSatisfy { selection.contains($0.path) } }.count
    }

    /// Coche toutes les copies en gardant, dans chaque groupe, le fichier le plus ancien.
    func selectCopies() {
        selection = Set(groups.flatMap { $0.files.dropFirst().map(\.path) })
    }

    func trashSelected() async {
        let targets = groups.flatMap { $0.files }.filter { selection.contains($0.path) }
        guard !targets.isEmpty, fullySelectedGroups == 0 else { return }
        guard lock.acquire("Doublons") else {
            lastError = "Une autre opération est en cours (\(lock.active ?? ""))."
            return
        }
        phase = .trashing
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
            var trashed: [String] = []
            var failures: [String] = []
            for file in targets {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                    trashed.append(file.path)
                } catch {
                    failures.append("\(file.name) : \(error.localizedDescription)")
                }
            }
            return (trashed, failures)
        }.value
        let trashed = Set(outcome.0)
        let bytes = groups.map { group in Int64(group.files.filter { trashed.contains($0.path) }.count) * group.size }.reduce(0, +)
        groups = groups
            .map { group in
                var group = group
                group.files.removeAll { trashed.contains($0.path) }
                return group
            }
            .filter { $0.files.count > 1 }
        selection.subtract(trashed)
        report = TrashReport(count: trashed.count, bytes: bytes, failures: outcome.1)
        phase = .ready
        lock.release()
    }
}
