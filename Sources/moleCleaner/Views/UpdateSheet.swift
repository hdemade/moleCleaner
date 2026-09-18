import SwiftUI

/// Feuille partagée par les quatre points d'entrée (menu de l'app, Réglages, barre latérale, popover).
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.update
        VStack(alignment: .leading, spacing: 18) {
            header(store)

            if let session = store.session {
                RunLogView(session: session)
                    .frame(minHeight: 260)
            } else {
                details(store)
            }

            HStack {
                if store.session == nil {
                    Button("Vérifier à nouveau") { Task { await store.check() } }
                        .disabled(store.isChecking)
                }
                Spacer()
                Button(store.isUpdating ? "Masquer" : "Fermer") { dismiss() }
                if store.session == nil, store.newVersion != nil {
                    Button("Mettre à jour") { store.startUpdate() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func header(_ store: UpdateStore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 52, height: 52)
                Image(systemName: symbol(store.status))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: store.isChecking || store.isUpdating)
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
