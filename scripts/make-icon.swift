// Génère l'icône de moleCleaner : la silhouette de taupe du logo Mole (scripts/mole-mark.png)
// posée dans un traitement façon icônes macOS récentes (squircle, dégradés doux, verre, ombre).
// Usage :
//   make-icon preview <dossier>            → aperçus des variantes (512 px + 32 px agrandi)
//   make-icon iconset <dossier> [variante] → jeu d'icônes pour iconutil (défaut : a)
import AppKit

let scriptDir = ((CommandLine.arguments.first ?? ".") as NSString).deletingLastPathComponent
let markCandidates = [
    "scripts/mole-mark.png",
    scriptDir + "/../scripts/mole-mark.png",
    scriptDir + "/mole-mark.png",
]
guard let markFile = markCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
      let mark = NSImage(contentsOfFile: markFile) else {
    FileHandle.standardError.write(Data("mole-mark.png introuvable\n".utf8))
    exit(1)
}

// MARK: - Palette

let cream = NSColor(srgbRed: 0.976, green: 0.957, blue: 0.902, alpha: 1)
let creamDeep = NSColor(srgbRed: 0.933, green: 0.894, blue: 0.804, alpha: 1)
let espresso = NSColor(srgbRed: 0.161, green: 0.106, blue: 0.063, alpha: 1)
let forest = NSColor(srgbRed: 0.231, green: 0.345, blue: 0.263, alpha: 1)
let forestDeep = NSColor(srgbRed: 0.098, green: 0.169, blue: 0.125, alpha: 1)
let tealC = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.62, alpha: 1)
let blueC = NSColor(srgbRed: 0.17, green: 0.38, blue: 0.80, alpha: 1)

// MARK: - Formes

/// Superellipse : la forme « squircle » des icônes macOS, plus douce qu'un rectangle arrondi.
func squircle(_ rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for i in 0 ... steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

let iconRect = NSRect(x: 92, y: 92, width: 840, height: 840)

func withShadow(_ block: () -> Void, alpha: CGFloat, blur: CGFloat, dy: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    block()
    NSGraphicsContext.restoreGraphicsState()
}

/// Fond : squircle rempli d'un dégradé, avec ombre portée douce.
func base(_ colors: [NSColor], angle: CGFloat = -60) -> NSBezierPath {
    let shape = squircle(iconRect)
    withShadow({ NSColor.white.setFill(); shape.fill() }, alpha: 0.26, blur: 24, dy: -12)
    NSGradient(colors: colors)!.draw(in: shape, angle: angle)
    return shape
}

// MARK: - Silhouette

/// Alpha du logo, calculé une fois. Le seuil supprime le fond très légèrement opaque du PNG
/// source, qui sinon dessine un rectangle pâle autour de la taupe.
let markAlpha: (rep: NSBitmapImageRep, values: [CGFloat]) = {
    guard let rep = mark.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
        fatalError("logo illisible")
    }
    var values = [CGFloat](repeating: 0, count: rep.pixelsWide * rep.pixelsHigh)
    for y in 0 ..< rep.pixelsHigh {
        for x in 0 ..< rep.pixelsWide {
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            values[y * rep.pixelsWide + x] = max(0, min(1, (a - 0.3) / 0.7))
        }
    }
    return (rep, values)
}()

/// Recolore le logo en conservant son anticrénelage.
func tinted(_ color: NSColor) -> NSImage {
    let (src, alpha) = markAlpha
    let w = src.pixelsWide, h = src.pixelsHigh
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    let (r, g, b) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    guard let data = out.bitmapData else { return NSImage(size: .zero) }
    for index in 0 ..< (w * h) {
        let a = alpha[index]
        let o = index * 4
        data[o] = UInt8(r * a * 255)
        data[o + 1] = UInt8(g * a * 255)
        data[o + 2] = UInt8(b * a * 255)
        data[o + 3] = UInt8(a * 255)
    }
    let image = NSImage(size: NSSize(width: w, height: h))
    image.addRepresentation(out)
    return image
}

