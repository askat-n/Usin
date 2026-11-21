import SwiftUI
import QuartzCore
import CoreText

// MARK: - Palette

/// Стиль «Терминал»: чёрный экран, зелёный люминофор, моноширинный шрифт.
enum Term {
    static let bg = Color(hex: 0x030603)
    static let panel = Color(hex: 0x070C07)
    static let green = Color(hex: 0x4ADE80)
    static let dim = Color(hex: 0x4ADE80).opacity(0.35)

    /// Цвет заметки: яркий цвет терминала или зелёный люминофор.
    static func ink(_ index: Int) -> Color {
        Palette.terminalInks.indices.contains(index) ? Palette.terminalInks[index] : green
    }

    /// Ширина символа моноширинного шрифта в долях размера (SF Mono ≈ 0,6).
    static let charWidth: CGFloat = 0.6
}

// MARK: - Background

/// Фон «Терминала» на Core Animation: чёрный экран, едва заметная сетка,
/// строки развёртки, виньетка и медленно проходящая полоса «развёртки».
struct TerminalBackground: View {
    let transform: CanvasTransform
    let animate: Bool
    let showGrid: Bool

    var body: some View {
        LayerHost { root, size, scale, env in
            render(root, size: size, scale: scale, env: env)
        }
        .allowsHitTesting(false)
    }

    private func render(_ root: CALayer, size: CGSize, scale: CGFloat, env: EnvironmentValues) {
        let bounds = CGRect(origin: .zero, size: size)

        let bg = root.sublayer("bg", scale: scale) { CALayer() }
        bg.frame = bounds
        bg.backgroundColor = Term.bg.cg(env)

        // Сетка — двигается вместе с холстом.
        let grid = root.sublayer("grid", scale: scale) { CAShapeLayer() }
        grid.frame = bounds
        grid.isHidden = !showGrid
        grid.fillColor = nil
        grid.strokeColor = Term.green.opacity(0.055).cg(env)
        grid.lineWidth = 1
        if showGrid {
            var spacing = 40 * transform.scale
            while spacing < 16 { spacing *= 2 }
            let origin = transform.toScreen(.zero)
            let path = CGMutablePath()
            var x = origin.x.truncatingRemainder(dividingBy: spacing)
            if x < 0 { x += spacing }
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y = origin.y.truncatingRemainder(dividingBy: spacing)
            if y < 0 { y += spacing }
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            grid.path = path
        }

        // Строки развёртки — неподвижные, как на мониторе.
        let scan = root.sublayer("scanlines", scale: scale) { CAShapeLayer() }
        scan.frame = bounds
        scan.fillColor = nil
        scan.strokeColor = Color.black.opacity(0.35).cg(env)
        scan.lineWidth = 1
        let lines = CGMutablePath()
        var y: CGFloat = 0
        while y <= size.height { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y)); y += 3 }
        scan.path = lines

        // Полоса развёртки — раз в несколько секунд проходит сверху вниз.
        let sweep = root.sublayer("sweep", scale: scale) { CAGradientLayer() }
        let band: CGFloat = 140
        sweep.colors = [Term.green.opacity(0).cg(env), Term.green.opacity(0.045).cg(env), Term.green.opacity(0).cg(env)]
        sweep.bounds = CGRect(x: 0, y: 0, width: size.width, height: band)
        let sweepDown: Bool = {
            #if os(macOS)
            return sweep.contentsAreFlipped()
            #else
            return true
            #endif
        }()
        sweep.position = CGPoint(x: size.width / 2, y: sweepDown ? -band : size.height + band)
        sweep.isHidden = !animate
        sweep.removeAnimation(forKey: "sweep") // высота экрана могла измениться
        if animate {
            let a = basic("position.y", from: sweepDown ? -band : size.height + band,
                          to: sweepDown ? size.height + band : -band, duration: 7, autoreverses: false, timing: .linear)
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            sweep.add(a, forKey: "sweep")
        }

        // Дождь данных — струйки символов с яркой «головой» и тающим хвостом падают сверху вниз.
        // Каждая струйка — слой с анимацией положения: её крутит система, процессор не нужен.
        let rain = root.sublayer("rain", scale: scale) { CALayer() }
        rain.frame = bounds
        let yDown: Bool = {
            #if os(macOS)
            return rain.contentsAreFlipped()
            #else
            return true
            #endif
        }()
        let sizeKey = "\(Int(size.width))x\(Int(size.height))"
        if rain.value(forKey: "size") as? String != sizeKey, size.width > 0, size.height > 0 {
            rain.sublayers?.forEach { $0.removeFromSuperlayer() }
            var rng = SeededRandom(7)
            let count = min(26, max(10, Int(size.width / 34)))
            for i in 0..<count {
                let image = Glyphs.strip(seed: UInt64(i) &* 977 &+ 13)
                let stream = CALayer()
                stream.contents = image
                stream.contentsScale = 2
                let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
                stream.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                stream.position = CGPoint(x: rng.next() * size.width, y: -h)
                stream.opacity = Float(0.35 + rng.next() * 0.35)
                let duration = 9 + rng.next() * 12
                let fall = basic("position.y", from: yDown ? -h : size.height + h, to: yDown ? size.height + h : -h,
                                 duration: duration, autoreverses: false, timing: .linear)
                fall.timeOffset = rng.next() * duration
                fall.repeatCount = .infinity
                fall.isRemovedOnCompletion = false
                stream.setValue(fall, forKey: "fallTemplate")
                rain.addSublayer(stream)
            }
            rain.setValue(sizeKey, forKey: "size")
        }
        for stream in rain.sublayers ?? [] {
            if animate, stream.animation(forKey: "fall") == nil, let fall = stream.value(forKey: "fallTemplate") as? CAAnimation {
                stream.add(fall, forKey: "fall")
            } else if !animate {
                stream.removeAnimation(forKey: "fall")
            }
        }
        rain.isHidden = !animate

        // Мерцание экрана — едва заметное, как у старого монитора.
        let flicker = root.sublayer("flicker", scale: scale) { CALayer() }
        flicker.frame = bounds
        flicker.backgroundColor = Color.black.cg(env)
        flicker.opacity = 0
        flicker.loop("flicker", enabled: animate) {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, 0.05, 0, 0.025, 0, 0, 0.06, 0, 0]
            a.duration = 3.7
            return a
        }

        // Виньетка — края экрана чуть темнее.
        let vignette = root.sublayer("vignette", scale: scale) { CAGradientLayer() }
        vignette.frame = bounds
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        vignette.colors = [Color.black.opacity(0).cg(env), Color.black.opacity(0).cg(env), Color.black.opacity(0.55).cg(env)]
        vignette.locations = [0, 0.55, 1]
    }
}

