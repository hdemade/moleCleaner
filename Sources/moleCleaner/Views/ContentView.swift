import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var update = model.update
        @Bindable var appUpdate = model.appUpdate
        @Bindable var diskAccess = model.diskAccess
        NavigationSplitView {
            List(selection: $model.page) {
                Section("Surveillance") { row(.status) }
                Section("Nettoyage") {
                    row(.clean)
                    row(.purge)
                    row(.installers)
                }
                Section("Applications") { row(.uninstall) }
                Section("Maintenance") {
                    row(.optimize)
                    row(.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            PageDetail(page: model.page ?? .status)
        }
        .task { await model.bootstrap() }
        .sheet(isPresented: $diskAccess.showSheet, onDismiss: model.launchSheetDismissed) {
            DiskAccessSheet().environment(model)
        }
        .sheet(isPresented: $appUpdate.showSheet, onDismiss: model.launchSheetDismissed) {
            AppUpdateSheet().environment(model)
        }
        .sheet(isPresented: $update.showSheet, onDismiss: model.launchSheetDismissed) {
            UpdateSheet().environment(model)
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            // La ligne sélectionnée garde son propre fond : pas de surbrillance en plus.
            .hoverHighlight(enabled: model.page != page)
            .tag(page)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let active = model.lock.active {
                Label("\(active) en cours", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    versionButton(model.version.map { "Mole \($0)" } ?? "Mole",
                                  newVersion: model.update.newVersion, product: "Mole") {
                        model.update.showSheet = true
                    }
                    versionButton("moleCleaner \(model.appUpdate.currentVersion)",
                                  newVersion: model.appUpdate.release?.version, product: "moleCleaner") {
                        model.appUpdate.showSheet = true
                    }
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6, expand: EdgeInsets())
                .help("Réglages")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Version affichée en bas de la barre latérale, en orange avec une pastille quand une mise à
    /// jour est disponible ; un clic ouvre la feuille de mise à jour correspondante.
    private func versionButton(_ title: String, newVersion: String?, product: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if newVersion != nil {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
            }
            .font(.caption)
            .foregroundStyle(newVersion == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(expand: EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .help(newVersion.map { "\(product) \($0) est disponible" } ?? "Rechercher les mises à jour de \(product)")
    }
}

/// Contenu de la colonne de droite. La largeur idéale est fixée explicitement : sinon SwiftUI
/// la déduit des sous-titres mis sur une seule ligne (≈ 1000 px) et NavigationSplitView replie
/// la barre latérale pour faire de la place.
struct PageDetail: View {
    @Environment(AppModel.self) private var model
    let page: Page

    var body: some View {
        Group {
            if !model.isMoleInstalled {
                MoleMissingView()
            } else {
                switch page {
                case .status: StatusView()
                case .clean: CleanView()
                case .purge: DiskItemsView(store: model.purge)
                case .installers: DiskItemsView(store: model.installers)
                case .uninstall: UninstallView()
                case .optimize: OptimizeView()
                case .history: HistoryView()
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 760, maxWidth: .infinity,
               minHeight: 420, idealHeight: 620, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage("menuBarShowsCPU") private var showsCPU = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if showsCPU, let cpu = model.status.snapshot?.cpu?.usage {
                Text("\(Int(cpu.rounded()))%").monospacedDigit()
            }
        }
        .task { await model.bootstrap() }
    }
}

/// Écran affiché quand la CLI Mole est absente : elle peut être installée depuis ici.
struct MoleMissingView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var confirmingScript = false

    var body: some View {
        let setup = model.setup
        VStack(spacing: 0) {
            switch setup.phase {
            case .idle:
                intro(setup)
            case .running:
                if let session = setup.session {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Installation de Mole").font(.title2.weight(.semibold))
                        RunLogView(session: session)
                    }
                    .padding(24)
                }
            case .installed(let version):
                success(version, setup: setup)
            case .failed(let message):
                failure(message, setup: setup)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Installer Mole sans Homebrew ?", isPresented: $confirmingScript) {
            Button("Télécharger et exécuter le script") { model.setup.installViaScript() }
        } message: {
            Text("Cette méthode télécharge le script d'installation officiel de Mole et l'exécute :\n\n\(model.setup.scriptCommand)\n\nMole sera installé dans ton dossier personnel, donc sans mot de passe administrateur.")
        }
    }

    private func intro(_ setup: SetupStore) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 120, height: 120)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Installer Mole").font(.title.weight(.semibold))
                Text("moleCleaner est une interface pour Mole, l'outil en ligne de commande qui fait le travail de nettoyage, de désinstallation et de maintenance. Il n'est pas encore installé sur ce Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                if setup.brewPath != nil {
                    Button { setup.installViaHomebrew() } label: {
                        Label("Installer avec Homebrew", systemImage: "shippingbox")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Text(setup.homebrewCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Button("Installer sans Homebrew…") { confirmingScript = true }
                        .buttonStyle(.link)
                } else {
                    Button { confirmingScript = true } label: {
                        Label("Installer avec le script officiel", systemImage: "terminal")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Label("Homebrew n'a pas été trouvé sur ce Mac.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link("Installer Homebrew d'abord", destination: URL(string: "https://brew.sh")!)
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(30)
    }

    private func success(_ version: String, setup: SetupStore) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 110, height: 110)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Mole \(version) est installé").font(.title2.weight(.semibold))
            Text("Redémarre moleCleaner pour commencer à l'utiliser.")
                .foregroundStyle(.secondary)
            Button("Relancer moleCleaner") { setup.relaunch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if let session = setup.session {
                DisclosureGroup("Voir le journal d'installation") {
                    RunLogView(session: session).frame(height: 220)
                }
                .frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
    }

    private func failure(_ message: String, setup: SetupStore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("L'installation a échoué").font(.title2.weight(.semibold))
            ErrorBanner(message: message)
            if let session = setup.session {
                RunLogView(session: session)
            }
            HStack {
                Button("Réessayer") { setup.dismissSession() }
                Spacer()
                Text("Tu peux aussi lancer « \(setup.homebrewCommand) » dans le Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarShowsCPU") private var showsCPU = true
    @LocalState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @LocalState private var loginError: String?

    var body: some View {
        @Bindable var status = model.status
        @Bindable var update = model.update
        @Bindable var appUpdate = model.appUpdate
        @Bindable var diskAccess = model.diskAccess
        Form {
            Section("Surveillance") {
                Picker("Fréquence de mise à jour", selection: $status.interval) {
                    Text("1 s").tag(1)
                    Text("2 s").tag(2)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }
                Toggle("Afficher le CPU dans la barre de menus", isOn: $showsCPU)
            }
            Section("Démarrage") {
                Toggle("Lancer à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Accès au disque") {
                LabeledContent("Accès complet au disque") {
                    HStack(spacing: 8) {
                        diskAccessStatus
                        Button("Ouvrir les réglages") { model.diskAccess.openSettings() }
                    }
                }
                Toggle("Demander au lancement s'il n'est pas accordé", isOn: $diskAccess.promptAtLaunch)
            }
            Section("moleCleaner") {
                LabeledContent("Version installée", value: model.appUpdate.currentVersion)
                LabeledContent("Mises à jour") {
                    HStack(spacing: 8) {
                        appUpdateStatus
                        Button("Vérifier") { Task { await model.appUpdate.check() } }
                            .disabled(model.appUpdate.isChecking)
                        if model.appUpdate.release != nil {
                            Button("Mettre à jour…") {
                                openWindow(id: "main")
                                model.appUpdate.showSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Toggle("Vérifier automatiquement au lancement", isOn: $appUpdate.autoCheck)
            }
            Section("Mole") {
                LabeledContent("Version installée", value: model.version ?? "—")
                LabeledContent("Installé via", value: model.update.installMethod.label)
                LabeledContent("Mises à jour") {
                    HStack(spacing: 8) {
                        updateStatus
                        Button("Vérifier") { Task { await model.update.check() } }
                            .disabled(model.update.isChecking)
                        if model.update.newVersion != nil {
                            Button("Mettre à jour…") {
                                openWindow(id: "main")
                                model.update.showSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Toggle("Vérifier automatiquement au lancement", isOn: $update.autoCheck)
                LabeledContent("Exécutable", value: model.moPath ?? "introuvable")
                LabeledContent("Liste de protection", value: MoleCLI.whitelistFile)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // L'accès se modifie dans Réglages Système : on relit l'état en revenant dans l'app.
        .onAppear { model.diskAccess.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.diskAccess.refresh()
        }
    }

    @ViewBuilder
    private var diskAccessStatus: some View {
        switch model.diskAccess.hasFullAccess {
        case true?:
            Label("Accordé", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case false?:
            Label("Non accordé", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case nil:
            Text("Inconnu").foregroundStyle(.secondary).font(.callout)
        }
    }

    @ViewBuilder
    private var appUpdateStatus: some View {
        switch model.appUpdate.status {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Vérification…")
            }
            .font(.callout)
        case .upToDate:
            Label("À jour", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .available(let release):
            Label("\(release.version) disponible", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange).font(.callout)
        case .failed:
            Label("Échec de la vérification", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .unknown:
            Text("—").foregroundStyle(.secondary).font(.callout)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.update.status {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Vérification…")
            }
            .font(.callout)
        case .upToDate:
            Label("À jour", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .available(let version):
            Label("\(version) disponible", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange).font(.callout)
        case .pendingHomebrew(let version):
            Label("\(version) publiée", systemImage: "clock").foregroundStyle(.orange).font(.callout)
        case .failed:
            Label("Échec de la vérification", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .unknown:
            Text("—").foregroundStyle(.secondary).font(.callout)
        }
    }
}
