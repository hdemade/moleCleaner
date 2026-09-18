import AppKit
import Foundation
import Observation

// MARK: - Nettoyage (`mo clean`)

@Observable
@MainActor
final class CleanStore {
    enum Phase { case idle, scanning, preview, running }

    private(set) var phase: Phase = .idle
    private(set) var scanLineCount = 0
    private(set) var currentSection: String?
    private(set) var preview: CleanPreview?
    private(set) var fileGroups: [CleanListGroup] = []
    private(set) var session: TerminalSession?
    var lastError: String?

    private let moPath: String
    private let lock: TaskLock
    private var scanLines: [String] = []
    private var scanProcess: StreamingProcess?

    init(moPath: String, lock: TaskLock) {
        self.moPath = moPath
        self.lock = lock
    }

    func scan() {
        guard phase != .scanning, phase != .running else { return }
        phase = .scanning
        scanLines = []
        scanLineCount = 0
        currentSection = nil
        lastError = nil
        session = nil
        let proc = StreamingProcess(executable: moPath, arguments: ["clean", "--dry-run"])
        proc.onLines = { [weak self] lines, _ in
            guard let self else { return }
            for line in lines {
                let clean = ANSI.cleanLine(line)
                self.scanLines.append(clean)
                let parsed = LogLine(id: 0, raw: clean)
                if parsed.kind == .section { self.currentSection = parsed.text }
            }
            self.scanLineCount = self.scanLines.count
        }
        proc.onExit = { [weak self] _ in
            guard let self, self.phase == .scanning else { return }
            self.scanProcess = nil
            self.preview = MoleParse.cleanPreview(from: self.scanLines)
            if let text = try? String(contentsOfFile: MoleCLI.cleanListFile, encoding: .utf8) {
                self.fileGroups = MoleParse.cleanList(from: text)
            }
            self.phase = .preview
        }
        scanProcess = proc
        do { try proc.start() } catch {
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    func cancelScan() {
        scanProcess?.terminate()
        scanProcess = nil
        phase = preview == nil ? .idle : .preview
    }

    func run(includeSystem: Bool) {
        guard lock.acquire("Nettoyage") else {
            lastError = "Une autre opération est en cours (\(lock.active ?? "")) ."
            return
        }
        let session = TerminalSession(title: "Nettoyage")
        session.onFinish = { [weak self] _ in
            self?.lock.release()
            self?.preview = nil
        }
        // stdin = /dev/null → Mole passe en mode non interactif ; `| cat` évite les animations.
        session.start(moPath: moPath, command: "\"$MC_MO\" clean </dev/null 2>&1 | cat", preAuth: includeSystem, allowPassword: includeSystem)
        self.session = session
        phase = .running
    }

    func reset() {
        session = nil
        phase = preview == nil ? .idle : .preview
    }

    /// Ajoute un chemin à la liste de protection de Mole (`~/.config/mole/whitelist`).
    func protect(_ path: String) {
        do {
            try Whitelist.add(path)
            if var preview { preview.whitelist.append(path); self.preview = preview }
        } catch {
            lastError = "Impossible de modifier la whitelist : \(error.localizedDescription)"
        }
    }
}

enum Whitelist {
    static func entries() -> [String] {
        guard let text = try? String(contentsOfFile: MoleCLI.whitelistFile, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func add(_ path: String) throws {
        guard !entries().contains(path) else { return }
        try FileManager.default.createDirectory(atPath: MoleCLI.configDirectory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: MoleCLI.whitelistFile)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += path + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Purge & Installeurs : détection par Mole, mise à la Corbeille par l'app

@Observable
@MainActor
final class DiskItemStore {
    enum Kind { case purge, installers }
    enum Phase { case idle, scanning, ready, trashing }

    struct TrashReport {
        let count: Int
        let bytes: Int64
        let failures: [String]
    }

    let kind: Kind
    private(set) var phase: Phase = .idle
    private(set) var items: [DiskItem] = []
    var selection: Set<String> = []
    private(set) var report: TrashReport?
    var lastError: String?

    private let moPath: String
    private let libexec: String?
    private let lock: TaskLock

    init(kind: Kind, moPath: String, libexec: String?, lock: TaskLock) {
        self.kind = kind
        self.moPath = moPath
        self.libexec = libexec
        self.lock = lock
    }

    var selectedItems: [DiskItem] { items.filter { selection.contains($0.path) } }
    var selectedBytes: Int64 { selectedItems.map(\.bytes).reduce(0, +) }
    var totalBytes: Int64 { items.map(\.bytes).reduce(0, +) }

    func scan() async {
        guard phase != .scanning, phase != .trashing else { return }
        phase = .scanning
        lastError = nil
        report = nil
        switch kind {
        case .purge:
            let result = await ProcessRunner.run(moPath, ["purge", "--dry-run"])
            let lines = result.output.components(separatedBy: .newlines).map(ANSI.cleanLine)
            items = MoleParse.purgeItems(from: lines).sorted { $0.bytes > $1.bytes }
        case .installers:
            items = await scanInstallers().sorted { $0.bytes > $1.bytes }
        }
        selection = selection.filter { path in items.contains { $0.path == path } }
        phase = .ready
    }

    /// Réutilise la détection de Mole (`collect_installers`) en sourçant installer.sh sans lancer son menu.
    private func scanInstallers() async -> [DiskItem] {
        guard let libexec else {
            lastError = "Dossier interne de Mole introuvable."
            return []
        }
        let script = """
        source "$1/bin/installer.sh" || exit 3
        collect_installers >/dev/null 2>&1 || exit 0
        for i in "${!INSTALLER_PATHS[@]}"; do
          printf '%s\\t%s\\t%s\\n' "${INSTALLER_PATHS[$i]}" "${INSTALLER_SIZES[$i]}" "${INSTALLER_SOURCES[$i]}"
        done
        """
        var env = MoleCLI.environment
        env["MOLE_TEST_MODE"] = "1" // empêche installer.sh de lancer son main interactif
        let result = await ProcessRunner.run("/bin/bash", ["-c", script, "moleCleaner", libexec], environment: env, includeStderr: false)
        if result.status == 3 { lastError = "Impossible de charger le module installeurs de Mole." }
        return result.output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3, fields[0].hasPrefix("/") else { return nil }
            let bytes = Int64(fields[1]) ?? 0
            return DiskItem(path: fields[0], sizeText: Format.bytes(bytes), bytes: bytes, source: fields[2])
        }
    }

    func trashSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        guard lock.acquire(kind == .purge ? "Projets" : "Installeurs") else {
            lastError = "Une autre opération est en cours (\(lock.active ?? ""))."
            return
        }
        phase = .trashing
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
            var trashed: [String] = []
            var failures: [String] = []
            for item in targets {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    trashed.append(item.path)
                } catch {
                    failures.append("\(item.name) : \(error.localizedDescription)")
                }
            }
            return (trashed, failures)
        }.value
        let trashedSet = Set(outcome.0)
        let bytes = items.filter { trashedSet.contains($0.path) }.map(\.bytes).reduce(0, +)
        items.removeAll { trashedSet.contains($0.path) }
        selection.subtract(trashedSet)
        report = TrashReport(count: trashedSet.count, bytes: bytes, failures: outcome.1)
        phase = .ready
        lock.release()
    }
}

// MARK: - Désinstallation (`mo uninstall`)

@Observable
@MainActor
final class UninstallStore {
    private(set) var apps: [InstalledApp] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var loading = false
    private(set) var session: TerminalSession?
    var selection: Set<String> = []
    var search = ""
    var lastError: String?

    private let moPath: String
    private let lock: TaskLock
    private var sizeTask: Task<Void, Never>?

    enum PlanState {
        case loading
        case ready(RemovalPlan)
        case failed(String)
    }

    /// Plan de suppression par app, mis en cache (le scan de Mole prend quelques secondes).
    private(set) var plans: [String: PlanState] = [:]
    private(set) var expanded: Set<String> = []

    init(moPath: String, lock: TaskLock) {
        self.moPath = moPath
        self.lock = lock
    }

    func toggleDetail(_ app: InstalledApp) {
        setExpanded(app, expanded.contains(app.path) ? false : true)
    }

    func setExpanded(_ app: InstalledApp, _ on: Bool) {
        if on {
            expanded.insert(app.path)
            if plans[app.path] == nil { Task { await loadPlan(app) } }
        } else {
            expanded.remove(app.path)
        }
    }

    /// Cocher une app déplie son détail et déclenche le scan : le plan est prêt avant la confirmation.
    func setSelected(_ app: InstalledApp, _ on: Bool) {
        if on { selection.insert(app.path) } else { selection.remove(app.path) }
        setExpanded(app, on)
    }

    func clearSelection() {
        expanded.subtract(selection)
        selection = []
    }

    func reloadPlan(_ app: InstalledApp) {
        plans[app.path] = nil
        Task { await loadPlan(app) }
    }

    /// `mo uninstall --dry-run` n'écrit ni ne supprime rien : il imprime le plan.
    /// Il pose deux confirmations, auxquelles on répond par le tube d'entrée.
    private func loadPlan(_ app: InstalledApp) async {
        plans[app.path] = .loading
        var env = MoleCLI.environment
        env["MC_MO"] = moPath
        let script = "printf 'y\n' | \"$MC_MO\" uninstall --dry-run \"$1\" 2>&1"
        let result = await ProcessRunner.run("/bin/bash", ["-c", script, "moleCleaner", app.uninstall_name],
                                             environment: env)
        let lines = result.output.components(separatedBy: .newlines).map(ANSI.cleanLine)
        let plan = MoleParse.removalPlan(from: lines)
        if plan.entries.isEmpty {
            plans[app.path] = .failed("Mole n'a pas produit de plan pour cette app.")
        } else {
            plans[app.path] = .ready(plan)
        }
    }

    var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundle_id.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.path) } }

    func load() async {
        loading = true
        defer { loading = false }
        // Une actualisation repart de zéro : les plans en cache décrivent l'état d'avant.
        selection = []
        expanded = []
        plans = [:]
        let result = await ProcessRunner.run(moPath, ["uninstall", "--list"], includeStderr: false)
        guard let start = result.output.firstIndex(of: "["),
              let data = String(result.output[start...]).data(using: .utf8),
              let list = try? JSONDecoder().decode([InstalledApp].self, from: data) else {
            lastError = "Impossible de lire la liste des applications."
            return
        }
        apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastError = nil
        computeSizes()
    }

    /// Mole renvoie souvent « -- » : on mesure les .app en arrière-plan.
    private func computeSizes() {
        sizeTask?.cancel()
        let paths = apps.map(\.path).filter { sizes[$0] == nil }
        sizeTask = Task { [weak self] in
            for path in paths {
                if Task.isCancelled { return }
                let result = await ProcessRunner.run("/usr/bin/du", ["-sk", path], includeStderr: false)
                if let kb = Int64(result.output.split(separator: "\t").first ?? "") {
                    self?.sizes[path] = kb * 1024
                }
            }
        }
    }

    func uninstallSelected() {
        let targets = selectedApps
        guard !targets.isEmpty else { return }
        guard lock.acquire("Désinstallation") else {
            lastError = "Une autre opération est en cours (\(lock.active ?? ""))."
            return
        }
        let session = TerminalSession(title: "Désinstallation", responders: [
            .init(contains: "[y/N]", reply: "y\n"),
            .init(contains: "Enter confirm", reply: "y"),
        ])
        session.onFinish = { [weak self] _ in
            guard let self else { return }
            self.lock.release()
            self.selection = []
            Task { await self.load() }
        }
        session.start(moPath: moPath, command: "\"$MC_MO\" uninstall \"$@\"", arguments: targets.map(\.uninstall_name), preAuth: false)
        self.session = session
    }

    func dismissSession() { session = nil }
}

