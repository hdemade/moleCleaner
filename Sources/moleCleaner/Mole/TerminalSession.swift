import Foundation
import Observation

/// Exécute une commande Mole dans un pseudo-terminal (via /usr/bin/script) pour que sudo
/// dispose d'un terminal de contrôle. Les invites de mot de passe sont remontées à l'UI ;
/// le mot de passe est écrit dans le PTY puis oublié, jamais stocké ni journalisé.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        case finished(Int32)
        case failed(String)
    }

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let retry: Bool
    }

    /// Réponse automatique à une invite connue (ex. confirmation déjà donnée dans l'app).
    struct Responder {
        let contains: String
        let reply: String
    }

    static let passwordMarker = "[moleCleaner] password:"
    private static let adminOK = "[moleCleaner] admin-ok"
    private static let adminSkipped = "[moleCleaner] admin-skipped"
    private static let passwordRegex = try! NSRegularExpression(pattern: "(?i)(password|mot de passe)[^:\\n]{0,60}:\\s*$")

    let id = UUID()
    let title: String
    private(set) var lines: [LogLine] = []
    private(set) var rawLines: [String] = []
    private(set) var state: State = .running
    var passwordRequest: PasswordRequest?

    private var process: StreamingProcess?
    private let responders: [Responder]
    private var lastHandledTail = ""
    private var declined = false
    private var sawSorry = false
    private var nextLineID = 0
    var onFinish: ((Int32) -> Void)?

    init(title: String, responders: [Responder] = []) {
        self.title = title
        self.responders = responders
    }

    var isRunning: Bool { state == .running }

    /// `command` est une ligne bash qui peut utiliser `"$MC_MO"` et `"$@"` (arguments passés à part, sans injection).
    /// `allowPassword = false` : toute invite de mot de passe est refusée automatiquement (mode sans admin).
    func start(moPath: String, command: String, arguments: [String] = [], preAuth: Bool,
               allowPassword: Bool = true, environment extra: [String: String] = [:]) {
        declined = !allowPassword
        let script = """
        set -o pipefail
        trap 'sudo -k >/dev/null 2>&1' EXIT
        if [ "$MC_PREAUTH" = 1 ]; then
          if sudo -v -p '\(Self.passwordMarker) '; then echo '\(Self.adminOK)'; else echo '\(Self.adminSkipped)'; fi
        fi
        \(command)
        """
        var env = MoleCLI.environment
        env["MC_MO"] = moPath
        env["MC_PREAUTH"] = preAuth ? "1" : "0"
        for (key, value) in extra { env[key] = value }

        let proc = StreamingProcess(
            executable: "/usr/bin/script",
            arguments: ["-q", "/dev/null", "/bin/bash", "-c", script, "moleCleaner"] + arguments,
            environment: env,
            interactive: true
        )
        proc.onLines = { [weak self] lines, tail in self?.handle(lines: lines, tail: tail) }
        proc.onExit = { [weak self] status in self?.finish(status) }
        process = proc
        do {
            try proc.start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func submitPassword(_ password: String) {
        process?.write(password + "\n")
        passwordRequest = nil
        sawSorry = false
    }

    func declinePassword() {
        declined = true
        passwordRequest = nil
        process?.write("\n")
    }

    func cancel() {
        guard isRunning else { return }
        process?.write("\u{03}")
        let proc = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { proc?.terminate() }
    }

    // MARK: - Sortie

    private func handle(lines raw: [String], tail rawTail: String) {
        if !raw.isEmpty { lastHandledTail = "" }
        for line in raw {
            let clean = ANSI.cleanLine(line)
            if clean.contains(Self.passwordMarker) || isPasswordPrompt(clean) { continue }
            if clean.contains("Sorry, try again") { sawSorry = true; continue }
            if clean == Self.adminOK { append("✓ Accès administrateur accordé"); continue }
            if clean == Self.adminSkipped { append("◎ Accès administrateur refusé, les tâches système seront ignorées"); continue }
            append(clean)
        }

        let tail = ANSI.cleanLine(rawTail)
        guard !tail.isEmpty, tail != lastHandledTail else { return }
        if tail.contains(Self.passwordMarker) || isPasswordPrompt(tail) {
            lastHandledTail = tail
            if declined {
                process?.write("\n")
            } else {
                passwordRequest = PasswordRequest(retry: sawSorry)
            }
            return
        }
        for responder in responders where tail.contains(responder.contains) {
            lastHandledTail = tail
            process?.write(responder.reply)
            append(tail)
            return
        }
    }

    private func isPasswordPrompt(_ text: String) -> Bool {
        Self.passwordRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func append(_ text: String) {
        rawLines.append(text)
        lines.append(LogLine(id: nextLineID, raw: text))
        nextLineID += 1
        if lines.count > 4000 {
            lines.removeFirst(lines.count - 4000)
        }
    }

    private func finish(_ status: Int32) {
        passwordRequest = nil
        if case .running = state { state = .finished(status) }
        onFinish?(status)
    }

    var summary: MoleSummary? { MoleParse.summary(from: rawLines) }
}
