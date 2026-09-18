import SwiftUI

struct OptimizeView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirming = false
    @LocalState private var withAdmin = true

    var body: some View {
        let store = model.optimize
        VStack(alignment: .leading, spacing: 14) {
            if let session = store.session {
                RunHero(session: session,
                        symbol: "wrench.and.screwdriver",
                        runningTitle: "Optimisation en cours…",
                        doneTitle: "Optimisation terminée",
                        hint: "Mole exécute ses tâches de maintenance ; certains services redémarrent.") { store.dismissSession() }
            } else {
                PageHeader(title: "Optimisation",
                           subtitle: "Tâches de maintenance bornées : DNS, Spotlight, caches Finder et QuickLook, LaunchServices, bases de données, agents de lancement…") {
                    HStack {
                        Button { Task { await store.loadPreview() } } label: { Label("Aperçu", systemImage: "eye") }
                            .disabled(store.loadingPreview)
                        Button { confirming = true } label: { Label("Optimiser…", systemImage: "wrench.and.screwdriver") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.lock.active != nil)
                    }
                }
                if let error = store.lastError { ErrorBanner(message: error) }
                if store.loadingPreview && store.previewSections.isEmpty {
                    ProgressView("Préparation de l'aperçu…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    preview(store)
                }
            }
        }
        .padding(20)
        .navigationTitle("Optimisation")
        .task { if store.previewSections.isEmpty { await store.loadPreview() } }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Lancer l'optimisation ?", systemImage: "wrench.and.screwdriver").font(.headline)
                Text("Mole exécute ses tâches de maintenance. Certaines relancent des services (Finder, DNS…) : ferme les apps signalées dans l'aperçu pour de meilleurs résultats.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $withAdmin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avec les droits administrateur")
                        Text("Nécessaire pour la plupart des tâches système. Le mot de passe est transmis à sudo et jamais enregistré.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Annuler", role: .cancel) { confirming = false }
                    Button("Optimiser") {
                        confirming = false
                        store.run(withAdmin: withAdmin)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func preview(_ store: OptimizeStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = store.previewSummary { SummaryBox(summary: summary) }
                if !store.diagnosis.isEmpty {
                    Card(title: "Diagnostic de performance", symbol: "stethoscope") {
                        ForEach(store.diagnosis) { LogLineRow(line: $0) }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(store.previewSections) { section in
                        Card(title: section.title, symbol: "gearshape.2") {
                            ForEach(section.entries) { LogLineRow(line: $0) }
                        }
                    }
                }
            }
        }
    }
}
