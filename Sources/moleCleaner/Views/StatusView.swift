import SwiftUI

struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.status
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = store.lastError { ErrorBanner(message: error) }
                if let snap = store.snapshot {
                    header(snap, hardware: store.hardware)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        cpuCard(snap, store: store)
                        memoryCard(snap, store: store)
                        diskCard(snap)
                        networkCard(snap, store: store)
                        if let battery = snap.batteries?.first { batteryCard(battery, thermal: snap.thermal) }
                        processesCard(snap)
                    }
                } else {
                    ProgressView("Connexion au collecteur Mole…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .navigationTitle("État du système")
    }

    private func header(_ snap: StatusSnapshot, hardware: StatusSnapshot.Hardware?) -> some View {
        HStack(spacing: 20) {
            let score = snap.health_score ?? 0
            RingGauge(value: Double(score) / 100, lineWidth: 9, tint: healthColor(score)) {
                VStack(spacing: 0) {
                    Text("\(score)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("santé").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 4) {
                Text(snap.health_score_msg ?? "—").font(.title2.weight(.semibold))
                Text([hardware?.model, hardware?.cpu_model, hardware?.total_ram].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text([hardware?.os_version, snap.uptime.map { "allumé depuis \($0)" }, snap.procs.map { "\($0) processus" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func cpuCard(_ snap: StatusSnapshot, store: StatusStore) -> some View {
        Card(title: "Processeur", symbol: "cpu") {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(snap.cpu?.usage)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                if let cpu = snap.cpu, let l1 = cpu.load1, let l5 = cpu.load5, let l15 = cpu.load15 {
                    Text(String(format: "charge %.2f · %.2f · %.2f", l1, l5, l15)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Sparkline(samples: store.cpuHistory, tint: .blue, maxValue: 100).frame(height: 50)
            if let cores = snap.cpu?.per_core, !cores.isEmpty {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(usageColor(value).gradient)
                            .frame(height: max(2, 28 * value / 100))
                            .frame(maxWidth: .infinity, maxHeight: 28, alignment: .bottom)
                    }
                }
                .help("Charge par cœur")
            }
        }
    }

    private func memoryCard(_ snap: StatusSnapshot, store: StatusStore) -> some View {
        Card(title: "Mémoire", symbol: "memorychip") {
            let mem = snap.memory
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(mem?.used_percent)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                if let used = mem?.used, let total = mem?.total {
                    Text("\(Format.memory(used)) / \(Format.memory(total))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Sparkline(samples: store.memoryHistory, tint: .purple, maxValue: 100).frame(height: 50)
            HStack {
                if let available = mem?.available { stat("Disponible", Format.memory(available)) }
                if let swap = mem?.swap_used { stat("Swap", Format.memory(swap)) }
                if let pressure = mem?.pressure, !pressure.isEmpty { stat("Pression", pressure) }
            }
        }
    }

    private func diskCard(_ snap: StatusSnapshot) -> some View {
        Card(title: "Disque", symbol: "internaldrive") {
            ForEach(snap.disks ?? []) { disk in
                let free = (disk.total ?? 0) - (disk.used ?? 0)
                UsageBar(label: disk.mount == "/" ? "Macintosh HD" : (disk.mount ?? "Volume"),
                         value: disk.used_percent ?? 0,
                         detail: "\(Format.bytes(free)) libres")
            }
            HStack {
                if let purgeable = snap.rootDisk?.purgeable, purgeable > 0 { stat("Purgeable", Format.bytes(purgeable)) }
                stat("Corbeille", Format.bytes(snap.trash_size ?? 0))
                if let io = snap.disk_io {
                    stat("E/S", "↓\(Format.rate(io.read_rate ?? 0)) ↑\(Format.rate(io.write_rate ?? 0))")
                }
            }
        }
    }

    private func networkCard(_ snap: StatusSnapshot, store: StatusStore) -> some View {
        Card(title: "Réseau", symbol: "network") {
            HStack {
                stat("Réception", Format.rate(snap.networkRx))
                stat("Envoi", Format.rate(snap.networkTx))
                if let ip = snap.primaryIP { stat("IP", ip) }
            }
            ZStack {
                Sparkline(samples: store.rxHistory, tint: .teal)
                Sparkline(samples: store.txHistory, tint: .orange)
            }
            .frame(height: 50)
        }
    }

    private func batteryCard(_ battery: StatusSnapshot.Battery, thermal: StatusSnapshot.Thermal?) -> some View {
        Card(title: "Batterie & énergie", symbol: "battery.75percent") {
            UsageBar(label: battery.status == "AC" ? "Sur secteur" : "Sur batterie",
                     value: battery.percent ?? 0,
                     detail: Format.percent(battery.percent),
                     color: (battery.percent ?? 0) < 20 ? .red : .green)
            HStack {
                if let health = battery.health { stat("État", health) }
                if let capacity = battery.capacity { stat("Capacité", Format.percent(capacity)) }
                if let cycles = battery.cycle_count { stat("Cycles", "\(cycles)") }
            }
            HStack {
                if let power = thermal?.system_power, power > 0 { stat("Consommation", String(format: "%.1f W", power)) }
                if let temp = thermal?.battery_temp, temp > 0 { stat("Temp. batterie", String(format: "%.0f °C", temp)) }
                if let temp = thermal?.cpu_temp, temp > 0 { stat("Temp. CPU", String(format: "%.0f °C", temp)) }
            }
        }
    }

    private func processesCard(_ snap: StatusSnapshot) -> some View {
        Card(title: "Processus les plus actifs", symbol: "list.number") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(snap.top_processes ?? []) { proc in
                    GridRow {
                        Text(proc.name ?? "?").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f %%", proc.cpu ?? 0)).monospacedDigit().foregroundStyle(usageColor(proc.cpu ?? 0))
                        Text(Format.memory(proc.memory_bytes ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
