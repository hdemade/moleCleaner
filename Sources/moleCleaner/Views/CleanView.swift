import SwiftUI

struct CleanView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirming = false
    @LocalState private var includeSystem = false

    var body: some View {
        let store = model.clean
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Nettoyage",
                       subtitle: "Caches, journaux, fichiers temporaires et restes d'applications détectés par mo clean. Les éléments protégés par ta liste de protection sont ignorés.") {
                if store.phase == .preview, store.preview != nil {
                    HStack {
                        Button { store.scan() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Relancer l'analyse")
                        Button { confirming = true } label: { Label("Nettoyer…", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.lock.active != nil)
                    }
                }
            }
            if let error = store.lastError { ErrorBanner(message: error) }

            switch store.phase {
            case .idle, .scanning:
                // Une seule branche pour les deux états : le bouton se transforme en anneau de progression.
                ScanHero(scanning: store.phase == .scanning,
                         section: store.currentSection,
                         freeSpace: freeSpace,
                         onScan: store.scan,
                         onCancel: store.cancelScan)
            case .preview:
                if let preview = store.preview { PreviewList(preview: preview, groups: store.fileGroups, onProtect: store.protect) }
            case .running:
                if let session = store.session {
                    RunHero(session: session,
                            symbol: "sparkles",
                            runningTitle: "Nettoyage en cours…",
                            doneTitle: "Nettoyage terminé",
                            hint: "Mole supprime les caches, journaux et fichiers temporaires de l'aperçu.") { store.reset() }
                }
            }
        }
        .padding(20)
        .navigationTitle("Nettoyage")
        .sheet(isPresented: $confirming) {
            ConfirmCleanSheet(preview: store.preview, includeSystem: $includeSystem) {
                confirming = false
                store.run(includeSystem: includeSystem)
            } onCancel: {
                confirming = false
            }
        }
    }

    private var freeSpace: String? {
        guard let disk = model.status.snapshot?.rootDisk, let total = disk.total, let used = disk.used else { return nil }
        return Format.bytes(total - used)
    }
}

/// Grand bouton rond « Analyser » ; pendant l'analyse, il devient un anneau de progression.
private struct ScanHero: View {
    let scanning: Bool
    let section: String?
    let freeSpace: String?
    let onScan: () -> Void
    let onCancel: () -> Void
    @LocalState private var hovering = false

    private let diameter: CGFloat = 176

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            ZStack {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    // ZStack explicite : sans lui, les deux cercles s'empilent verticalement.
                    ZStack {
                        if scanning {
                            Circle()
                                .stroke(.quaternary, lineWidth: 5)
                                .frame(width: diameter + 34, height: diameter + 34)
                            Circle()
                                .trim(from: 0, to: 0.3)
                                .stroke(Brand.angular, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .frame(width: diameter + 34, height: diameter + 34)
                                .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                        } else {
                            // Halo qui s'élargit et s'estompe en boucle.
                            let phase = time.truncatingRemainder(dividingBy: 2.4) / 2.4
                            Circle()
                                .fill(Brand.gradient)
                                .frame(width: diameter, height: diameter)
                                .scaleEffect(1 + 0.32 * phase)
                                .opacity(0.35 * (1 - phase))
                        }
                    }
                }

                Button(action: onScan) {
                    ZStack {
                        Circle()
                            .fill(Brand.gradient)
                            .shadow(color: Brand.teal.opacity(hovering ? 0.55 : 0.35), radius: hovering ? 26 : 16, y: 8)
                        Circle()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        VStack(spacing: 8) {
                            Image(systemName: scanning ? "sparkle.magnifyingglass" : "sparkles")
                                .font(.system(size: 46, weight: .semibold))
                                .symbolEffect(.pulse, isActive: scanning)
                            Text(scanning ? "Analyse…" : "Analyser")
                                .font(.title3.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                    }
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(scanning)
                .scaleEffect(hovering && !scanning ? 1.04 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hovering)
                .onHover { hovering = $0 }
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: diameter + 80, height: diameter + 80)

            VStack(spacing: 6) {
                Text(scanning ? (section.map { "Analyse : \($0)" } ?? "Démarrage de l'analyse…") : "Prêt à analyser ton Mac")
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: section)
                Text(scanning ? "Environ 30 à 60 secondes" : "Aperçu sans risque : rien n'est supprimé avant ta confirmation.")
                    .foregroundStyle(.secondary)
                if !scanning, let freeSpace {
                    Label("\(freeSpace) libres actuellement", systemImage: "internaldrive")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)

            if scanning {
                Button("Annuler", action: onCancel)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct PreviewList: View {
    let preview: CleanPreview
    let groups: [CleanListGroup]
    let onProtect: (String) -> Void

    var body: some View {
        let active = preview.categories.filter { !$0.isEmpty }
        let empty = preview.categories.filter(\.isEmpty)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 24) {
                    metric("Espace récupérable", preview.potentialText ?? "—", big: true)
                    if let count = preview.itemCount { metric("Éléments", "\(count)") }
                    if let free = preview.freeSpace { metric("Espace libre actuel", free) }
                    Spacer()
                }
                if !preview.systemIncluded {
                    Label("Aperçu limité à ton compte : les caches système nécessitent les droits administrateur (option proposée au moment du nettoyage).",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(active) { category in
                    Card(title: category.title, symbol: "folder") {
                        ForEach(category.entries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                if let symbol = entry.kind.symbol {
                                    Image(systemName: symbol).foregroundStyle(entry.kind.tint).font(.caption)
                                }
                                Text(entry.label)
                                Spacer()
                                Text(entry.detail).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }

                if !empty.isEmpty {
                    Label("Rien à nettoyer : " + empty.map(\.title).joined(separator: ", "), systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !groups.isEmpty {
                    Card(title: "Détail des chemins", symbol: "list.bullet.indent") {
                        Text("Clic droit sur un chemin pour l'afficher dans le Finder ou le protéger définitivement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(groups) { group in
                            DisclosureGroup("\(group.title) (\(group.paths.count))") {
                                ForEach(group.paths) { entry in
                                    HStack {
                                        Text(entry.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(entry.size).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contextMenu {
                                        Button("Afficher dans le Finder") { revealInFinder(MoleParse.expandTilde(entry.path)) }
                                        Button("Protéger (ne plus nettoyer)") { onProtect(entry.path) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(big ? .system(size: 28, weight: .semibold, design: .rounded) : .title3).monospacedDigit()
        }
    }
}

private struct ConfirmCleanSheet: View {
    let preview: CleanPreview?
    @Binding var includeSystem: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Lancer le nettoyage ?", systemImage: "sparkles").font(.headline)
            Text("Mole va supprimer les éléments de l'aperçu\(preview?.potentialText.map { " (environ \($0))" } ?? ""). Ce sont des caches et journaux régénérables, mais la suppression est définitive : ils ne passent pas par la Corbeille.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $includeSystem) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inclure les caches système")
                    Text("Demande ton mot de passe administrateur, transmis à sudo et jamais enregistré.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: onCancel)
                Button("Nettoyer", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
