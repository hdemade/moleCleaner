import SwiftUI

struct UninstallView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirming = false
    @LocalState private var blockedVolumes: [String] = []

    var body: some View {
        @Bindable var store = model.uninstall
        VStack(alignment: .leading, spacing: 14) {
            if let session = store.session {
                RunHero(session: session,
                        symbol: "trash",
                        runningTitle: "Désinstallation en cours…",
                        doneTitle: "Désinstallation terminée",
                        hint: "Les apps et leurs fichiers associés partent à la Corbeille.") { store.dismissSession() }
            } else {
                PageHeader(title: "Désinstallation",
                           subtitle: "Désinstalle des apps avec leurs préférences, caches, agents de lancement et fichiers cachés. Cocher une app affiche exactement ce que Mole supprimerait. Tout part à la Corbeille.") {
                    Button { Task { await store.load() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                        .disabled(store.loading)
                }
                if let error = store.lastError { ErrorBanner(message: error) }
                if !blockedVolumes.isEmpty { volumesNotice }
                TextField("Rechercher une application", text: $store.search)
                    .textFieldStyle(.roundedBorder)

                if store.loading {
                    ProgressView("Inventaire des applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.filteredApps) { app in
                        AppRow(app: app,
                               size: store.sizes[app.path],
                               planState: store.plans[app.path],
                               isExpanded: store.expanded.contains(app.path),
                               isSelected: Binding(
                                   get: { store.selection.contains(app.path) },
                                   set: { on in store.setSelected(app, on) }
                               ),
                               onToggleDetail: { store.toggleDetail(app) },
                               onReloadPlan: { store.reloadPlan(app) })
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    footer(store)
                }
            }
        }
        .padding(20)
        .navigationTitle("Désinstallation")
        .task {
            blockedVolumes = VolumeAccess.unreadableVolumes()
            if store.apps.isEmpty { await store.load() }
        }
        .confirmationDialog("Désinstaller \(store.selectedApps.count) application(s) ?", isPresented: $confirming) {
            Button("Désinstaller", role: .destructive) { store.uninstallSelected() }
        } message: {
            Text(store.selectedApps.map(\.name).joined(separator: ", ")
                 + "\n\nLes apps et leurs fichiers associés iront à la Corbeille. Si des fichiers système sont concernés, ton mot de passe administrateur te sera demandé.")
        }
    }

    /// Sans accès complet au disque, Mole ne peut pas écarter l'existence d'un autre exemplaire
    /// d'une app et se limite alors à son bundle, sans les fichiers annexes.
    private var volumesNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Suppression limitée au bundle des apps", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
            Text("Pour supprimer aussi les caches, préférences et journaux d'une app, Mole doit pouvoir lister tous les volumes montés afin d'écarter l'existence d'un autre exemplaire. Ces volumes lui sont refusés : \(blockedVolumes.joined(separator: ", ")).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Ouvrir les réglages de confidentialité") {
                    NSWorkspace.shared.open(VolumeAccess.privacySettingsURL)
                }
                Text("Ajoute moleCleaner à « Accès complet au disque », puis relance l'app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func footer(_ store: UninstallStore) -> some View {
        let selectedBytes = store.selectedApps.compactMap { store.sizes[$0.path] }.reduce(0, +)
        return HStack {
            Text("\(store.apps.count) applications").foregroundStyle(.secondary)
            Spacer()
            if !store.selection.isEmpty {
                Text("\(store.selection.count) sélectionnée(s) · \(Format.bytes(selectedBytes))").monospacedDigit()
                Button("Aucune") { store.clearSelection() }
            }
            Button { confirming = true } label: { Label("Désinstaller…", systemImage: "trash") }
                .buttonStyle(.borderedProminent)
                .disabled(store.selection.isEmpty || model.lock.active != nil)
        }
        .font(.callout)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?
    let planState: UninstallStore.PlanState?
    let isExpanded: Bool
    @Binding var isSelected: Bool
    let onToggleDetail: () -> Void
    let onReloadPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: $isSelected).labelsHidden()
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(app.bundle_id).font(.caption).foregroundStyle(.secondary)
                }
                if app.isHomebrew {
                    Text("Homebrew")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if case .ready(let plan) = planState {
                    Text("\(plan.entries.count) élément(s)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(size.map(Format.bytes) ?? "…").monospacedDigit().foregroundStyle(.secondary)
                Button(action: onToggleDetail) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Voir ce qui sera supprimé")
            }
            .contentShape(Rectangle())
            .onTapGesture { isSelected.toggle() }

            if isExpanded { detail.padding(.leading, 42) }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Afficher dans le Finder") { revealInFinder(app.path) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch planState {
        case .none, .some(.loading):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Analyse du plan de suppression…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        case .some(.failed(let message)):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
        case .some(.ready(let plan)):
            VStack(alignment: .leading, spacing: 7) {
                if plan.narrowed {
                    Label("Mole se limite au bundle de l'app : il n'a pas pu écarter l'existence d'un autre exemplaire installé ailleurs.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plan.groups, id: \.category) { group in
                    HStack {
                        Label(group.category.label, systemImage: group.category.symbol)
                            .font(.callout.weight(.medium))
                        Text("\(group.entries.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Spacer()
                        Text(Format.bytes(group.entries.map(\.bytes).reduce(0, +)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(group.entries) { entry in
                        HStack(spacing: 6) {
                            Text(shorten(entry.path))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if entry.kind == .system { tag("admin", .orange) }
                            if entry.kind == .reviewOnly { tag("à vérifier", .secondary) }
                            Spacer()
                            Text(entry.bytes > 0 ? Format.bytes(entry.bytes) : entry.sizeText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .padding(.leading, 20)
                        .help(entry.path)
                        .contextMenu {
                            Button("Afficher dans le Finder") { revealInFinder(entry.path) }
                        }
                    }
                }
                HStack {
                    Text("Total : \(Format.bytes(plan.totalBytes))").font(.caption).monospacedDigit()
                    Spacer()
                    Button("Réanalyser", action: onReloadPlan).font(.caption).buttonStyle(.link)
                }
                Text("Mole décide seul de la liste : elle n'est donc pas modifiable ici.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 6)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func shorten(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