// MARK: - Packets and cursor

/// «Пакеты данных», бегущие по стрелкам.
struct TerminalFlows: View {
    struct Edge { let id: UUID; let path: Path; let width: CGFloat; let opacity: Float; let color: Color }

    let edges: [Edge]
    let animate: Bool

    var body: some View {
        LayerHost { root, size, scale, env in
            render(root, size: size, scale: scale, env: env)
        }
        .allowsHitTesting(false)
    }

    private func render(_ root: CALayer, size: CGSize, scale: CGFloat, env: EnvironmentValues) {
        let bounds = CGRect(origin: .zero, size: size)

        let host = root.sublayer("packets", scale: scale) { CALayer() }
        host.frame = bounds
        var keep = Set<String>()
        for e in edges {
            let name = e.id.uuidString
            keep.insert(name)
            let layer = host.sublayer(name, scale: scale) { CAShapeLayer() }
            layer.frame = bounds
            layer.path = e.path.cgPath
            layer.fillColor = nil
            layer.strokeColor = e.color.cg(env)
            layer.lineWidth = e.width
            layer.lineCap = .butt
            layer.lineDashPattern = [NSNumber(value: Double(e.width) * 1.6), 18]
            layer.opacity = e.opacity
            layer.isHidden = !animate
            layer.loop("flow", enabled: animate) {
                basic("lineDashPhase", from: 0, to: -(Double(e.width) * 1.6 + 18), duration: 1.1,
                      autoreverses: false, timing: .linear)
            }
        }
        host.removeSublayers(except: keep)
    }
}

/// Мигающий курсор после надписи на сфере. Лежит поверх заметок.
struct TerminalCaret: View {
    let rect: CGRect
    let color: Color
    let animate: Bool

    var body: some View {
        LayerHost { root, _, scale, env in
            let caret = root.sublayer("cursor", scale: scale) { CALayer() }
            caret.frame = rect
            caret.backgroundColor = color.cg(env)
            caret.shadowColor = color.cg(env)
            caret.shadowOpacity = 0.8
            caret.shadowRadius = 6
            caret.shadowOffset = .zero
            caret.loop("blink", enabled: animate) {
                let a = CAKeyframeAnimation(keyPath: "opacity")
                // В режиме .discrete точек времени должно быть на одну больше, чем значений,
                // иначе система молча игнорирует анимацию.
                a.values = [1, 0]
                a.keyTimes = [0, 0.5, 1]
                a.calculationMode = .discrete
                a.duration = 1.06
                return a
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glyphs for data rain

/// Картинки символов для дождя данных — рисуются один раз моноширинным шрифтом.
enum Glyphs {
    static let images: [CGImage] = Array("0110ABCDEF7λ>_#").compactMap { image(String($0)) }

    /// Вертикальная струйка из 4–9 символов: сверху тусклые, внизу яркая «голова».
    static func strip(seed: UInt64) -> CGImage {
        var rng = SeededRandom(seed)
        let chars = Array("0123456789ABCDEF01λ>_#")
        let n = 4 + Int(rng.next() * 6)
        let fontSize: CGFloat = 26
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let lineH = Int(fontSize * 1.25), w = Int(fontSize * 0.75)
        let h = lineH * n
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<n {
            // i = 0 — верх струйки (самый тусклый), i = n-1 — «голова» (самая яркая, почти белая).
            let t = CGFloat(i + 1) / CGFloat(n)
            let head = i == n - 1
            let color = head ? CGColor(red: 0.8, green: 1, blue: 0.85, alpha: 1)
                             : CGColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 0.15 + 0.7 * t)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let ch = String(chars[Int(rng.next() * Double(chars.count)) % chars.count])
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: ch, attributes: attributes))
            // В CGContext начало координат внизу: верх струйки — большие y.
            ctx.textPosition = CGPoint(x: 2, y: CGFloat(h - (i + 1) * lineH) + fontSize * 0.3)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    private static func image(_ text: String) -> CGImage? {
        let fontSize: CGFloat = 28
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let w = Int(ceil(width)) + 4, h = Int(ceil(ascent + descent)) + 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textPosition = CGPoint(x: 2, y: descent + 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}

// MARK: - Status line

/// Строка статуса в углу холста: координаты, масштаб, число заметок — как в терминале.
struct TerminalStatus: View {
    let transform: CanvasTransform
    let count: Int

    var body: some View {
        let x = Int(-transform.offset.width / transform.scale)
        let y = Int(-transform.offset.height / transform.scale)
        Text("x:\(x) y:\(y)  \(Int((transform.scale * 100).rounded()))%  [\(count)]")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Term.green.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Term.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.green.opacity(0.2), lineWidth: 1))
            .allowsHitTesting(false)
    }
}
