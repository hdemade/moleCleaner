import SwiftUI

/// Page commune à « Projets » (mo purge) et « Installeurs » (mo installer).
struct DiskItemsView: View {
    @Bindable var store: DiskItemStore
    @Environment(AppModel.self) private var model
    @LocalState private var confirming = false
    @LocalState private var sortOrder = [KeyPathComparator(\DiskItem.bytes, order: .reverse)]

    private var title: String { store.kind == .purge ? "Projets" : "Installeurs" }
    private var subtitle: String {
        store.kind == .purge
            ? "Artefacts de build régénérables (node_modules, target, .build, dist…) détectés par mo purge. Les projets modifiés récemment sont exclus par Mole."
            : "Fichiers d'installation (.dmg, .pkg, .iso, .xip, .zip) trouvés par Mole dans Téléchargements, Bureau, caches Homebrew et messageries."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: title, subtitle: subtitle) {
                HStack {
                    Button { Task { await store.scan() } } label: { Label("Analyser", systemImage: "arrow.clockwise") }
                        .disabled(store.phase == .scanning || store.phase == .trashing)
                    Button { confirming = true } label: {
                        Label("Mettre à la Corbeille", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.selection.isEmpty || store.phase != .ready || model.lock.active != nil)
                }
            }
            if let error = store.lastError { ErrorBanner(message: error) }
            if let report = store.report { reportView(report) }

            switch store.phase {
            case .idle:
                ProgressView("Analyse par Mole…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning where store.items.isEmpty:
                ProgressView("Analyse par Mole…").frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if store.items.isEmpty {
                    ContentUnavailableView("Rien à supprimer", systemImage: "checkmark.circle",
                                           description: Text(store.kind == .purge ? "Aucun artefact de projet ancien trouvé." : "Aucun fichier d'installation trouvé."))
                } else {
                    table
                    footer
                }
            }
        }
        .padding(20)
        .navigationTitle(title)
        .task { if store.phase == .idle { await store.scan() } }
        .confirmationDialog("Mettre \(store.selection.count) élément(s) à la Corbeille ?", isPresented: $confirming) {
            Button("Mettre à la Corbeille (\(Format.bytes(store.selectedBytes)))", role: .destructive) {
                Task { await store.trashSelected() }
            }
        } message: {
            Text("Les éléments restent récupérables depuis la Corbeille tant que tu ne la vides pas.")
        }
    }

    private var table: some View {
        Table(store.items.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { store.selection.contains(item.path) },
                    set: { on in
                        if on { store.selection.insert(item.path) } else { store.selection.remove(item.path) }
                    }
                ))
                .labelsHidden()
            }
            .width(24)
            TableColumn("Nom", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1)
                }
            }
            TableColumn(store.kind == .purge ? "Projet" : "Source", value: \.source)
                .width(min: 90, ideal: 140)
            TableColumn("Emplacement", value: \.path) { item in
                Text((item.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
            }
            TableColumn("Taille", value: \.bytes) { item in
                Text(item.sizeText).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
            paths.forEach(revealInFinder)
        }
    }

    private var footer: some View {
        HStack {
            Button("Tout sélectionner") { store.selection = Set(store.items.map(\.path)) }
            Button("Aucun") { store.selection = [] }
            Spacer()
            if store.phase == .trashing { ProgressView().controlSize(.small) }
            Text("\(store.selection.count) sélectionné(s) · \(Format.bytes(store.selectedBytes)) sur \(Format.bytes(store.totalBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func reportView(_ report: DiskItemStore.TrashReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(report.count) élément(s) mis à la Corbeille, \(Format.bytes(report.bytes)) récupérables en la vidant.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            ForEach(report.failures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }
}