/// Cadre utile du dessin (hors transparence), en points image, origine en bas à gauche.
let markContentRect: NSRect = {
    let (rep, alpha) = markAlpha
    var minX = rep.pixelsWide, maxX = 0, minY = rep.pixelsHigh, maxY = 0
    for y in 0 ..< rep.pixelsHigh {
        for x in 0 ..< rep.pixelsWide where alpha[y * rep.pixelsWide + x] > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX > minX else { return NSRect(origin: .zero, size: mark.size) }
    // colorAt et bitmapData partent du haut : on retourne l'axe Y pour dessiner.
    let top = CGFloat(rep.pixelsHigh - 1 - maxY), bottom = CGFloat(rep.pixelsHigh - 1 - minY)
    return NSRect(x: CGFloat(minX), y: top, width: CGFloat(maxX - minX + 1), height: bottom - top + 1)
}()

/// Dessine la taupe recolorée, centrée, à la largeur demandée.
func drawMark(_ color: NSColor, width: CGFloat, center: NSPoint, shadowAlpha: CGFloat = 0) {
    let image = tinted(color)
    let scale = width / markContentRect.width
    let height = markContentRect.height * scale
    let dest = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    NSGraphicsContext.current?.imageInterpolation = .high
    let draw = {
        image.draw(in: dest, from: markContentRect, operation: .sourceOver, fraction: 1)
    }
    if shadowAlpha > 0 {
        withShadow(draw, alpha: shadowAlpha, blur: width * 0.05, dy: -width * 0.02)
    } else {
        draw()
    }
}

// MARK: - Variantes

/// A — Crème & terre : palette du logo Mole, esprit des icônes claires d'Apple.
func variantA() {
    let shape = base([cream, creamDeep])
    NSGraphicsContext.saveGraphicsState()
    shape.setClip()
    NSGradient(colors: [espresso.withAlphaComponent(0.09), espresso.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 92, y: 92, width: 840, height: 260), angle: 90)
    let rim = squircle(iconRect.insetBy(dx: 5, dy: 5))
    rim.lineWidth = 7
    NSColor.white.withAlphaComponent(0.75).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    drawMark(espresso, width: 610, center: NSPoint(x: 512, y: 500), shadowAlpha: 0.16)
}

/// B — Verre sur vert : disque translucide façon « liquid glass » de macOS 26.
func variantB() {
    _ = base([forest, forestDeep])
    let disc = NSBezierPath(ovalIn: NSRect(x: 512 - 302, y: 512 - 302, width: 604, height: 604))
    withShadow({ NSColor.black.withAlphaComponent(0.25).setFill(); disc.fill() }, alpha: 0.3, blur: 40, dy: -14)
    NSColor.white.withAlphaComponent(0.14).setFill()
    disc.fill()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.34), NSColor.white.withAlphaComponent(0.02)])!
        .draw(in: disc, relativeCenterPosition: NSPoint(x: -0.4, y: 0.6))
    disc.lineWidth = 5
    NSColor.white.withAlphaComponent(0.4).setStroke()
    disc.stroke()
    drawMark(cream, width: 452, center: NSPoint(x: 512, y: 498), shadowAlpha: 0.3)
}

/// C — Dégradé de l'app : reprend le vert-bleu de l'interface, avec le disque crème du logo.
func variantC() {
    _ = base([tealC, blueC])
    let disc = NSBezierPath(ovalIn: NSRect(x: 512 - 300, y: 512 - 300, width: 600, height: 600))
    withShadow({ cream.setFill(); disc.fill() }, alpha: 0.28, blur: 34, dy: -12)
    NSGradient(colors: [cream, creamDeep])!.draw(in: disc, angle: -70)
    drawMark(espresso, width: 448, center: NSPoint(x: 512, y: 498))
}

/// D — Silhouette pleine page : la taupe en blanc sur le vert, sans disque.
func variantD() {
    _ = base([forest, forestDeep])
    drawMark(cream, width: 640, center: NSPoint(x: 512, y: 505), shadowAlpha: 0.22)
}

// MARK: - Rendu

func render(_ variant: String, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform()
    t.scale(by: CGFloat(px) / 1024)
    t.concat()
    switch variant {
    case "b": variantB()
    case "c": variantC()
    case "d": variantD()
    default: variantA()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// Agrandissement sans lissage d'un petit rendu, pour juger la lisibilité en 32 px.
func writeMagnified(_ variant: String, small: Int, factor: Int, to path: String) {
    let src = render(variant, px: small)
    let px = small * factor
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    write(rep, to: path)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "iconset"
let outDir = args.count > 2 ? args[2] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if mode == "preview" {
    for variant in ["a", "b", "c", "d"] {
        write(render(variant, px: 512), to: "\(outDir)/\(variant).png")
        writeMagnified(variant, small: 32, factor: 8, to: "\(outDir)/\(variant)-32.png")
        print("✓ \(variant)")
    }
} else {
    let variant = args.count > 3 ? args[3] : "a"
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            write(render(variant, px: base * scale), to: "\(outDir)/\(name)")
        }
    }
    print("✓ iconset (variante \(variant))")
}
