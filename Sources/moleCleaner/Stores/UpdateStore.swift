import Foundation
import Observation

/// Vérifie et installe les mises à jour de Mole.
///
/// La vérification est en lecture seule : version installée via `mo --version`, dernière version
/// publiée via l'API GitHub, et — pour une installation Homebrew — `brew outdated` pour savoir si
/// la formule est déjà publiée (une version peut exister sur GitHub avant d'arriver dans Homebrew).
/// L'installation délègue à `mo update`, qui choisit lui-même son canal (Homebrew ou script).
@Observable
@MainActor
final class UpdateStore {
    enum InstallMethod {
        case homebrew, script

        var label: String {
            switch self {
            case .homebrew: "Homebrew"
            case .script: "script d'installation"
            }
        }
    }

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        /// Installable tout de suite.
        case available(String)
        /// Publiée sur GitHub mais pas encore disponible dans la formule Homebrew locale.
        case pendingHomebrew(String)
        case failed(String)
    }

    private(set) var status: Status = .unknown
    var currentVersion: String?
    private(set) var lastChecked: Date?
    private(set) var session: TerminalSession?
    let installMethod: InstallMethod
    var showSheet = false
    /// Appelé après une mise à jour réussie pour relire la version et relancer le monitoring.
    var onRefresh: (() async -> Void)?

    private let moPath: String
    private let lock: TaskLock
    private static let latestKey = "updateLatestVersion"
    private static let checkedKey = "updateLastChecked"
    private static let autoKey = "autoCheckUpdates"
    private static let staleAfter: TimeInterval = 60 * 60 * 24

    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoKey) }
    }

    init(moPath: String, lock: TaskLock) {
        self.moPath = moPath
        self.lock = lock
        installMethod = (moPath as NSString).resolvingSymlinksInPath.contains("Cellar/mole") ? .homebrew : .script
        let defaults = UserDefaults.standard
        autoCheck = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        if let stamp = defaults.object(forKey: Self.checkedKey) as? Double {
            lastChecked = Date(timeIntervalSince1970: stamp)
        }
    }

    // MARK: - État dérivé

    var newVersion: String? {
        switch status {
        case .available(let version), .pendingHomebrew(let version): version
        default: nil
        }
    }

    var isChecking: Bool { status == .checking }
    var isUpdating: Bool { session?.isRunning ?? false }
    var releaseNotesURL = URL(string: "https://github.com/tw93/Mole/releases/latest")!

    // MARK: - Vérification

    /// Vérifie au plus une fois par jour, en réutilisant le dernier résultat connu.
    func checkIfStale() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.staleAfter, restoreCached() { return }
        await check()
    }

    private func restoreCached() -> Bool {
        guard let current = currentVersion else { return false }
        guard let cached = UserDefaults.standard.string(forKey: Self.latestKey), !cached.isEmpty else {
            status = .upToDate
            return true
        }
        status = isNewer(cached, than: current) ? .available(cached) : .upToDate
        return true
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking

        var resolved = currentVersion
        if resolved == nil { resolved = await installedVersion() }
        guard let current = resolved else {
            status = .failed("Version installée introuvable.")
            return
        }
        currentVersion = current

        guard let latest = await latestPublishedVersion() else {
            status = .failed("Impossible de contacter GitHub. Vérifie ta connexion.")
            return
        }

        lastChecked = Date()
        UserDefaults.standard.set(lastChecked?.timeIntervalSince1970, forKey: Self.checkedKey)
        UserDefaults.standard.set(latest, forKey: Self.latestKey)

        guard isNewer(latest, than: current) else {
            status = .upToDate
            return
        }
        guard installMethod == .homebrew else {
            status = .available(latest)
            return
        }
        // Mole n'annonce une mise à jour Homebrew que si la formule locale la propose déjà.
        if let brewVersion = await homebrewAvailableVersion(), isNewer(brewVersion, than: current) {
            status = .available(brewVersion)
        } else {
            status = .pendingHomebrew(latest)
        }
    }

    private func installedVersion() async -> String? {
        let result = await ProcessRunner.run(moPath, ["--version"])
        return Self.parseVersion(from: result.output)
    }

    static func parseVersion(from output: String) -> String? {
        output.components(separatedBy: .newlines)
            .first { $0.hasPrefix("Mole version") }?
            .replacingOccurrences(of: "Mole version ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func latestPublishedVersion() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/tw93/Mole/releases/latest")!)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Release: Decodable { let tag_name: String }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
            var version = tag
            for prefix in ["v", "V"] where version.hasPrefix(prefix) { version.removeFirst() }
            return version.isEmpty ? nil : version
        } catch {
            return nil
        }
    }

    /// `brew outdated --formula --verbose mole` → « mole (1.53.0) < 1.54.0 ».
    private func homebrewAvailableVersion() async -> String? {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        var env = MoleCLI.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        let result = await ProcessRunner.run(brew, ["outdated", "--formula", "--verbose", "mole"],
                                             environment: env, includeStderr: false)
        guard let line = result.output.components(separatedBy: .newlines).first(where: { $0.contains("< ") }),
              let range = line.range(of: "< ") else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    // MARK: - Installation

    func startUpdate() {
        guard session?.isRunning != true else { return }
        guard lock.acquire("Mise à jour") else {
            status = .failed("Une autre opération est en cours (\(lock.active ?? "")).")
            return
        }
        let session = TerminalSession(title: "Mise à jour de Mole")
        session.onFinish = { [weak self] _ in
            guard let self else { return }
            self.lock.release()
            Task {
                await self.onRefresh?()
                await self.check()
            }
        }
        // `mo update` choisit son canal : brew update + brew upgrade, ou réinstallation par script.
        session.start(moPath: moPath, command: "\"$MC_MO\" update </dev/null 2>&1 | cat", preAuth: false)
        self.session = session
    }

    func dismissSession() { session = nil }
}
