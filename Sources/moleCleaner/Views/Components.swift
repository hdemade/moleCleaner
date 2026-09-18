import Charts
import SwiftUI

// MARK: - Couleurs de la marque (identiques à l'icône de l'app)

enum Brand {
    static let teal = Color(red: 0.20, green: 0.78, blue: 0.62)
    static let blue = Color(red: 0.17, green: 0.38, blue: 0.80)
    static let gradient = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let angular = AngularGradient(colors: [teal.opacity(0.1), teal, blue], center: .center)
    static let warning = LinearGradient(colors: [Color(red: 0.98, green: 0.68, blue: 0.25), Color(red: 0.90, green: 0.38, blue: 0.24)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Survol

/// Surbrillance douce au survol, comme les boutons de la barre d'outils de macOS.
/// `enabled` permet de la désactiver sur une ligne déjà sélectionnée, qui a son propre fond.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    var opacity: Double = 0.07
    var enabled = true
    /// Débordement du fond au-delà du contenu, pour atteindre la taille du rectangle de sélection.
    var expand = EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
    @LocalState private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? opacity : 0))
                    // Marges négatives : le fond s'étend hors du contenu.
                    .padding(EdgeInsets(top: -expand.top, leading: -expand.leading,
                                        bottom: -expand.bottom, trailing: -expand.trailing))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8, opacity: Double = 0.07, enabled: Bool = true,
                        expand: EdgeInsets = EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, opacity: opacity, enabled: enabled, expand: expand))
    }
}

// MARK: - Cartes et jauges

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

struct RingGauge<Label: View>: View {
    let value: Double // 0...1
    var lineWidth: CGFloat = 10
    var tint: Color = .accentColor
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            label
        }
    }
}

struct Sparkline: View {
    let samples: [Sample]
    var tint: Color = .accentColor
    var maxValue: Double?

    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("t", sample.id), y: .value("v", sample.value))
                .foregroundStyle(tint.opacity(0.15).gradient)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", sample.id), y: .value("v", sample.value))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(maxValue ?? max(samples.map(\.value).max() ?? 1, 0.001)))
    }
}

struct UsageBar: View {
    let label: String
    let value: Double // 0...100
    var detail: String?
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(detail ?? Format.percent(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill((color ?? usageColor(value)).gradient)
                        .frame(width: geo.size.width * min(max(value, 0), 100) / 100)
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 6)
        }
    }
}

func usageColor(_ percent: Double) -> Color {
    switch percent {
    case ..<60: .green
    case ..<85: .orange
    default: .red
    }
}

func healthColor(_ score: Int) -> Color {
    switch score {
    case 80...: .green
    case 60..<80: .yellow
    case 40..<60: .orange
    default: .red
    }
}

// MARK: - Journal d'exécution

struct LogLineRow: View {
    let line: LogLine

    var body: some View {
        if line.kind == .section {
            Text(line.text)
                .font(.callout.weight(.semibold))
                .padding(.top, 6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = line.kind.symbol {
                    Image(systemName: symbol).foregroundStyle(line.kind.tint).font(.caption)
                }
                Text(line.text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(line.kind == .sub ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .padding(.leading, line.kind == .sub ? 18 : 0)
        }
    }
}

extension LineKind {
    var symbol: String? {
        switch self {
        case .success: "checkmark.circle.fill"
        case .action: "arrow.right.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .hint: "lightbulb"
        case .info: "info.circle"
        case .sub: "arrow.turn.down.right"
        case .section, .rule, .plain: nil
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .action: .blue
        case .warning: .orange
        case .error: .red
        case .hint: .yellow
        default: .secondary
        }
    }
}

/// Affiche une session Mole en cours ou terminée : journal en direct, résumé, invite de mot de passe.
struct RunLogView: View {
    @Bindable var session: TerminalSession
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if case .finished = session.state, let summary = session.summary {
                SummaryBox(summary: summary)
            }
            RunLogScroll(lines: session.lines)
        }
        .sheet(item: $session.passwordRequest) { request in
            PasswordSheet(retry: request.retry, onSubmit: session.submitPassword, onCancel: session.declinePassword)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch session.state {
            case .running:
                ProgressView().controlSize(.small)
                Text("\(session.title) en cours…").font(.headline)
                Spacer()
                Button("Interrompre", role: .destructive) { session.cancel() }
            case .finished(let code):
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code == 0 ? .green : .orange)
                Text(code == 0 ? "\(session.title) terminé" : "\(session.title) terminé avec des avertissements (code \(code))")
                    .font(.headline)
                Spacer()
                if let onClose { Button("Fermer", action: onClose) }
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Échec : \(message)").font(.headline)
                Spacer()
                if let onClose { Button("Fermer", action: onClose) }
            }
        }
    }
}

