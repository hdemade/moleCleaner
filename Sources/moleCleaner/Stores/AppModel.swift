import Foundation
import Observation

/// Empêche de lancer deux opérations destructives Mole en même temps.
@Observable
@MainActor
final class TaskLock {
    private(set) var active: String?

    func acquire(_ name: String) -> Bool {
        guard active == nil else { return false }
        active = name
        return true
    }

    func release() { active = nil }
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case status, clean, purge, installers, uninstall, optimize, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "État du système"
        case .clean: "Nettoyage"
        case .purge: "Projets"
        case .installers: "Installeurs"
        case .uninstall: "Désinstallation"
        case .optimize: "Optimisation"
        case .history: "Historique"
        }
    }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .clean: "sparkles"
        case .purge: "shippingbox"
        case .installers: "externaldrive.badge.minus"
        case .uninstall: "app.badge.checkmark"
        case .optimize: "wrench.and.screwdriver"
        case .history: "clock.arrow.circlepath"
        }
    }
}

@Observable
@MainActor
final class AppModel {
    var page: Page? = .status
    let moPath: String?
    let libexec: String?
    var version: String?

    let lock = TaskLock()
    let status: StatusStore
    let clean: CleanStore
    let purge: DiskItemStore
    let installers: DiskItemStore
    let uninstall: UninstallStore
    let optimize: OptimizeStore
    let history: HistoryStore
    let update: UpdateStore
    let setup = SetupStore()

    init() {
        let mo = MoleCLI.locate()
        moPath = mo
        libexec = mo.flatMap(MoleCLI.libexecDirectory(for:))
        let path = mo ?? "/opt/homebrew/bin/mo"
        status = StatusStore(moPath: path)
        clean = CleanStore(moPath: path, lock: lock)
        purge = DiskItemStore(kind: .purge, moPath: path, libexec: libexec, lock: lock)
        installers = DiskItemStore(kind: .installers, moPath: path, libexec: libexec, lock: lock)
        uninstall = UninstallStore(moPath: path, lock: lock)
        optimize = OptimizeStore(moPath: path, lock: lock)
        history = HistoryStore(moPath: path)
        update = UpdateStore(moPath: path, lock: lock)
    }

    var isMoleInstalled: Bool { moPath != nil }
    private var bootstrapped = false

    func bootstrap() async {
        guard !bootstrapped, moPath != nil else { return }
        bootstrapped = true
        status.start()
        update.onRefresh = { [weak self] in await self?.refreshAfterUpdate() }
        await loadVersion()
        if update.autoCheck {
            Task { await update.checkIfStale() }
        }
    }

    private func loadVersion() async {
        guard let moPath else { return }
        let result = await ProcessRunner.run(moPath, ["--version"])
        version = UpdateStore.parseVersion(from: result.output)
        update.currentVersion = version
    }

    /// Après une mise à jour : le binaire a été remplacé, donc on relit la version
    /// et on relance le collecteur qui tournait depuis l'ancienne installation.
    private func refreshAfterUpdate() async {
        await loadVersion()
        status.restart()
    }
}
