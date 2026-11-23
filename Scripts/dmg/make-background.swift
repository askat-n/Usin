// Рисует фон окна установочного образа: стрелка от Usin к «Программам».
//   swift Scripts/dmg/make-background.swift   (кладёт background.png и background@2x.png рядом)
import AppKit

let size = NSSize(width: 600, height: 400)
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    // Большая стрелка между значками (значки по центру x=150 и x=450, y=200 сверху → 200 снизу).
    let y: CGFloat = 400 - 200
    let ink = NSColor(srgbRed: 0x25 / 255.0, green: 0x63 / 255.0, blue: 0xEB / 255.0, alpha: 1)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 236, y: y + 9))
    arrow.line(to: NSPoint(x: 328, y: y + 9))
    arrow.line(to: NSPoint(x: 328, y: y + 30))
    arrow.line(to: NSPoint(x: 368, y: y))
    arrow.line(to: NSPoint(x: 328, y: y - 30))
    arrow.line(to: NSPoint(x: 328, y: y - 9))
    arrow.line(to: NSPoint(x: 236, y: y - 9))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 6
    ink.setFill()
    ink.setStroke()
    arrow.fill()
    arrow.stroke()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    func text(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.23, alpha: alpha),
            .paragraphStyle: style,
        ]
        NSString(string: s).draw(in: NSRect(x: 0, y: y, width: 600, height: size * 1.5), withAttributes: attrs)
    }
    text("Перетащи Usin в «Программы»", y: 400 - 70, size: 20, weight: .semibold, alpha: 0.9)
    text("Drag Usin to Applications", y: 400 - 96, size: 14, weight: .regular, alpha: 0.55)
    text("Потом открой Usin из «Программ» · Then open Usin from Applications", y: 46, size: 12, weight: .regular, alpha: 0.45)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

render(scale: 1, to: dir.appendingPathComponent("background.png"))
render(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
