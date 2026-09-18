import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String
}

enum ProcessRunner {
    /// Lance une commande jusqu'à sa fin et renvoie sa sortie (stdin = /dev/null).
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = MoleCLI.environment,
        includeStderr: Bool = true
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = includeStderr ? pipe : FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// Processus dont la sortie est livrée ligne par ligne sur le thread principal.
final class StreamingProcess: @unchecked Sendable {
    typealias LinesHandler = @MainActor (_ lines: [String], _ tail: String) -> Void
    typealias ExitHandler = @MainActor (_ status: Int32) -> Void

    private let process = Process()
    private let stdinPipe: Pipe?
    private let queue = DispatchQueue(label: "moleCleaner.stream")
    private var buffer = LineBuffer()
    private var reachedEOF = false
    private var exitStatus: Int32?
    private var delivered = false

    var onLines: LinesHandler?
    var onExit: ExitHandler?

    init(executable: String, arguments: [String], environment: [String: String] = MoleCLI.environment, interactive: Bool = false) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        stdinPipe = interactive ? Pipe() : nil
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.queue.async {
                    self.reachedEOF = true
                    self.deliverExitIfReady()
                }
                return
            }
            self.queue.async {
                let lines = self.buffer.append(data)
                let tail = self.buffer.tail
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onLines?(lines, tail) }
                }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                self.exitStatus = proc.terminationStatus
                self.deliverExitIfReady()
            }
            // Sécurité : si un sous-processus garde le pipe ouvert, on livre quand même.
            self.queue.asyncAfter(deadline: .now() + 2) {
                self.reachedEOF = true
                self.deliverExitIfReady()
            }
        }
        try process.run()
    }

    private func deliverExitIfReady() {
        guard reachedEOF, let status = exitStatus, !delivered else { return }
        delivered = true
        let rest = buffer.flush()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let rest { self.onLines?([rest], "") }
                self.onExit?(status)
            }
        }
    }

    func write(_ text: String) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
