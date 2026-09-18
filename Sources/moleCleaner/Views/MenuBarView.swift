import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snap = model.status.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                let score = snap?.health_score ?? 0
                RingGauge(value: Double(score) / 100, lineWidth: 5, tint: healthColor(score)) {
                    Text("\(score)").font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("moleCleaner").font(.headline)
                    Text(snap?.health_score_msg.map { "Santé : \($0)" } ?? "Connexion à Mole…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let snap {
                UsageBar(label: "CPU", value: snap.cpu?.usage ?? 0)
                UsageBar(label: "Mémoire", value: snap.memory?.used_percent ?? 0)
                if let disk = snap.rootDisk {
                    UsageBar(label: "Disque", value: disk.used_percent ?? 0,
                             detail: "\(Format.bytes((disk.total ?? 0) - (disk.used ?? 0))) libres")
                }
                HStack {
                    Label(Format.rate(snap.networkRx), systemImage: "arrow.down")
                    Spacer()
                    Label(Format.rate(snap.networkTx), systemImage: "arrow.up")
                    if let battery = snap.batteries?.first, let percent = battery.percent {
                        Spacer()
                        Label(Format.percent(percent), systemImage: battery.status == "AC" ? "bolt.fill" : "battery.75percent")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

                if let top = snap.top_processes?.first {
                    Text("Plus actif : \(top.name ?? "?") (\(String(format: "%.0f", top.cpu ?? 0)) % CPU)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            VStack(spacing: 2) {
                if let version = model.update.newVersion {
                    Button {
                        open(nil)
                        model.update.showSheet = true
                    } label: {
                        Label("Mole \(version) disponible", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(MenuRowStyle())
                    .foregroundStyle(.orange)
                }
                menuButton("Ouvrir moleCleaner", symbol: "macwindow") { open(nil) }
                menuButton("Analyser le nettoyage", symbol: "sparkles") {
                    open(.clean)
                    model.clean.scan()
                }
                menuButton("Optimiser", symbol: "wrench.and.screwdriver") { open(.optimize) }
                SettingsLink {
                    Label("Réglages…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowStyle())
                menuButton("Quitter", symbol: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func open(_ page: Page?) {
        if let page { model.page = page }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func menuButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Un ButtonStyle n'est pas une vue : SwiftUI n'y gère pas @State, donc le survol
        // doit être suivi par une vraie vue.
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @LocalState private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.08 : 0))
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
