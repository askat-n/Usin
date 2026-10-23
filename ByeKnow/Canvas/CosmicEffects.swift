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

// MARK: - Background

/// Космический фон: градиент, плывущие туманности, мерцающие звёзды в три слоя
/// (дальние сдвигаются медленнее ближних — глубина при движении холста).
/// Движение и мерцание делает видеокарта (бесконечные анимации слоёв),
/// а процессор перерисовывает звёзды только когда двигаешь холст.
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
        // Медленные движения: 10 кадров в секунду хватает, а процессор почти не занят.
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !animate)) { context in
            let t = animate ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geo in
                let size = geo.size
                let side = max(size.width, size.height)
                ZStack {
                    LinearGradient(colors: [Cosmos.deepTop, Cosmos.deep], startPoint: .top, endPoint: .bottom)

                    ForEach(Self.nebulae.indices, id: \.self) { i in
                        let n = Self.nebulae[i]
                        let r = n.radius * side
                        let k = sin(t * 2 * .pi / (n.duration * 2) + Double(i))
                        Circle()
                            .fill(RadialGradient(colors: [n.color.opacity(0.16), n.color.opacity(0.05), .clear],
                                                 center: .center, startRadius: 0, endRadius: r))
                            .frame(width: r * 2, height: r * 2)
                            .position(x: n.x * size.width + transform.offset.width * 0.03 + n.drift.width * k,
                                      y: n.y * size.height + transform.offset.height * 0.03 + n.drift.height * k)
                    }

                    if showGrid {
                        Canvas { g, size in drawGrid(into: &g, size: size) }
                    }

                    ForEach(Self.starGroups.indices, id: \.self) { i in
                        let group = Self.starGroups[i]
                        let speed = [1.9, 1.3, 2.6][group.group] - group.parallax
                        let twinkle = 0.55 + 0.45 * sin(t * speed + Double(group.group) * 2.1)
                        StarLayer(stars: group.stars, offset: transform.offset, parallax: group.parallax)
                            .equatable()
                            .opacity(twinkle)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(into g: inout GraphicsContext, size: CGSize) {
        var spacing = 120 * transform.scale
        while spacing < 50 { spacing *= 2 }
        let origin = transform.toScreen(.zero)
        var grid = Path()
        var x = origin.x.truncatingRemainder(dividingBy: spacing)
        if x < 0 { x += spacing }
        while x <= size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
        var y = origin.y.truncatingRemainder(dividingBy: spacing)
        if y < 0 { y += spacing }
        while y <= size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
        g.stroke(grid, with: .color(.white.opacity(0.028)), lineWidth: 1)
    }
}

/// Одна группа звёзд одного слоя. Перерисовывается только при сдвиге холста.
private struct StarLayer: View, Equatable {
    let stars: [CosmicBackground.Star]
    let offset: CGSize
    let parallax: Double

    static func == (a: StarLayer, b: StarLayer) -> Bool {
        a.offset == b.offset && a.parallax == b.parallax && a.stars.count == b.stars.count
    }

    var body: some View {
        Canvas { g, size in
            let tile = CosmicBackground.tile
            let shiftX = (offset.width * parallax).truncatingRemainder(dividingBy: tile)
            let shiftY = (offset.height * parallax).truncatingRemainder(dividingBy: tile)
            var path = Path()
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
            g.fill(path, with: .color(.white.opacity(0.85)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Floating

/// Заметка слегка «дышит» и плавает на месте — у каждой свой ритм.
/// Смещение считается от времени (а не бесконечной анимацией), поэтому рамка выделения
/// и всё, что появляется поверх заметки, плывёт вместе с ней.
struct Floating: ViewModifier {
    let seed: UInt64
    let enabled: Bool

    func body(content: Content) -> some View {
        var rng = SeededRandom(seed)
        let ax = 1.5 + rng.next() * 2.5
        let ay = 2.5 + rng.next() * 3.5
        let speed = 2 * Double.pi / (3.2 + rng.next() * 2.6)
        let phase = rng.next() * 2 * Double.pi
        return TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !enabled)) { context in
            let t = enabled ? context.date.timeIntervalSinceReferenceDate : 0
            content.offset(x: enabled ? sin(t * speed * 0.7 + phase) * ax : 0,
                           y: enabled ? cos(t * speed + phase) * ay : 0)
        }
    }
}

// MARK: - Orb (сфера ByeKnow)

/// Живое ядро: переливающийся градиент, пульсирующий ореол и спутник на орбите.
struct CosmicOrb: View {
    let base: Color
    let size: CGFloat
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animate)) { context in
            let t = animate ? context.date.timeIntervalSinceReferenceDate : 0
            let spin = (t * 20).truncatingRemainder(dividingBy: 360)          // 20° в секунду
            let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / 5.6)                    // вдох-выдох ~5,6 с
            orb(spin: spin, pulse: pulse)
        }
        .frame(width: size, height: size)
    }

    private func orb(spin: Double, pulse: Double) -> some View {
        ZStack {
            // Ореол
            Circle()
                .fill(RadialGradient(colors: [base.opacity(0.55), base.opacity(0)], center: .center,
                                     startRadius: size * 0.3, endRadius: size * 0.95))
                .scaleEffect(1 + 0.22 * pulse)
                .opacity(1 - 0.35 * pulse)
                .frame(width: size * 2, height: size * 2)

            // Орбита и спутник
            Circle()
                .stroke(base.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: size + 46, height: size + 46)
                .rotationEffect(.degrees(-spin))
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .shadow(color: .white, radius: 6)
                .shadow(color: Cosmos.cyan, radius: 10)
                .offset(y: -(size + 46) / 2)
                .rotationEffect(.degrees(spin * 1.5))

            // Ядро
            Circle()
                .fill(AngularGradient(colors: [base, Cosmos.violet, Cosmos.cyan, base], center: .center))
                .rotationEffect(.degrees(spin))
                .frame(width: size, height: size)
                .overlay(
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                                 center: UnitPoint(x: 0.32, y: 0.26),
                                                 startRadius: 0, endRadius: size * 0.6))
                )
                .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                                         lineWidth: 1.2))
                .shadow(color: base.opacity(0.8), radius: 24)
        }
    }
}

// MARK: - Flowing light on arrows

/// Огоньки, бегущие по стрелке от начала к концу — как сигнал по нейронам.
struct FlowingLight: Shape {
    var path: Path
    var phase: CGFloat
    var lineWidth: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [1, 22], dashPhase: -phase))
    }
}

struct FlowingEdgeLight: View {
    let path: Path
    let color: Color
    let width: CGFloat
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animate)) { context in
            let t = animate ? context.date.timeIntervalSinceReferenceDate : 0
            FlowingLight(path: path, phase: CGFloat((t * 16).truncatingRemainder(dividingBy: 23)), lineWidth: width)
                .fill(color)
                .shadow(color: color, radius: 4)
        }
    }
}
