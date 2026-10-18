import SwiftUI

/// Feuille partagée par les quatre points d'entrée (menu de l'app, Réglages, barre latérale, popover),
/// ouverte aussi automatiquement au lancement quand une nouvelle version est disponible.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.update
        VStack(alignment: .leading, spacing: 18) {
            header(store)

            if let session = store.session {
                UpdateProgressView(session: session, version: store.currentVersion)
            } else {
                details(store)
            }

            HStack {
                if store.session == nil {
                    Button("Vérifier à nouveau") { Task { await store.check() } }
                        .disabled(store.isChecking)
                }
                Spacer()
                if store.session == nil, store.canSkipNewVersion {
                    Button("Ignorer cette version") {
                        store.skipNewVersion()
                        dismiss()
                    }
                }
                if let session = store.session, !session.isRunning {
                    if session.state != .finished(0) {
                        Button("Réessayer") { store.startUpdate() }
                    }
                    Button("Fermer") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(store.isUpdating ? "Masquer" : (store.newVersion != nil ? "Plus tard" : "Fermer")) { dismiss() }
                }
                if store.session == nil, store.newVersion != nil {
                    Button("Mettre à jour") { store.startUpdate() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .onDisappear {
            // Une mise à jour terminée ne se réaffiche pas : la prochaine ouverture repart sur les détails.
            if let session = store.session, !session.isRunning { store.dismissSession() }
        }
    }

    private func header(_ store: UpdateStore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 52, height: 52)
                Image(systemName: symbol(store.status))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: store.isChecking || store.isUpdating)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Mise à jour de Mole").font(.title3.weight(.semibold))
                Text(headline(store))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func details(_ store: UpdateStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            row("Version installée", store.currentVersion ?? "inconnue")
            if let version = store.newVersion {
                row("Dernière version", version)
            }
            row("Installé via", store.installMethod.label)
            row("Dernière vérification", store.lastChecked.map(relative) ?? "jamais")
            if case .failed(let message) = store.status {
                Divider()
                ErrorBanner(message: message)
            }
            if case .pendingHomebrew = store.status {
                Divider()
                Label("« Mettre à jour » lance d'abord brew update pour récupérer la nouvelle formule, puis brew upgrade mole. Si elle n'est pas encore publiée, Mole restera sur la version actuelle.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Link("Voir les nouveautés sur GitHub", destination: store.releaseNotesURL)
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

    private func symbol(_ status: UpdateStore.Status) -> String {
        switch status {
        case .checking: "arrow.triangle.2.circlepath"
        case .upToDate: "checkmark"
        case .available, .pendingHomebrew: "arrow.down"
        case .failed: "exclamationmark.triangle"
        case .unknown: "arrow.triangle.2.circlepath"
        }
    }

    private func headline(_ store: UpdateStore) -> String {
        if store.isUpdating { return "Installation en cours…" }
        if let session = store.session {
            return session.state == .finished(0) ? "Mise à jour terminée." : "La mise à jour n'a pas abouti."
        }
        switch store.status {
        case .checking:
            return "Vérification en cours…"
        case .upToDate:
            return "Mole est à jour" + (store.currentVersion.map { " en version \($0)." } ?? ".")
        case .available(let version):
            return "La version \(version) est disponible."
        case .pendingHomebrew(let version):
            return "La version \(version) est publiée sur GitHub, mais pas encore disponible dans ta formule Homebrew."
        case .failed:
            return "La vérification a échoué."
        case .unknown:
            return "Aucune vérification depuis le lancement."
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Avancement de `mo update` sans le détail des commandes : une barre de progression pendant
/// l'installation, puis un message de fin.
///
/// `mo update` n'annonce pas de pourcentage, seulement ses étapes (« Updating Homebrew... »,
/// « Downloading latest version... », « Installing update... »). Chaque étape couvre une plage
/// de la barre, qui avance doucement vers sa borne tant que l'étape suivante n'est pas arrivée.
struct UpdateProgressView: View {
    @Bindable var session: TerminalSession
    let version: String?
    @LocalState private var stepStarted = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            switch session.state {
            case .running:
                running
            case .finished(0):
                outcome(symbol: "checkmark.circle.fill", tint: .green,
                        title: Self.alreadyLatest(session.rawLines) ? "Mole était déjà à jour" : "Mise à jour terminée",
                        detail: (Self.installedVersion(session.rawLines) ?? version).map { "Mole est maintenant en version \($0)." })
            case .finished:
                outcome(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: "La mise à jour a échoué", detail: Self.errorLine(session.rawLines))
            case .failed(let message):
                outcome(symbol: "xmark.octagon.fill", tint: .red,
                        title: "La mise à jour n'a pas pu démarrer", detail: message)
            }
            Divider()
        }
        .sheet(item: $session.passwordRequest) { request in
            PasswordSheet(retry: request.retry, onSubmit: session.submitPassword, onCancel: session.declinePassword)
        }
    }

    private var running: some View {
        let step = Self.step(for: session.rawLines)
        return TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let elapsed = context.date.timeIntervalSince(stepStarted)
            let fraction = step.start + (step.end - step.start) * (1 - exp(-elapsed / 10))
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Brand.teal)
                    .animation(.easeOut(duration: 0.2), value: fraction)
                HStack {
                    Text(step.label)
                    Spacer()
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: step.label) { stepStarted = Date() }
    }

    private func outcome(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: title)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Lecture de la sortie de `mo update`

    private struct Step {
        let label: String
        let start: Double
        let end: Double
    }

    private static let steps: [(markers: [String], step: Step)] = [
        (["Upgrading Mole", "Installing", "Repairing", "Switching to stable"],
         Step(label: "Installation de la nouvelle version…", start: 0.55, end: 0.95)),
        (["Downloading"], Step(label: "Téléchargement…", start: 0.25, end: 0.55)),
        (["Updating Homebrew"], Step(label: "Mise à jour de Homebrew…", start: 0.05, end: 0.55)),
        (["Checking for updates"], Step(label: "Recherche de la dernière version…", start: 0.05, end: 0.25)),
    ]

    private static func step(for lines: [String]) -> Step {
        for line in lines.reversed() {
            if let match = steps.first(where: { $0.markers.contains(where: line.contains) }) { return match.step }
        }
        return Step(label: "Préparation…", start: 0, end: 0.05)
    }

    /// « ✓ Updated to latest version, 1.60.0 » → « 1.60.0 ».
    private static func installedVersion(_ lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.contains("Updated to") || $0.contains("Already on latest") }),
              let comma = line.lastIndex(of: ",") else { return nil }
        let version = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return version.isEmpty || version == "unknown" ? nil : version
    }

    private static func alreadyLatest(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("Already on latest") }
    }

    private static func errorLine(_ lines: [String]) -> String? {
        let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return meaningful.last { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("failed") }
            ?? meaningful.last
    }
}
