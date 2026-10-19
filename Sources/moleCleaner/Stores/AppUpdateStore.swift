import AppKit
import Foundation
import Observation

/// Vérifie les nouvelles versions de moleCleaner lui-même (et non de Mole).
///
/// Compare la version de l'app (`CFBundleShortVersionString`) à la dernière release GitHub de
/// hdemade/moleCleaner. La mise à jour télécharge le DMG de la release dans Téléchargements puis
/// l'ouvre : l'app ne se remplace pas elle-même, il reste à la glisser dans Applications.
@Observable
@MainActor
final class AppUpdateStore {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
        let notes: String
    }

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    enum Download: Equatable {
        case running(Double)
        case finished(URL)
        case failed(String)
    }

    private(set) var status: Status = .unknown
    private(set) var lastChecked: Date?
    private(set) var download: Download?
    var showSheet = false

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let releasesURL = URL(string: "https://github.com/hdemade/moleCleaner/releases/latest")!

    private static let apiURL = URL(string: "https://api.github.com/repos/hdemade/moleCleaner/releases/latest")!
    private static let checkedKey = "appUpdateLastChecked"
    private static let autoKey = "autoCheckAppUpdates"
    private static let skippedKey = "appUpdateSkippedVersion"
    private static let staleAfter: TimeInterval = 60 * 60 * 24

    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoKey) }
    }

    /// Version que l'utilisateur a choisi d'ignorer : la popup du lancement ne la propose plus.
    private(set) var skippedVersion: String?
    private var downloadTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        autoCheck = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        if let stamp = defaults.object(forKey: Self.checkedKey) as? Double {
            lastChecked = Date(timeIntervalSince1970: stamp)
        }
        skippedVersion = defaults.string(forKey: Self.skippedKey)
    }

    // MARK: - État dérivé

    var release: Release? {
        if case .available(let release) = status { release } else { nil }
    }

    var canSkipNewVersion: Bool { release.map { $0.version != skippedVersion } ?? false }
    var isChecking: Bool { status == .checking }
    var isDownloading: Bool { if case .running = download { true } else { false } }

    // MARK: - Vérification

    /// Au lancement : vérifie au plus une fois par jour et indique s'il faut ouvrir la feuille,
    /// c'est-à-dire si une version non ignorée est disponible. `AppModel` décide quand l'afficher.
    /// Contrairement à Mole, le résultat n'est pas mis en cache : en dessous d'un jour, l'app ne
    /// contacte pas GitHub du tout.
    func checkAtLaunch() async -> Bool {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.staleAfter { return false }
        await check()
        return canSkipNewVersion && !showSheet
    }

    /// Ne plus proposer cette version au lancement ; une version plus récente sera de nouveau annoncée.
    func skipNewVersion() {
        skippedVersion = release?.version
        UserDefaults.standard.set(skippedVersion, forKey: Self.skippedKey)
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking
        guard let latest = await latestRelease() else {
            status = .failed("Impossible de contacter GitHub. Vérifie ta connexion.")
            return
        }
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked?.timeIntervalSince1970, forKey: Self.checkedKey)
        status = latest.version.compare(currentVersion, options: .numeric) == .orderedDescending
            ? .available(latest) : .upToDate
    }

    private func latestRelease() async -> Release? {
        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let body: String?
            let assets: [Asset]
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            var version = payload.tag_name
            for prefix in ["v", "V"] where version.hasPrefix(prefix) { version.removeFirst() }
            guard !version.isEmpty else { return nil }
            let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            return Release(version: version, pageURL: payload.html_url, dmgURL: dmg?.browser_download_url,
                           notes: payload.body ?? "")
        } catch {
            return nil
        }
    }

    // MARK: - Téléchargement

    /// Télécharge le DMG dans Téléchargements puis l'ouvre (le Finder le monte et affiche la fenêtre
    /// d'installation). Sans DMG dans la release, ouvre simplement sa page GitHub.
    func startUpdate() {
        guard let release, !isDownloading else { return }
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        download = .running(0)
        downloadTask = Task {
            do {
                let file = try await Self.fetch(dmgURL) { fraction in
                    Task { @MainActor in
                        if case .running = self.download { self.download = .running(fraction) }
                    }
                }
                let destination = try Self.moveToDownloads(file, name: dmgURL.lastPathComponent)
                download = .finished(destination)
                NSWorkspace.shared.open(destination)
            } catch is CancellationError {
                download = nil
            } catch {
                download = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = nil
    }

    func dismissDownload() {
        if !isDownloading { download = nil }
    }

    private nonisolated static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let expected = response.expectedContentLength
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let fraction = Double(received) / Double(expected)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
        return temp
    }

    /// Place le fichier dans Téléchargements, avec « -2 », « -3 »… si le nom est déjà pris.
    private static func moveToDownloads(_ file: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appendingPathComponent(name)
        var index = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        try fm.moveItem(at: file, to: destination)
        return destination
    }
}
