import SwiftUI

// MARK: - Palette

enum Cosmos {
    static let deep = Color(hex: 0x04060C)
    static let deepTop = Color(hex: 0x0A1022)
    static let glass = Color(hex: 0x0D1322)
    /// Свечение заметок «по умолчанию» (без своего цвета).
    static let defaultGlow = Color(hex: 0x8AA2FF)
    static let cyan = Color(hex: 0x22D3EE)
    static let violet = Color(hex: 0x8B5CF6)
}

/// Повторяемые «случайные» числа — звёзды и ритмы не прыгают между запусками.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

extension UUID {
    var seed: UInt64 {
        withUnsafeBytes(of: uuid) { $0.load(as: UInt64.self) }
    }
}

// MARK: - Panels

extension View {
    /// Фон плавающих панелей. В «Космосе» — плотная тёмная капсула: живое стекло над
    /// движущимся фоном пришлось бы перерисовывать каждый кадр. В классическом — стекло.
    @ViewBuilder
    func panelBackground() -> some View {
        if AppSettings.shared.isTerminal {
            self
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Term.panel.opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Term.green.opacity(0.35), lineWidth: 1))
        } else if AppSettings.shared.isCosmos {
            self
                .background(Capsule().fill(Color(hex: 0x131A2C).opacity(0.95)))
                .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        } else {
            self.glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Background

/// Космический фон на Core Animation: градиент, плывущие туманности,
/// мерцающие звёзды в три слоя с параллаксом и тонкая сетка.
/// Анимации крутит система; при сдвиге холста пересчитываются только пути звёзд и сетки.
struct CosmicBackground: View {
    let transform: CanvasTransform
    let animate: Bool
    let showGrid: Bool

    struct Star { let x, y, size: Double }
    private struct Nebula { let x, y, radius: Double; let drift: CGSize; let duration: Double; let color: Color }

    static let tile: Double = 700
    /// 3 слоя глубины × 3 группы мерцания.
    static let starGroups: [(parallax: Double, group: Int, stars: [Star])] = {
        var rng = SeededRandom(42)
        var result: [(Double, Int, [Star])] = []
        for (parallax, count, sizes) in [(0.04, 72, 0.6...1.2), (0.12, 45, 0.9...1.6), (0.28, 24, 1.3...2.2)] {
            var groups: [[Star]] = [[], [], []]
            for i in 0..<count {
                groups[i % 3].append(Star(x: rng.next() * tile, y: rng.next() * tile,
                                          size: sizes.lowerBound + rng.next() * (sizes.upperBound - sizes.lowerBound)))
            }
            for (g, stars) in groups.enumerated() { result.append((parallax, g, stars)) }
        }
        return result
    }()

    private static let nebulae: [Nebula] = [
        Nebula(x: 0.18, y: 0.22, radius: 0.55, drift: CGSize(width: 70, height: 40), duration: 23, color: Cosmos.violet),
        Nebula(x: 0.85, y: 0.30, radius: 0.45, drift: CGSize(width: -60, height: 50), duration: 29, color: Cosmos.cyan),
        Nebula(x: 0.55, y: 0.85, radius: 0.60, drift: CGSize(width: 50, height: -45), duration: 31, color: Color(hex: 0x3B5BFF)),
        Nebula(x: 0.10, y: 0.90, radius: 0.35, drift: CGSize(width: 40, height: -60), duration: 19, color: Color(hex: 0xD946EF)),
    ]

    var body: some View {
        LayerHost { root, size, scale, env in
            render(root, size: size, scale: scale, env: env)
        }
        .allowsHitTesting(false)
    }

    private func render(_ root: CALayer, size: CGSize, scale: CGFloat, env: EnvironmentValues) {
        let bounds = CGRect(origin: .zero, size: size)

        let bg = root.sublayer("bg", scale: scale) { CAGradientLayer() }
        bg.frame = bounds
        bg.colors = [Cosmos.deepTop.cg(env), Cosmos.deep.cg(env)]

        // Туманности
        let nebulaHost = root.sublayer("nebulae", scale: scale) { CALayer() }
        nebulaHost.frame = bounds
        nebulaHost.setAffineTransform(CGAffineTransform(translationX: transform.offset.width * 0.03,
                                                        y: transform.offset.height * 0.03))
        let side = max(size.width, size.height)
        for (i, n) in Self.nebulae.enumerated() {
            let layer = nebulaHost.sublayer("n\(i)", scale: scale) { CAGradientLayer() }
            let r = n.radius * side
            layer.type = .radial
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            layer.colors = [n.color.opacity(0.16).cg(env), n.color.opacity(0.05).cg(env), Color.clear.cg(env)]
            layer.locations = [0, 0.45, 1]
            layer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            layer.position = CGPoint(x: n.x * size.width, y: n.y * size.height)
            layer.loop("dx", enabled: animate) {
                basic("transform.translation.x", from: 0, to: n.drift.width, duration: n.duration)
            }
            layer.loop("dy", enabled: animate) {
                basic("transform.translation.y", from: 0, to: n.drift.height, duration: n.duration * 0.83)
            }
        }

        // Сетка
        let grid = root.sublayer("grid", scale: scale) { CAShapeLayer() }
        grid.frame = bounds
        grid.isHidden = !showGrid
        grid.fillColor = nil
        grid.strokeColor = Color.white.opacity(0.028).cg(env)
        grid.lineWidth = 1
        if showGrid { grid.path = gridPath(size: size) }

        // Звёзды
        for (i, group) in Self.starGroups.enumerated() {
            let layer = root.sublayer("s\(i)", scale: scale) { CAShapeLayer() }
            layer.frame = bounds
            layer.fillColor = Color.white.opacity(0.85).cg(env)
            layer.path = starPath(group.stars, parallax: group.parallax, size: size)
            let low = [0.35, 0.4, 0.5][group.group]
            layer.loop("twinkle", enabled: animate) {
                basic("opacity", from: 1, to: low, duration: [2.3, 3.1, 1.7][group.group] + group.parallax * 4)
            }
        }
    }

    private func gridPath(size: CGSize) -> CGPath {
        var spacing = 120 * transform.scale
        while spacing < 50 { spacing *= 2 }
        let origin = transform.toScreen(.zero)
        let path = CGMutablePath()
        var x = origin.x.truncatingRemainder(dividingBy: spacing)
        if x < 0 { x += spacing }
        while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
        var y = origin.y.truncatingRemainder(dividingBy: spacing)
        if y < 0 { y += spacing }
        while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
        return path
    }

    private func starPath(_ stars: [Star], parallax: Double, size: CGSize) -> CGPath {
        let tile = Self.tile
        let shiftX = (transform.offset.width * parallax).truncatingRemainder(dividingBy: tile)
        let shiftY = (transform.offset.height * parallax).truncatingRemainder(dividingBy: tile)
        let path = CGMutablePath()
        for star in stars {
            var sx = star.x + shiftX
            while sx < 0 { sx += tile }
            while sx < size.width + tile {
                var sy = star.y + shiftY
                while sy < 0 { sy += tile }
                while sy < size.height + tile {
                    if sx <= size.width + 4, sy <= size.height + 4 {
                        path.addEllipse(in: CGRect(x: sx - star.size / 2, y: sy - star.size / 2,
                                                   width: star.size, height: star.size))
                    }
                    sy += tile
                }
                sx += tile
            }
        }
        return path
    }
}

// MARK: - Orb (сфера Usin)

/// Живое ядро на Core Animation: переливающийся градиент, пульсирующий ореол, спутник на орбите.
/// Рисуется в координатах экрана под заметкой-сферой.
struct CosmicOrb: View {
    let center: CGPoint
    /// Диаметр на экране.
    let diameter: CGFloat
    /// Масштаб холста (толщина орбиты, размер спутника).
    let scale: CGFloat
    let base: Color
    let animate: Bool

    var body: some View {
        LayerHost { root, _, contentsScale, env in
            render(root, contentsScale: contentsScale, env: env)
        }
        .allowsHitTesting(false)
    }

    private func render(_ root: CALayer, contentsScale: CGFloat, env: EnvironmentValues) {
        let d = diameter
        let k = scale
        let box = root.sublayer("orb", scale: contentsScale) { CALayer() }
        box.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        box.position = center
        let mid = CGPoint(x: d / 2, y: d / 2)
        let baseCG = base.cg(env)

        // Ореол
        let halo = box.sublayer("halo", scale: contentsScale) { CAGradientLayer() }
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.colors = [base.opacity(0.55).cg(env), base.opacity(0.55).cg(env), base.opacity(0).cg(env)]
        halo.locations = [0, 0.3, 0.95]
        halo.bounds = CGRect(x: 0, y: 0, width: d * 2, height: d * 2)
        halo.position = mid
        halo.loop("pulse", enabled: animate) { basic("transform.scale", from: 1, to: 1.22, duration: 2.8) }
        halo.loop("fade", enabled: animate) { basic("opacity", from: 1, to: 0.65, duration: 2.8) }

        // Свечение ядра
        let glow = box.sublayer("glow", scale: contentsScale) { CAShapeLayer() }
        glow.frame = box.bounds
        glow.path = CGPath(ellipseIn: box.bounds, transform: nil)
        glow.fillColor = baseCG
        glow.shadowColor = baseCG
        glow.shadowOpacity = 0.8
        glow.shadowRadius = 24 * k
        glow.shadowOffset = .zero
        glow.shadowPath = glow.path

        // Орбита
        let orbitD = d + 46 * k
        let orbit = box.sublayer("orbit", scale: contentsScale) { CAShapeLayer() }
        orbit.bounds = CGRect(x: 0, y: 0, width: orbitD, height: orbitD)
        orbit.position = mid
        orbit.path = CGPath(ellipseIn: orbit.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        orbit.fillColor = nil
        orbit.strokeColor = base.opacity(0.35).cg(env)
        orbit.lineWidth = 1
        orbit.lineDashPattern = [NSNumber(value: Double(2 * k)), NSNumber(value: Double(7 * k))]
        orbit.loop("spin", enabled: animate) {
            basic("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 18, autoreverses: false, timing: .linear)
        }

        // Спутник
        let carrier = box.sublayer("carrier", scale: contentsScale) { CALayer() }
        carrier.bounds = orbit.bounds
        carrier.position = mid
        carrier.loop("spin", enabled: animate) {
            basic("transform.rotation.z", from: 0, to: 2 * Double.pi, duration: 12, autoreverses: false, timing: .linear)
        }
        let sat = carrier.sublayer("sat", scale: contentsScale) { CALayer() }
        let satD = max(4, 6 * k)
        sat.bounds = CGRect(x: 0, y: 0, width: satD, height: satD)
        sat.position = CGPoint(x: orbitD / 2, y: 0)
        sat.cornerRadius = satD / 2
        sat.backgroundColor = Color.white.cg(env)
        sat.shadowColor = Cosmos.cyan.cg(env)
        sat.shadowOpacity = 1
        sat.shadowRadius = 8 * k
        sat.shadowOffset = .zero

        // Ядро
        let core = box.sublayer("core", scale: contentsScale) { CAGradientLayer() }
        core.type = .conic
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 0.5, y: 0)
        core.colors = [baseCG, Cosmos.violet.cg(env), Cosmos.cyan.cg(env), baseCG]
        core.frame = box.bounds
        core.cornerRadius = d / 2
        core.masksToBounds = true
        core.loop("spin", enabled: animate) {
            basic("transform.rotation.z", from: 0, to: 2 * Double.pi, duration: 18, autoreverses: false, timing: .linear)
        }

        // Блик и кромка
        let shine = box.sublayer("shine", scale: contentsScale) { CAGradientLayer() }
        shine.type = .radial
        shine.startPoint = CGPoint(x: 0.32, y: 0.26)
        shine.endPoint = CGPoint(x: 0.92, y: 0.86)
        shine.colors = [Color.white.opacity(0.55).cg(env), Color.white.opacity(0).cg(env)]
        shine.frame = box.bounds
        shine.cornerRadius = d / 2
        shine.masksToBounds = true

        let rim = box.sublayer("rim", scale: contentsScale) { CAShapeLayer() }
        rim.frame = box.bounds
        rim.path = CGPath(ellipseIn: box.bounds.insetBy(dx: 0.6, dy: 0.6), transform: nil)
        rim.fillColor = nil
        rim.strokeColor = Color.white.opacity(0.4).cg(env)
        rim.lineWidth = 1.2
    }
}

// MARK: - Flowing light on arrows + breathing glow of notes

/// Огоньки, бегущие по стрелкам (как сигнал по нейронам), и «дыхание» свечения заметок.
/// Один слой на весь холст, в координатах экрана.
struct CosmicFlows: View {
    struct Edge { let id: UUID; let path: Path; let width: CGFloat; let opacity: Float }
    struct Glow { let id: UUID; let path: Path; let color: Color; let radius: CGFloat; let opacity: Float; let seed: UInt64 }

    let edges: [Edge]
    let glows: [Glow]
    let animate: Bool

    var body: some View {
        LayerHost { root, size, scale, env in
            render(root, size: size, scale: scale, env: env)
        }
        .allowsHitTesting(false)
    }

    private func render(_ root: CALayer, size: CGSize, scale: CGFloat, env: EnvironmentValues) {
        let bounds = CGRect(origin: .zero, size: size)

        // Свечение заметок — под стеклом заметок (сами заметки рисует SwiftUI поверх).
        let glowHost = root.sublayer("glows", scale: scale) { CALayer() }
        glowHost.frame = bounds
        var keepGlows = Set<String>()
        for g in glows {
            let name = g.id.uuidString
            keepGlows.insert(name)
            let layer = glowHost.sublayer(name, scale: scale) { CAShapeLayer() }
            layer.frame = bounds
            let cg = g.path.cgPath
            layer.path = cg
            layer.fillColor = Cosmos.glass.cg(env)
            layer.shadowColor = g.color.cg(env)
            layer.shadowRadius = g.radius
            layer.shadowOffset = .zero
            layer.shadowPath = cg
            layer.shadowOpacity = 0.3
            layer.opacity = g.opacity
            var rng = SeededRandom(g.seed)
            let duration = 2.6 + rng.next() * 2.2
            let delay = -rng.next() * duration
            layer.loop("breathe", enabled: animate) {
                basic("shadowOpacity", from: 0.22, to: 0.7, duration: duration, begin: delay)
            }
        }
        glowHost.removeSublayers(except: keepGlows)

        // Огоньки на стрелках
        let flowHost = root.sublayer("flows", scale: scale) { CALayer() }
        flowHost.frame = bounds
        var keepFlows = Set<String>()
        for e in edges {
            let name = e.id.uuidString
            keepFlows.insert(name)
            let layer = flowHost.sublayer(name, scale: scale) { CAShapeLayer() }
            layer.frame = bounds
            layer.path = e.path.cgPath
            layer.fillColor = nil
            layer.strokeColor = Color.white.cg(env)
            layer.lineWidth = e.width
            layer.lineCap = .round
            layer.lineDashPattern = [1, 22]
            layer.opacity = e.opacity
            layer.isHidden = !animate
            layer.loop("flow", enabled: animate) {
                basic("lineDashPhase", from: 0, to: -23, duration: 1.4, autoreverses: false, timing: .linear)
            }
        }
        flowHost.removeSublayers(except: keepFlows)
    }
}