/// Journal brut d'une session, déroulé automatiquement sur la dernière ligne.
struct RunLogScroll: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        LogLineRow(line: line).id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            .onChange(of: lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

/// Exécution d'une tâche Mole présentée comme l'analyse du nettoyage : un grand disque animé
/// au lieu d'un terminal. Le journal complet reste accessible d'un clic.
struct RunHero: View {
    @Bindable var session: TerminalSession
    let symbol: String
    let runningTitle: String
    let doneTitle: String
    let hint: String
    var onClose: (() -> Void)?

    @LocalState private var showLog = false
    private let diameter: CGFloat = 176

    private var running: Bool { session.isRunning }

    private var failed: Bool {
        switch session.state {
        case .running: false
        case .finished(let code): code != 0
        case .failed: true
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            disc
            VStack(spacing: 6) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                if !caption.isEmpty {
                    Text(caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: caption)
                }
            }
            if !running, let summary = session.summary {
                SummaryBox(summary: summary).frame(maxWidth: 520)
            }
            HStack(spacing: 14) {
                if running {
                    Button("Interrompre", role: .destructive) { session.cancel() }
                } else if let onClose {
                    Button("Terminé", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Button(showLog ? "Masquer le journal" : "Voir le journal") { showLog.toggle() }
                    .buttonStyle(.link)
            }
            if showLog {
                RunLogScroll(lines: session.lines)
                    .frame(maxWidth: 620, maxHeight: 220)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $session.passwordRequest) { request in
            PasswordSheet(retry: request.retry, onSubmit: session.submitPassword, onCancel: session.declinePassword)
        }
    }

    private var heading: String {
        if running { return runningTitle }
        if case .failed = session.state { return "Échec" }
        return failed ? "\(doneTitle) avec des avertissements" : doneTitle
    }

    /// Pendant l'exécution : l'étape en cours, lue sur la dernière ligne utile du journal.
    private var caption: String {
        if running { return currentStep ?? hint }
        if case .failed(let message) = session.state { return message }
        return session.summary == nil ? hint : ""
    }

    private var currentStep: String? {
        session.lines.last { $0.kind != .rule && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.text
    }

    private var disc: some View {
        ZStack {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                // ZStack explicite : sans lui les cercles s'empilent verticalement.
                ZStack {
                    if running {
                        Circle()
                            .stroke(.quaternary, lineWidth: 5)
                            .frame(width: diameter + 34, height: diameter + 34)
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(Brand.angular, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .frame(width: diameter + 34, height: diameter + 34)
                            .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                    }
                }
            }
            ZStack {
                Circle()
                    .fill(failed ? Brand.warning : Brand.gradient)
                    .shadow(color: (failed ? Color.orange : Brand.teal).opacity(0.35), radius: 18, y: 8)
                Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                Image(systemName: glyph)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: running)
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter + 80, height: diameter + 80)
    }

    private var glyph: String {
        if running { return symbol }
        return failed ? "exclamationmark.triangle.fill" : "checkmark"
    }
}

struct SummaryBox: View {
    let summary: MoleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.heading).font(.headline)
            ForEach(summary.details, id: \.self) { detail in
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PasswordSheet: View {
    let retry: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @LocalState private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mot de passe administrateur", systemImage: "lock.shield").font(.headline)
            Text("Mole a besoin des droits administrateur pour cette étape. Le mot de passe est transmis directement à sudo et n'est jamais enregistré.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Label("Mot de passe incorrect, réessaie.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            SecureField("Mot de passe", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Button("Continuer sans admin", role: .cancel) {
                    password = ""
                    onCancel()
                }
                Spacer()
                Button("Valider", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        onSubmit(value)
    }
}

// MARK: - En-têtes de page

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            actions
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
