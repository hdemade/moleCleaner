import Foundation

// MARK: - Status (`mo status --json` / `--watch`)
// Tous les champs sont optionnels pour résister aux évolutions du format de Mole.

struct StatusSnapshot: Decodable {
    var collected_at: String?
    var host: String?
    var uptime: String?
    var procs: Int?
    var hardware: Hardware?
    var health_score: Int?
    var health_score_msg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var trash_size: Int64?
    var disk_io: DiskIO?
    var network: [Network]?
    var batteries: [Battery]?
    var thermal: Thermal?
    var top_processes: [Proc]?

    struct Hardware: Decodable {
        var model: String?
        var cpu_model: String?
        var total_ram: String?
        var disk_size: String?
        var os_version: String?
        var isEmpty: Bool { (model ?? "").isEmpty && (cpu_model ?? "").isEmpty }
    }

    struct CPU: Decodable {
        var usage: Double?
        var per_core: [Double]?
        var load1: Double?
        var load5: Double?
        var load15: Double?
        var core_count: Int?
        var p_core_count: Int?
        var e_core_count: Int?
    }

    struct GPU: Decodable {
        var name: String?
        var usage: Double?
        var core_count: Int?
    }

    struct Memory: Decodable {
        var used: Int64?
        var total: Int64?
        var available: Int64?
        var used_percent: Double?
        var swap_used: Int64?
        var swap_total: Int64?
        var cached: Int64?
        var pressure: String?
    }

    struct Disk: Decodable, Identifiable {
        var mount: String?
        var used: Int64?
        var total: Int64?
        var used_percent: Double?
        var external: Bool?
        var purgeable: Int64?
        var id: String { mount ?? UUID().uuidString }
    }

    struct DiskIO: Decodable {
        var read_rate: Double?
        var write_rate: Double?
    }

    struct Network: Decodable {
        var name: String?
        var rx_rate_mbs: Double?
        var tx_rate_mbs: Double?
        var ip: String?
    }

    struct Battery: Decodable {
        var percent: Double?
        var status: String?
        var time_left: String?
        var health: String?
        var cycle_count: Int?
        var capacity: Double?
    }

    struct Thermal: Decodable {
        var cpu_temp: Double?
        var gpu_temp: Double?
        var battery_temp: Double?
        var fan_speed: Double?
        var system_power: Double?
        var adapter_power: Double?
    }

    struct Proc: Decodable, Identifiable {
        var pid: Int?
        var name: String?
        var command: String?
        var cpu: Double?
        var memory: Double?
        var memory_bytes: Int64?
        var id: Int { pid ?? 0 }
    }

    var rootDisk: Disk? { disks?.first { $0.mount == "/" } ?? disks?.first }
    var networkRx: Double { (network ?? []).compactMap(\.rx_rate_mbs).reduce(0, +) }
    var networkTx: Double { (network ?? []).compactMap(\.tx_rate_mbs).reduce(0, +) }
    var primaryIP: String? { network?.first { !($0.ip ?? "").isEmpty }?.ip }
}

// MARK: - Historique (`mo history --json`)

struct HistoryResponse: Decodable {
    struct Logs: Decodable {
        var operations: String?
        var deletions: String?
    }

    struct Session: Decodable, Identifiable {
        var command: String
        var started_at: String?
        var ended_at: String?
        var items: Int?
        var size: String?
        var operation_count: Int?
        var failed_tasks: Int?
        var actions: Actions?
        var id: String { "\(command)-\(started_at ?? "")" }
    }

    struct Actions: Decodable {
        var removed: Int?
        var trashed: Int?
        var skipped: Int?
        var failed: Int?
    }

    var logs: Logs?
    var sessions: [Session]
}

// MARK: - Applications (`mo uninstall --list`, JSON quand la sortie est pipée)

struct InstalledApp: Decodable, Identifiable, Hashable {
    var name: String
    var bundle_id: String
    var source: String
    var uninstall_name: String
    var path: String
    var size: String
    var id: String { path }
    var isHomebrew: Bool { source == "Homebrew" }
}

// MARK: - Fichiers à supprimer (Purge, Installeurs)

struct DiskItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let sizeText: String
    let bytes: Int64
    let source: String
    var name: String { (path as NSString).lastPathComponent }
}

enum Format {
    private static func formatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter
    }

    private static let fileFormatter = formatter(.file)
    private static let memoryFormatter = formatter(.memory)

    /// Tailles disque (base 1000, comme le Finder).
    static func bytes(_ value: Int64) -> String { fileFormatter.string(fromByteCount: value) }

    /// Quantités de mémoire (base 1024 : 16 Go de RAM s'affichent « 16 GB »).
    static func memory(_ value: Int64) -> String { memoryFormatter.string(fromByteCount: value) }

    static func rate(_ mbPerSecond: Double) -> String {
        fileFormatter.string(fromByteCount: Int64(mbPerSecond * 1_048_576)) + "/s"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f %%", value)
    }
}
