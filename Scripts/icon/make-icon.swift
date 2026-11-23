// Значок Usin: белый фон, белый круг с чёрной обводкой и большая «U» посередине.
//   swift Scripts/icon/make-icon.swift   (перерисовывает Usin/Assets.xcassets/AppIcon.appiconset)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("Usin/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

/// mac: значок по сетке macOS (белая плитка 824/1024 с тенью); full: во весь квадрат (iPhone — углы скругляет система).
func draw(px: Int, mac: Bool) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024

    var tile = NSRect(x: 0, y: 0, width: s, height: s)
    if mac {
        tile = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = 22 * u
        shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.08).setStroke()
        path.lineWidth = max(1, 2 * u)
        path.stroke()
    } else {
        NSColor.white.setFill()
        tile.fill()
    }

    // Круг: белый, с чёрной обводкой.
    let d = tile.width * 0.70
    let line = tile.width * 0.045
    let circle = NSRect(x: tile.midX - d / 2, y: tile.midY - d / 2, width: d, height: d)
    let ring = NSBezierPath(ovalIn: circle)
    NSColor.white.setFill()
    ring.fill()
    NSColor.black.setStroke()
    ring.lineWidth = line
    ring.stroke()

    // Большая «U».
    let font = NSFont.systemFont(ofSize: d * 0.72, weight: .bold)
    let text = NSAttributedString(string: "U", attributes: [.font: font, .foregroundColor: NSColor.black])
    let b = text.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin, .usesFontLeading])
    // По вертикали центрируем саму букву (высота заглавных), а не строку целиком.
    let y = circle.midY - (font.capHeight / 2) + font.descender - b.origin.y
    text.draw(at: NSPoint(x: circle.midX - b.width / 2, y: y))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(pt)@\(scale)x.png"
        try! draw(px: pt * scale, mac: true).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
try! draw(px: 1024, mac: false).write(to: set.appendingPathComponent("ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])

let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
print("Значок готов: \(set.path)")
