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

    let bg = NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                        ending: NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.94, alpha: 1))!
    bg.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Стрелка между значками (значки стоят в x=150 и x=450, y=190 сверху → 210 снизу).
    let y: CGFloat = 400 - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 240, y: y))
    arrow.curve(to: NSPoint(x: 350, y: y), controlPoint1: NSPoint(x: 280, y: y + 22), controlPoint2: NSPoint(x: 315, y: y + 22))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let ink = NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.47, alpha: 0.85)
    ink.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 336, y: y + 15))
    head.line(to: NSPoint(x: 352, y: y))
    head.line(to: NSPoint(x: 334, y: y - 9))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

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
    text("Перетащи Usin в «Программы»", y: 400 - 72, size: 20, weight: .semibold, alpha: 0.9)
    text("Drag Usin to Applications", y: 400 - 98, size: 14, weight: .regular, alpha: 0.55)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

render(scale: 1, to: dir.appendingPathComponent("background.png"))
render(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
