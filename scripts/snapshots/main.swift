// Outil de développement : rend chaque page de l'app dans une fenêtre hors écran et
// l'exporte en PNG (aucune permission d'enregistrement d'écran requise).
// Usage : scripts/snapshots.sh <dossier de sortie>
import AppKit
import SwiftUI

@MainActor
final class Snapshotter {
    let model = AppModel()
    let output: String
    private var window: NSWindow?

    init(output: String) { self.output = output }

    func run() async {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(model))
        window.orderFrontRegardless()
        self.window = window

        await model.bootstrap()
        model.clean.scan()
        try? await Task.sleep(for: .seconds(5))

        let pages: [(Page, Double)] = [(.status, 4), (.purge, 10), (.installers, 8), (.uninstall, 12), (.optimize, 20), (.history, 5), (.clean, 45)]
        for (page, delay) in pages {
            model.page = page
            try? await Task.sleep(for: .seconds(delay))
            snap(window.contentView, name: page.rawValue)
        }

        let menu = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 380),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        menu.contentView = NSHostingView(rootView: MenuBarView().environment(model).background(Color(nsColor: .windowBackgroundColor)))
        menu.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        snap(menu.contentView, name: "menubar")

        model.status.stop()
        try? await Task.sleep(for: .seconds(0.5))
        exit(0)
    }

    private func snap(_ view: NSView?, name: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: output).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("✓ \(name).png")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let snapper = Snapshotter(output: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots")
    Task { await snapper.run() }
    app.run()
}
