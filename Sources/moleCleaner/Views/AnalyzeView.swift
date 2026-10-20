import Charts
import SwiftUI

/// Une part du graphique et une ligne de la liste.
struct AnalyzeSlice: Identifiable, Hashable {
    let id: String
    let name: String
    var detail: String?
    /// Chemin réel, `nil` pour les parts calculées (système, espace libre, autres éléments).
    var path: String?
    let bytes: Int64
    var isDirectory = false
    var color: Color
    /// Retrait dans la liste, pour un emplacement compris dans le précédent.
    var indent = 0
    /// Taille encore estimée : l'analyse détaillée est en cours.
    var pending = false
    var modified: Date?

    var canOpen: Bool { isDirectory && path != nil }
}

/// Ordre de la liste. Le graphique reste toujours rangé par taille, pour garder ses couleurs.
enum AnalyzeSort: String, CaseIterable, Identifiable {
    case name, size, date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Nom"
        case .size: "Taille"
        case .date: "Date"
        }
    }

    /// Sens le plus utile quand on choisit ce critère : A→Z, les plus gros, les plus récents.
    var defaultAscending: Bool { self == .name }

    func areInOrder(name a: String, _ b: String, bytes x: Int64, _ y: Int64, date d1: Date?, _ d2: Date?,
                    ascending: Bool) -> Bool {
        switch self {
        case .name:
            let result = a.localizedStandardCompare(b)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        case .size:
            return ascending ? x < y : x > y
        case .date:
            // Les éléments sans date (introuvables) vont toujours à la fin.
            guard let d1 else { return false }
            guard let d2 else { return true }
            return ascending ? d1 < d2 : d1 > d2
        }
    }
}