// MARK: - Optimisation (`mo optimize`)

@Observable
@MainActor
final class OptimizeStore {
    private(set) var previewSections: [OutputSection] = []
    private(set) var previewSummary: MoleSummary?
    private(set) var diagnosis: [LogLine] = []
    private(set) var loadingPreview = false
    private(set) var session: TerminalSession?
    var lastError: String?

    private let moPath: String
    private let lock: TaskLock

    init(moPath: String, lock: TaskLock) {
        self.moPath = moPath
        self.lock = lock
    }

    func loadPreview() async {
        loadingPreview = true
        defer { loadingPreview = false }
        let result = await ProcessRunner.run(moPath, ["optimize", "--dry-run"])
        let lines = result.output.components(separatedBy: .newlines).map(ANSI.cleanLine)
        let parsed = MoleParse.sections(from: lines)
        diagnosis = parsed.sections.first { $0.title.localizedCaseInsensitiveContains("diagnosis") }?.entries ?? []
        previewSections = parsed.sections.filter { !$0.title.localizedCaseInsensitiveContains("diagnosis") }
        previewSummary = MoleParse.summary(from: lines)
    }

    func run(withAdmin: Bool) {
        guard lock.acquire("Optimisation") else {
            lastError = "Une autre opération est en cours (\(lock.active ?? ""))."
            return
        }
        let session = TerminalSession(title: "Optimisation")
        session.onFinish = { [weak self] _ in self?.lock.release() }
        session.start(moPath: moPath, command: "\"$MC_MO\" optimize </dev/null 2>&1 | cat", preAuth: withAdmin, allowPassword: withAdmin)
        self.session = session
    }

    func dismissSession() { session = nil }
}
