import SwiftUI

/// Feuille de mise à jour de moleCleaner lui-même, ouverte au lancement quand une nouvelle release
/// GitHub est disponible, ou depuis le menu de l'app, les Réglages et la barre de menus.
struct AppUpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.appUpdate
        VStack(alignment: .leading, spacing: 18) {
            header(store)

            if let download = store.download {
                DownloadProgressView(download: download)
            } else {
                details(store)
            }

            HStack {
                if store.download == nil, store.canSkipNewVersion {
                    Button("Ignorer cette version") {
                        store.skipNewVersion()
                        dismiss()
                    }
                }
                Spacer()
                switch store.download {
                case .running:
                    Button("Annuler") { store.cancelDownload() }
                case .finished(let file):
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button("Fermer") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Ouvrir la page GitHub") { NSWorkspace.shared.open(store.release?.pageURL ?? AppUpdateStore.releasesURL) }
                    Button("Réessayer") { store.startUpdate() }
                    Button("Fermer") { dismiss() }
                case nil:
                    Button(store.release != nil ? "Plus tard" : "Fermer") { dismiss() }
                    if let release = store.release {
                        Button(release.dmgURL != nil ? "Télécharger" : "Ouvrir la page GitHub") { store.startUpdate() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .onDisappear { store.dismissDownload() }
    }

    private func header(_ store: AppUpdateStore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mise à jour de moleCleaner").font(.title3.weight(.semibold))
                Text(headline(store))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func details(_ store: AppUpdateStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            row("Version installée", store.currentVersion)
            if let release = store.release {
                row("Dernière version", release.version)
            }
            row("Dernière vérification", store.lastChecked.map(relative) ?? "jamais")
            if case .failed(let message) = store.status {
                Divider()
                ErrorBanner(message: message)
            }
            if let release = store.release, !release.notes.isEmpty {
                Divider()
                ScrollView {
                    Text(Self.notes(release.notes))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Divider()
            Link("Voir la release sur GitHub", destination: store.release?.pageURL ?? AppUpdateStore.releasesURL)
                .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func headline(_ store: AppUpdateStore) -> String {
        switch store.download {
        case .running: return "Téléchargement en cours…"
        case .finished: return "Le DMG est ouvert : glisse moleCleaner dans Applications, puis relance l'app."
        case .failed: return "Le téléchargement n'a pas abouti."
        case nil: break
        }
        switch store.status {
        case .checking: return "Vérification en cours…"
        case .upToDate: return "moleCleaner est à jour en version \(store.currentVersion)."
        case .available(let release): return "La version \(release.version) est disponible."
        case .failed: return "La vérification a échoué."
        case .unknown: return "Aucune vérification depuis le lancement."
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Le Markdown des releases GitHub, simplifié pour `Text` : titres en gras, puces, sans
    /// délimiteurs de blocs de code. Le reste (gras, code en ligne, liens) est rendu tel quel.
    private static func notes(_ markdown: String) -> AttributedString {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("```") }
            .map { line -> String in
                if line.hasPrefix("#") {
                    let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    return title.isEmpty ? "" : "**\(title)**"
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { return "•  " + line.dropFirst(2) }
                return line
            }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Avancement du téléchargement du DMG, puis message de fin.
private struct DownloadProgressView: View {
    let download: AppUpdateStore.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            switch download {
            case .running(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Brand.teal)
                        .animation(.easeOut(duration: 0.2), value: fraction)
                    HStack {
                        Text("Téléchargement du DMG…")
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            case .finished(let file):
                outcome(symbol: "checkmark.circle.fill", tint: .green, title: "DMG téléchargé",
                        detail: "\(file.lastPathComponent) est dans Téléchargements. Quitte moleCleaner avant de remplacer l'app dans Applications.")
            case .failed(let message):
                outcome(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: "Le téléchargement a échoué", detail: message)
            }
            Divider()
        }
    }

    private func outcome(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: title)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