/// Page « Analyse » : répartition de l'espace disque calculée par `mo analyze`.
struct AnalyzeView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var highlighted: String?
    @LocalState private var selectedAngle: Double?
    @AppStorage("analyzeSort") private var sort: AnalyzeSort = .size
    @AppStorage("analyzeSortAscending") private var ascending = false

    private static let palette: [Color] = [Brand.teal, Brand.blue, .orange, .purple, .pink, .yellow, .mint, .indigo, .red, .cyan]
    private static let otherColor = Color.gray.opacity(0.55)
    private static let freeColor = Color.gray.opacity(0.18)
    /// Nombre de parts nommées dans le graphique d'un dossier ; le reste est regroupé.
    private static let maxSlices = 9

    var body: some View {
        let store = model.analyze
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Analyse",
                       subtitle: "Répartition de l'espace disque calculée par mo analyze. Clique sur un dossier pour voir ce qu'il contient.") {
                HStack {
                    Button { store.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                        .disabled(store.isLoading)
                    if let path = store.path {
                        Button { revealInFinder(path) } label: { Label("Finder", systemImage: "folder") }
                    }
                }
            }
            navigationBar(store)
            if let error = store.lastError { ErrorBanner(message: error) }

            if let result = store.current {
                if result.isPartial && model.diskAccess.hasFullAccess != true { partialNotice }
                content(result, store: store)
            } else if store.isLoading {
                VStack(spacing: 10) {
                    ProgressView(store.isOverview ? "Analyse du Mac par Mole…" : "Analyse du dossier par Mole…")
                    if store.isOverview {
                        Text("La vue d'ensemble parcourt tout le disque et peut prendre jusqu'à une minute.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.lastError == nil {
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle("Analyse")
        .task { await store.start() }
        .onChange(of: store.path) { _, _ in
            highlighted = nil
            selectedAngle = nil
        }
    }

    // MARK: - Navigation

    private func navigationBar(_ store: AnalyzeStore) -> some View {
        HStack(spacing: 8) {
            Button { store.back() } label: { Image(systemName: "chevron.left") }
                .disabled(store.backStack.isEmpty)
                .help("Revenir au niveau précédent")
            Button { store.open(nil) } label: { Image(systemName: "house") }
                .disabled(store.isOverview)
                .help("Vue d'ensemble du Mac")
            Label(store.path.map(Self.shortPath) ?? "Vue d'ensemble du Mac",
                  systemImage: store.isOverview ? "internaldrive" : "folder")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.path ?? "/")
            Spacer()
            if store.isLoading && store.current != nil {
                ProgressView().controlSize(.small)
                Text("Actualisation…").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Trier par", selection: Binding(get: { sort }, set: { newSort in
                if newSort != sort { ascending = newSort.defaultAscending }
                sort = newSort
            })) {
                ForEach(AnalyzeSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Trier la liste")
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .help(ascending ? "Ordre croissant" : "Ordre décroissant")
        }
        .buttonStyle(.borderless)
    }

    private var partialNotice: some View {
        HStack(spacing: 8) {
            Label("Analyse partielle : certains dossiers protégés par macOS n'ont pas pu être lus.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Accès complet au disque…") { model.diskAccess.openSettings() }
                .controlSize(.small)
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private func content(_ result: AnalyzeResult, store: AnalyzeStore) -> some View {
        let isOverview = result.overview ?? store.isOverview
        let parts = isOverview ? overview(result, store: store, capacity: store.capacity) : directoryParts(result)
        let rows = parts.rows
        let slices = parts.slices
        let total = isOverview ? (store.capacity?.total ?? rows.map(\.bytes).reduce(0, +)) : (result.total_size ?? rows.map(\.bytes).reduce(0, +))

        if rows.isEmpty {
            ContentUnavailableView("Dossier vide", systemImage: "folder", description: Text("Mole n'a rien trouvé à mesurer ici."))
        } else {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    chart(slices, total: total, result: result, isOverview: isOverview, capacity: store.capacity)
                        .frame(width: 250, height: 250)
                    if isOverview, let capacity = store.capacity {
                        VStack(spacing: 2) {
                            Text("\(Format.bytes(capacity.available)) libres sur \(Format.bytes(capacity.total))")
                                .font(.callout.weight(.medium))
                            Text("Disque de démarrage").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let files = result.total_files {
                        Text("\(files.formatted()) fichiers").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 250)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(isOverview ? "Répartition" : "Contenu", rows: rows, total: total, slices: slices, store: store)
                        if isOverview {
                            let insights = insightRows(result)
                            if !insights.isEmpty {
                                section("À surveiller", rows: insights, total: total, slices: [], store: store)
                            }
                        } else if let files = result.large_files, !files.isEmpty {
                            largeFiles(files, store: store)
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
    }

    // MARK: - Graphique

    private func chart(_ slices: [AnalyzeSlice], total: Int64, result: AnalyzeResult, isOverview: Bool,
                       capacity: VolumeCapacity?) -> some View {
        let active = highlighted.flatMap { id in slices.first { $0.id == id } }
        return Chart(slices) { slice in
            SectorMark(angle: .value("Taille", Double(slice.bytes)), innerRadius: .ratio(0.62), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(slice.color)
                .opacity(active == nil || active?.id == slice.id ? 1 : 0.35)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, angle in
            highlighted = angle.flatMap { slice(at: $0, in: slices)?.id }
        }
        .chartBackground { _ in
            VStack(spacing: 2) {
                if let active {
                    Text(active.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                    Text(Format.bytes(active.bytes))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(percentText(active.bytes, of: total)).font(.caption).foregroundStyle(.secondary)
                } else if isOverview, let capacity {
                    Text("Utilisé").font(.caption).foregroundStyle(.secondary)
                    Text(Format.bytes(capacity.used))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(percentText(capacity.used, of: capacity.total)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                    Text(Format.bytes(total))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: 140)
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }

    private func slice(at angle: Double, in slices: [AnalyzeSlice]) -> AnalyzeSlice? {
        var cumulative = 0.0
        for slice in slices {
            cumulative += Double(slice.bytes)
            if angle <= cumulative { return slice }
        }
        return nil
    }

    // MARK: - Listes

    private func section(_ title: String, rows: [AnalyzeSlice], total: Int64, slices: [AnalyzeSlice],
                         store: AnalyzeStore) -> some View {
        let largest = max(rows.map(\.bytes).max() ?? 1, 1)
        let sliceIDs = Set(slices.map(\.id))
        let rows = sorted(rows, store: store)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    // Les lignes regroupées dans « Autres éléments » éclairent cette part du graphique.
                    let chartID = sliceIDs.contains(row.id) ? row.id : (sliceIDs.isEmpty ? nil : Self.othersID)
                    rowView(row, total: total, largest: largest, store: store)
                        .onHover { inside in
                            if inside { highlighted = chartID } else if highlighted == chartID { highlighted = nil }
                        }
                }
            }
        }
    }

    private func rowView(_ row: AnalyzeSlice, total: Int64, largest: Int64, store: AnalyzeStore) -> some View {
        HStack(spacing: 10) {
            Circle().fill(row.color).frame(width: 9, height: 9)
            icon(for: row)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(row.path ?? row.name)
            Spacer(minLength: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(row.color.gradient)
                        .frame(width: max(geo.size.width * Double(row.bytes) / Double(largest), 2))
                }
            }
            .frame(width: 90, height: 5)
            if row.pending {
                ProgressView().controlSize(.mini).help("Calcul de la taille exacte en cours")
            }
            Text(row.path.flatMap { store.modified[$0] }.map(Self.dateText) ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(Format.bytes(row.bytes))
                .monospacedDigit()
                .foregroundStyle(row.pending ? .secondary : .primary)
                .frame(width: 72, alignment: .trailing)
            Text(percentText(row.bytes, of: total))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(row.canOpen ? 1 : 0)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.leading, 6 + CGFloat(row.indent) * 22)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 6, expand: EdgeInsets())
        .onTapGesture { if row.canOpen, let path = row.path { store.open(path) } }
        .contextMenu {
            if let path = row.path {
                if row.canOpen { Button("Analyser ce dossier") { store.open(path) } }
                Button("Afficher dans le Finder") { revealInFinder(path) }
            }
        }
    }

    @ViewBuilder
    private func icon(for row: AnalyzeSlice) -> some View {
        if let path = row.path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: row.id == Self.freeID ? "circle.dashed" : "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private func largeFiles(_ files: [AnalyzeResult.LargeFile], store: AnalyzeStore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gros fichiers").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(files.sorted { sort.areInOrder(name: $0.name, $1.name, bytes: $0.size, $1.size,
                                                   date: store.modified[$0.path], store.modified[$1.path],
                                                   ascending: ascending) }) { file in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Text(Self.shortPath((file.path as NSString).deletingLastPathComponent))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help(file.path)
                    Spacer(minLength: 8)
                    Text(store.modified[file.path].map(Self.dateText) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Format.bytes(file.size)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                .font(.callout)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 6, expand: EdgeInsets())
                .contextMenu { Button("Afficher dans le Finder") { revealInFinder(file.path) } }
                .onTapGesture(count: 2) { revealInFinder(file.path) }
            }
        }
    }

    // MARK: - Calcul des parts

    private static let systemID = "#system"
    private static let freeID = "#free"
    private static let othersID = "#others"

    /// Vue d'ensemble : les emplacements se recouvrent (la Bibliothèque est dans le dossier
    /// personnel). La liste les montre imbriqués, avec leur taille complète, celle que l'on
    /// retrouve en ouvrant le dossier. Le graphique ne garde pour chacun que ce qui n'est pas
    /// compté ailleurs, pour correspondre au disque ; le reste de l'espace utilisé va au système.
    private func overview(_ result: AnalyzeResult, store: AnalyzeStore,
                          capacity: VolumeCapacity?) -> (rows: [AnalyzeSlice], slices: [AnalyzeSlice]) {
        let main = result.entries.filter { !$0.isInsight && $0.size > 0 }
        // Emplacement le plus proche qui contient chaque entrée.
        var parentOf: [String: String] = [:]
        for entry in main {
            let parents = main.filter { $0.path != entry.path && Self.isInside(entry.path, $0.path) }
            parentOf[entry.path] = parents.max { $0.path.count < $1.path.count }?.path
        }
        func children(of parent: String?) -> [AnalyzeResult.Entry] {
            main.filter { parentOf[$0.path] == parent }.sorted { store.refinedSize(of: $0) > store.refinedSize(of: $1) }
        }

        var rows: [AnalyzeSlice] = []
        var slices: [AnalyzeSlice] = []
        func add(_ entry: AnalyzeResult.Entry, indent: Int) {
            let kids = children(of: entry.path)
            let full = store.refinedSize(of: entry)
            let own = max(full - kids.map { store.refinedSize(of: $0) }.reduce(0, +), 0)
            let color = Self.palette[rows.count % Self.palette.count]
            let name = Self.label(for: entry.name)
            rows.append(AnalyzeSlice(id: entry.path, name: name, detail: Self.shortPath(entry.path), path: entry.path,
                                     bytes: full, isDirectory: entry.isDirectory, color: color, indent: indent,
                                     pending: store.isRefining(entry.path)))
            let sliceName = kids.isEmpty ? name : name + ", hors " + kids.map { Self.label(for: $0.name).lowercased() }.joined(separator: ", ")
            slices.append(AnalyzeSlice(id: entry.path, name: sliceName, bytes: own, color: color))
            for kid in kids { add(kid, indent: indent + 1) }
        }
        for entry in children(of: nil) { add(entry, indent: 0) }

        if let capacity {
            let system = capacity.used - slices.map(\.bytes).reduce(0, +)
            var extra: [AnalyzeSlice] = []
            if system > 0 {
                extra.append(AnalyzeSlice(id: Self.systemID, name: "Système et autres",
                                          detail: "macOS, mémoire virtuelle, instantanés, dossiers non lus",
                                          bytes: system, color: Self.otherColor))
            }
            extra.append(AnalyzeSlice(id: Self.freeID, name: "Espace libre", detail: "Espace purgeable compris",
                                      bytes: capacity.available, color: Self.freeColor))
            rows += extra
            slices += extra
        }
        return (rows, slices)
    }

    private func insightRows(_ result: AnalyzeResult) -> [AnalyzeSlice] {
        result.entries
            .filter { $0.isInsight && $0.size > 0 }
            .sorted { $0.size > $1.size }
            .map { entry in
                AnalyzeSlice(id: "insight:" + entry.path, name: Self.label(for: entry.name), detail: Self.shortPath(entry.path),
                             path: entry.path, bytes: entry.size, isDirectory: entry.isDirectory, color: .orange)
            }
    }

    private func directoryParts(_ result: AnalyzeResult) -> (rows: [AnalyzeSlice], slices: [AnalyzeSlice]) {
        let rows = directoryRows(result)
        return (rows, chartSlices(rows))
    }

    private func directoryRows(_ result: AnalyzeResult) -> [AnalyzeSlice] {
        result.entries
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
            .enumerated()
            .map { index, entry in
                AnalyzeSlice(id: entry.path, name: entry.name, detail: nil, path: entry.path, bytes: entry.size,
                             isDirectory: entry.isDirectory,
                             color: index < Self.maxSlices ? Self.palette[index % Self.palette.count] : Self.otherColor)
            }
    }

    /// Les plus gros éléments d'un dossier, puis une part qui regroupe tous les autres.
    private func chartSlices(_ rows: [AnalyzeSlice]) -> [AnalyzeSlice] {
        guard rows.count > Self.maxSlices else { return rows }
        let rest = rows.dropFirst(Self.maxSlices)
        return Array(rows.prefix(Self.maxSlices)) + [
            AnalyzeSlice(id: Self.othersID, name: "\(rest.count) autres éléments", bytes: rest.map(\.bytes).reduce(0, +),
                         color: Self.otherColor),
        ]
    }

    // MARK: - Tri

    /// Trie la liste par blocs : un emplacement garde sous lui ceux qu'il contient (lignes en
    /// retrait), triés entre eux. Système et espace libre restent en bas.
    private func sorted(_ rows: [AnalyzeSlice], store: AnalyzeStore) -> [AnalyzeSlice] {
        let pinned = rows.filter { $0.path == nil && $0.id != Self.othersID }
        var blocks: [[AnalyzeSlice]] = []
        for row in rows where !pinned.contains(row) {
            if row.indent == 0 || blocks.isEmpty { blocks.append([row]) } else { blocks[blocks.count - 1].append(row) }
        }
        let inOrder = { (a: AnalyzeSlice, b: AnalyzeSlice) in
            sort.areInOrder(name: a.name, b.name, bytes: a.bytes, b.bytes,
                            date: a.path.flatMap { store.modified[$0] }, b.path.flatMap { store.modified[$0] },
                            ascending: ascending)
        }
        return blocks
            .sorted { inOrder($0[0], $1[0]) }
            .flatMap { [$0[0]] + $0.dropFirst().sorted(by: inOrder) }
            + pinned
    }

    // MARK: - Textes

    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func percentText(_ bytes: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let value = Double(bytes) / Double(total) * 100
        return value < 1 ? "< 1 %" : String(format: "%.0f %%", value)
    }

    private static func isInside(_ child: String, _ parent: String) -> Bool {
        child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Noms des emplacements de la vue d'ensemble, que Mole donne en anglais.
    private static func label(for name: String) -> String {
        let names = [
            "Home": "Dossier personnel",
            "User Library": "Bibliothèque utilisateur",
            "Applications": "Applications",
            "System Library": "Bibliothèque système",
            "Old Downloads (90d+)": "Téléchargements de plus de 90 jours",
            "Docker Data": "Données Docker",
            "JetBrains Cache": "Cache JetBrains",
            "System Logs": "Journaux",
            "Homebrew Cache": "Cache Homebrew",
            "pip Cache": "Cache pip",
            "Xcode Simulators": "Simulateurs Xcode",
            "Xcode DerivedData": "Xcode DerivedData",
            "iOS Backups": "Sauvegardes iOS",
        ]
        return names[name] ?? name
    }
}
