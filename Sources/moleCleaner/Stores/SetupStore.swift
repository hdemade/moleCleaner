import AppKit
import Foundation
import Observation

/// Installe la CLI Mole quand elle est absente, par Homebrew ou par le script officiel du projet.
@Observable
@MainActor
final class SetupStore {
    enum Phase: Equatable {
        case idle
        case running
        case installed(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var session: TerminalSession?

    let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Le projet recommande un dossier utilisateur : pas de mot de passe, ni à l'installation
    /// ni aux mises à jour suivantes (le script viserait sinon /usr/local/bin).
    let scriptPrefix = NSHomeDirectory() + "/.local/bin"
    let scriptURL = "https://raw.githubusercontent.com/tw93/mole/main/install.sh"

    var scriptCommand: String {
        "curl -fsSL \(scriptURL) | bash -s -- --prefix \"\(scriptPrefix)\""
    }

    var homebrewCommand: String { "brew install mole" }

    func installViaHomebrew() {
        guard let brewPath else { return }
        run(command: "\"$MC_MO\" install mole 2>&1 | cat",
            moPath: brewPath,
            extraEnv: ["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
    }

    func installViaScript() {
        run(command: "curl -fsSL \"$MC_SCRIPT\" | bash -s -- --prefix \"$MC_PREFIX\" 2>&1 | cat",
            moPath: "/usr/bin/true",
            extraEnv: ["MC_SCRIPT": scriptURL, "MC_PREFIX": scriptPrefix])
    }

    private func run(command: String, moPath: String, extraEnv: [String: String]) {
        guard phase != .running else { return }
        phase = .running
        let session = TerminalSession(title: "Installation de Mole")
        session.onFinish = { [weak self] code in self?.finish(code) }
        session.start(moPath: moPath, command: command, preAuth: false, environment: extraEnv)
        self.session = session
    }

    private func finish(_ code: Int32) {
        guard let path = MoleCLI.locate() else {
            phase = .failed(code == 0
                ? "L'installation s'est terminée mais la commande mo reste introuvable."
                : "L'installation a échoué (code \(code)). Le journal ci-dessus donne le détail.")
            return
        }
        Task {
            let result = await ProcessRunner.run(path, ["--version"])
            phase = .installed(UpdateStore.parseVersion(from: result.output) ?? "installé")
        }
    }

    func dismissSession() {
        session = nil
        if phase == .running { phase = .idle }
    }

    /// Les stores ont été créés sans chemin vers `mo` : un redémarrage est le plus simple et le plus sûr.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
