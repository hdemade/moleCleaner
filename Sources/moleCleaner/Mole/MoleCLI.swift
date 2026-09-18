import Foundation

/// Localise la CLI `mo` et prépare l'environnement d'exécution.
enum MoleCLI {
    static let candidates: [String] = [
        "/opt/homebrew/bin/mo",
        "/usr/local/bin/mo",
        NSHomeDirectory() + "/.local/bin/mo",
        NSHomeDirectory() + "/bin/mo",
    ]

    static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Dossier contenant `bin/` et `lib/` de Mole (libexec pour Homebrew).
    static func libexecDirectory(for moPath: String) -> String? {
        let real = (moPath as NSString).resolvingSymlinksInPath
        let dir = (real as NSString).deletingLastPathComponent
        let options = [
            (dir as NSString).appendingPathComponent("../libexec"),
            dir,
            (dir as NSString).appendingPathComponent(".."),
        ]
        for option in options {
            let std = (option as NSString).standardizingPath
            let probe = (std as NSString).appendingPathComponent("bin/installer.sh")
            if FileManager.default.fileExists(atPath: probe) { return std }
        }
        return nil
    }

    /// Les apps GUI héritent d'un PATH minimal : Mole a besoin de brew, bc, etc.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + current.filter { !extra.contains($0) }).joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    static let configDirectory = NSHomeDirectory() + "/.config/mole"
    static let whitelistFile = configDirectory + "/whitelist"
    static let cleanListFile = configDirectory + "/clean-list.txt"
}

/// Mole ne peut prouver qu'aucun autre exemplaire d'une app n'existe que s'il peut lister
/// tous les volumes montés. Sinon il limite la désinstallation au bundle `.app`.
/// `/Volumes/com.apple.TimeMachine.localsnapshots` existe sur tous les Mac et n'est lisible
/// qu'avec l'accès complet au disque.
enum VolumeAccess {
    static func unreadableVolumes() -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: "/Volumes") else { return [] }
        return entries
            .filter { (try? manager.contentsOfDirectory(atPath: "/Volumes/\($0)")) == nil }
            .sorted()
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
