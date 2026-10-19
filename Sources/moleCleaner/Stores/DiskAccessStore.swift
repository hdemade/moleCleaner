import AppKit
import Foundation
import Observation

/// Suit l'accès complet au disque, dont certaines commandes de Mole ont besoin pour lire les
/// dossiers protégés par macOS (caches et journaux système, données des autres apps).
///
/// macOS n'expose pas d'API pour connaître ce réglage : on tente d'ouvrir un fichier qu'il protège.
/// Un refus (EPERM) signifie que l'accès n'est pas accordé.
@Observable
@MainActor
final class DiskAccessStore {
    /// `nil` quand aucun fichier témoin n'existe : on ne sait pas, donc on ne réclame rien.
    private(set) var hasFullAccess: Bool?
    var showSheet = false

    private static let promptKey = "promptFullDiskAccess"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Faux après « Refuser » : la popup ne s'affiche plus au lancement. Modifiable dans les Réglages.
    var promptAtLaunch: Bool {
        didSet { UserDefaults.standard.set(promptAtLaunch, forKey: Self.promptKey) }
    }

    init() {
        promptAtLaunch = UserDefaults.standard.object(forKey: Self.promptKey) as? Bool ?? true
        refresh()
    }

    var shouldPromptAtLaunch: Bool { promptAtLaunch && hasFullAccess == false }

    func refresh() {
        hasFullAccess = Self.probe()
    }

    func decline() {
        promptAtLaunch = false
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private static func probe() -> Bool? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let witnesses = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
        ]
        for path in witnesses {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return nil
    }
}
