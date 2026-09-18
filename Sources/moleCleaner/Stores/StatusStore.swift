import Foundation
import Observation

struct Sample: Identifiable, Hashable {
    let id: Int
    let value: Double
}

/// Flux continu `mo status --watch` (une ligne JSON par relevé), partagé par la fenêtre et la barre de menus.
@Observable
@MainActor
final class StatusStore {
    private(set) var snapshot: StatusSnapshot?
    private(set) var hardware: StatusSnapshot.Hardware?
    private(set) var cpuHistory: [Sample] = []
    private(set) var memoryHistory: [Sample] = []
    private(set) var rxHistory: [Sample] = []
    private(set) var txHistory: [Sample] = []
    private(set) var lastError: String?

    var interval: Int {
        didSet {
            UserDefaults.standard.set(interval, forKey: "statusInterval")
            restart()
        }
    }

    private let moPath: String
    private var process: StreamingProcess?
    private var counter = 0
    private var stopped = false
    private let historyLength = 90
    private let decoder = JSONDecoder()

    init(moPath: String) {
        self.moPath = moPath
        let stored = UserDefaults.standard.integer(forKey: "statusInterval")
        interval = stored > 0 ? stored : 2
    }

    func start() {
        guard process == nil else { return }
        stopped = false
        let proc = StreamingProcess(executable: moPath, arguments: ["status", "--watch", "--interval", "\(interval)s"])
        proc.onLines = { [weak self] lines, _ in
            for line in lines { self?.ingest(line) }
        }
        proc.onExit = { [weak self] status in
            guard let self else { return }
            self.process = nil
            guard !self.stopped else { return }
            self.lastError = "Le collecteur Mole s'est arrêté (code \(status)), redémarrage…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
        process = proc
        do {
            try proc.start()
        } catch {
            lastError = error.localizedDescription
            process = nil
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
    }

    private func ingest(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let snap = try? decoder.decode(StatusSnapshot.self, from: data) else { return }
        snapshot = snap
        lastError = nil
        if let hw = snap.hardware, !hw.isEmpty { hardware = hw }
        counter += 1
        push(&cpuHistory, snap.cpu?.usage ?? 0)
        push(&memoryHistory, snap.memory?.used_percent ?? 0)
        push(&rxHistory, snap.networkRx)
        push(&txHistory, snap.networkTx)
    }

    private func push(_ series: inout [Sample], _ value: Double) {
        series.append(Sample(id: counter, value: value))
        if series.count > historyLength { series.removeFirst(series.count - historyLength) }
    }
}

@Observable
@MainActor
final class HistoryStore {
    private(set) var sessions: [HistoryResponse.Session] = []
    private(set) var logs: HistoryResponse.Logs?
    private(set) var loading = false
    private(set) var lastError: String?
    private let moPath: String

    init(moPath: String) { self.moPath = moPath }

    func load() async {
        loading = true
        defer { loading = false }
        let result = await ProcessRunner.run(moPath, ["history", "--json"], includeStderr: false)
        guard let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8) else {
            lastError = "Sortie inattendue de mo history"
            return
        }
        do {
            let response = try JSONDecoder().decode(HistoryResponse.self, from: data)
            sessions = response.sessions
            logs = response.logs
            lastError = nil
        } catch {
            lastError = "Impossible de lire l'historique : \(error.localizedDescription)"
        }
    }
}
