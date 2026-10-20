import SwiftUI

/// Page « Doublons » : fichiers au contenu identique, dans le dossier personnel ou un dossier choisi.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirming = false

    private static let minSizes: [(Int64, String)] = [
        (100_000, "100 Ko"), (1_000_000, "1 Mo"), (10_000_000, "10 Mo"), (100_000_000, "100 Mo"),
    ]

    var body: some View {
        @Bindable var store = model.duplicates
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Doublons",
                       subtitle: "Fichiers dont le contenu est identique octet pour octet, quel que soit leur nom. Rien n'est supprimé sans ta confirmation, et les copies partent à la Corbeille.") {
                EmptyView()
            }
            controls(store)
            if let error = store.lastError { ErrorBanner(message: error) }
            if let report = store.report { reportView(report) }

            switch store.phase {
            case .idle:
                ContentUnavailableView("Cherche des fichiers en double", systemImage: "doc.on.doc",
                                       description: Text("Choisis où chercher, puis lance la recherche. Sont ignorés : les fichiers iCloud non téléchargés, les fichiers cachés, le contenu des paquets (apps, photothèques) et les dossiers de dépendances (node_modules, Pods, DerivedData…)."))
            case .scanning:
                progressView(store.progress)
            case .ready, .trashing:
                if store.groups.isEmpty {
                    ContentUnavailableView("Aucun doublon", systemImage: "checkmark.circle",
                                           description: Text("Aucun fichier identique de plus de \(minSizeLabel(store.minSize)) dans \(store.scannedLabel ?? "ce dossier")."))
                } else {
                    results(store)
                    footer(store)
                }
            }
        }
        .padding(20)
        .navigationTitle("Doublons")
        .confirmationDialog("Mettre \(store.selection.count) copie(s) à la Corbeille ?", isPresented: $confirming) {
            Button("Mettre à la Corbeille (\(Format.bytes(store.selectedBytes)))", role: .destructive) {
                Task { await store.trashSelected() }
            }
        } message: {
            Text("Un exemplaire de chaque fichier est conservé. Les copies restent récupérables depuis la Corbeille tant que tu ne la vides pas.")
        }
    }

    // MARK: - Choix de la recherche

    private func controls(_ store: DuplicatesStore) -> some View {
        @Bindable var store = store
        let busy = store.phase == .scanning || store.phase == .trashing
        return HStack(spacing: 10) {
            Picker("Où chercher", selection: $store.scope) {
                Text("Recherche globale").tag(DuplicatesStore.Scope.home)
                Text("Dossier choisi").tag(DuplicatesStore.Scope.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(busy)

            if store.scope == .home {
                Label("Dossier personnel, hors Bibliothèque", systemImage: "house")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("La Bibliothèque contient les données internes des apps : y supprimer un doublon pourrait les casser.")
            } else {
                Button { store.pickFolder() } label: {
                    Label(store.folder.map { AnalyzeView.shortPath($0.path) } ?? "Choisir un dossier…", systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .disabled(busy)
                .help(store.folder?.path ?? "Choisir le dossier à analyser")
            }

            Spacer(minLength: 8)

            Picker("Taille minimale", selection: $store.minSize) {
                ForEach(Self.minSizes, id: \.0) { Text("≥ \($0.1)").tag($0.0) }
            }
            .fixedSize()
            .disabled(busy)
            .help("Les petits fichiers sont ignorés : ils libèrent peu de place et sont souvent voulus en double.")

            if store.phase == .scanning {
                Button("Arrêter") { store.cancel() }
            } else {
                Button {
                    if store.scope == .folder && store.folder == nil { store.pickFolder() }
                    if store.canStart { store.start() }
                } label: {
                    Label("Rechercher", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.phase == .trashing)
            }
        }
    }

    private func progressView(_ progress: DuplicateScanner.Progress?) -> some View {
        VStack(spacing: 10) {
            if let progress, let fraction = progress.fraction {
                ProgressView(value: fraction).frame(maxWidth: 360)
            } else {
                ProgressView()
            }
            Text(progressText(progress)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressText(_ progress: DuplicateScanner.Progress?) -> String {
        guard let progress else { return "Préparation…" }
        switch progress.phase {
        case .listing:
            return "Inventaire des fichiers : \(progress.filesSeen.formatted()) trouvés…"
        case .quickCompare:
            return "Comparaison rapide de \(progress.total.formatted()) fichiers de même taille…"
        case .fullCompare:
            return "Vérification du contenu : \(Format.bytes(progress.done)) sur \(Format.bytes(progress.total))"
        }
    }

    // MARK: - Résultats

    private func results(_ store: DuplicatesStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(store.groups.count) groupe(s) de fichiers identiques · \(Format.bytes(store.totalWasted)) récupérables · \(store.scannedLabel ?? "")")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.groups) { group in groupView(group, store: store) }
                }
                .padding(.trailing, 8)
            }
        }
    }

    private func groupView(_ group: DuplicateGroup, store: DuplicatesStore) -> some View {
        let allSelected = group.files.allSatisfy { store.selection.contains($0.path) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].path)).resizable().frame(width: 22, height: 22)
                Text(group.files[0].name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(group.files.count) × \(Format.bytes(group.size))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if allSelected {
                    Label("Tous les exemplaires sont cochés", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("\(Format.bytes(group.wasted)) en trop").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                fileRow(file, isOldest: index == 0, store: store)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    private func fileRow(_ file: DuplicateFile, isOldest: Bool, store: DuplicatesStore) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { store.selection.contains(file.path) },
                set: { on in
                    if on { store.selection.insert(file.path) } else { store.selection.remove(file.path) }
                }
            ))
            .labelsHidden()
            .disabled(store.phase == .trashing)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(AnalyzeView.shortPath((file.path as NSString).deletingLastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(file.path)
            Spacer(minLength: 8)
            if isOldest {
                Text("le plus ancien").font(.caption).foregroundStyle(.secondary)
            }
            Text(file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { revealInFinder(file.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Afficher dans le Finder")
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 6, expand: EdgeInsets())
        .contextMenu {
            Button("Afficher dans le Finder") { revealInFinder(file.path) }
            Button("Ouvrir") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
        }
    }

    private func footer(_ store: DuplicatesStore) -> some View {
        HStack {
            Button("Cocher les copies") { store.selectCopies() }
                .help("Coche tout sauf le fichier le plus ancien de chaque groupe")
            Button("Aucun") { store.selection = [] }
            Spacer()
            if store.phase == .trashing { ProgressView().controlSize(.small) }
            if store.fullySelectedGroups > 0 {
                Text("Garde au moins un exemplaire par groupe")
                    .foregroundStyle(.orange)
            } else {
                Text("\(store.selection.count) sélectionné(s) · \(Format.bytes(store.selectedBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { confirming = true } label: { Label("Mettre à la Corbeille", systemImage: "trash") }
                .buttonStyle(.borderedProminent)
                .disabled(store.selection.isEmpty || store.fullySelectedGroups > 0 || store.phase != .ready
                          || model.lock.active != nil)
        }
        .font(.callout)
    }

    private func reportView(_ report: DuplicatesStore.TrashReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(report.count) copie(s) mise(s) à la Corbeille, \(Format.bytes(report.bytes)) récupérables en la vidant.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            ForEach(report.failures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private func minSizeLabel(_ size: Int64) -> String {
        Self.minSizes.first { $0.0 == size }?.1 ?? Format.bytes(size)
    }
}
