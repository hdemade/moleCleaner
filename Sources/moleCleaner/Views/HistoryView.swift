import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        let store = model.history
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Historique", subtitle: "Sessions enregistrées par Mole (mo history). Les mises à la Corbeille faites depuis Projets et Installeurs n'y figurent pas.") {
                HStack {
                    if let path = store.logs?.operations {
                        Button("Journal des opérations") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    if let path = store.logs?.deletions {
                        Button("Journal des suppressions") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    Button { Task { await store.load() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                }
            }
            if let error = store.lastError { ErrorBanner(message: error) }
            if store.sessions.isEmpty && !store.loading {
                ContentUnavailableView("Aucune session", systemImage: "clock", description: Text("Lance un nettoyage ou une optimisation pour remplir l'historique."))
            } else {
                Table(store.sessions) {
                    TableColumn("Commande") { session in
                        Label(commandTitle(session.command), systemImage: commandSymbol(session.command))
                    }
                    TableColumn("Date") { session in Text(dateText(session.started_at)) }
                    TableColumn("Durée") { session in Text(duration(session)).monospacedDigit() }
                        .width(70)
                    TableColumn("Éléments") { session in Text("\(session.items ?? 0)").monospacedDigit() }
                        .width(70)
                    TableColumn("Taille") { session in Text(session.size ?? "—").monospacedDigit() }
                        .width(80)
                    TableColumn("Supprimés / Corbeille / Ignorés") { session in
                        let actions = session.actions
                        Text("\(actions?.removed ?? 0) / \(actions?.trashed ?? 0) / \(actions?.skipped ?? 0)").monospacedDigit()
                    }
                    TableColumn("Échecs") { session in
                        let failed = (session.actions?.failed ?? 0) + (session.failed_tasks ?? 0)
                        Text("\(failed)").monospacedDigit().foregroundStyle(failed > 0 ? .orange : .secondary)
                    }
                    .width(60)
                }
            }
        }
        .padding(20)
        .navigationTitle("Historique")
        .task { await store.load() }
    }

    private func commandTitle(_ command: String) -> String {
        switch command {
        case "clean": "Nettoyage"
        case "optimize": "Optimisation"
        case "uninstall": "Désinstallation"
        case "purge": "Projets"
        case "installer": "Installeurs"
        default: command
        }
    }

    private func commandSymbol(_ command: String) -> String {
        switch command {
        case "clean": Page.clean.symbol
        case "optimize": Page.optimize.symbol
        case "uninstall": Page.uninstall.symbol
        case "purge": Page.purge.symbol
        case "installer": Page.installers.symbol
        default: "terminal"
        }
    }

    private func dateText(_ raw: String?) -> String {
        guard let raw, let date = Self.parser.date(from: raw) else { return raw ?? "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func duration(_ session: HistoryResponse.Session) -> String {
        guard let start = session.started_at.flatMap(Self.parser.date(from:)),
              let end = session.ended_at.flatMap(Self.parser.date(from:)) else { return "—" }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }
}
