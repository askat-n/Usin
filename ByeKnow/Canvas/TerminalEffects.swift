import SwiftUI
import QuartzCore

// MARK: - Palette

/// Стиль «Терминал»: чёрный экран, зелёный люминофор, моноширинный шрифт.
enum Term {
    static let bg = Color(hex: 0x030603)
    static let panel = Color(hex: 0x070C07)
    static let green = Color(hex: 0x4ADE80)
    static let dim = Color(hex: 0x4ADE80).opacity(0.35)

    /// Цвет рамки заметки: свой цвет заметки (как цвета в терминале) или зелёный.
    static func ink(_ index: Int) -> Color { index == 0 ? green : Palette.swatch(index).ink }

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
        sweep.position = CGPoint(x: size.width / 2, y: -band)
        sweep.isHidden = !animate
        sweep.removeAnimation(forKey: "sweep") // высота экрана могла измениться
        if animate {
            let a = basic("position.y", from: -band, to: size.height + band, duration: 7, autoreverses: false, timing: .linear)
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            sweep.add(a, forKey: "sweep")
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
                a.values = [1, 0]
                a.keyTimes = [0, 0.5]
                a.calculationMode = .discrete
                a.duration = 1.06
                return a
            }
        }
        .allowsHitTesting(false)
    }
}
