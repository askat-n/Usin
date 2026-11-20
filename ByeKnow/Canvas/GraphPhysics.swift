import SwiftUI

/// Живой граф: заметки плавают вокруг места, где их поставили, связаны «пружинками»-стрелками
/// и расталкивают друг друга. Тянешь заметку — соседи по стрелкам тянутся за ней,
/// отпускаешь — всё мягко пружинит обратно.
///
/// Физика своя (простые пружины с затуханием), ничего в базе не меняет:
/// смещение от физики добавляется только при отрисовке. Обычный класс, не @Observable —
/// шаг считается прямо в часах холста, лишних перерисовок нет.
final class GraphPhysics {
    struct Body {
        var offset: CGPoint = .zero      // смещение от места заметки (в мире холста)
        var velocity: CGPoint = .zero
        var lastAnchor: CGPoint?
    }

    private var bodies: [UUID: Body] = [:]
    private var lastTime: Double?

    // Настройка «характера» движения
    private let stiffness: Double = 7        // как сильно тянет к своему месту
    private let damping: Double = 2.2        // затухание — чем меньше, тем «желейнее»
    private let wanderAmplitude: Double = 16 // насколько далеко плавает сама по себе
    private let linkPull: Double = 0.45      // какую долю движения передаёт соседу стрелка
    private let linkPull2: Double = 0.15     // и соседу соседа
    private let repelStrength: Double = 60   // как сильно расталкиваются слишком близкие заметки
    private let maxOffset: Double = 160

    /// Сдвинуть физику на текущий момент. Возвращает смещения для отрисовки.
    func step(time: Double, nodes: [GraphNode], links: [(UUID, UUID)], held: UUID?) -> Drift {
        let dt = min(max(time - (lastTime ?? time), 0), 1.0 / 20)
        lastTime = time

        // Соседи по стрелкам
        var neighbors: [UUID: [UUID]] = [:]
        for (a, b) in links {
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }

        var alive = Set<UUID>()
        var force: [UUID: CGPoint] = [:]

        // 1. Перетаскивание: место заметки сдвинулось — соседей «дёргает» следом.
        for node in nodes {
            alive.insert(node.id)
            var b = bodies[node.id] ?? Body()
            let anchor = node.position
            if let last = b.lastAnchor {
                let delta = CGPoint(x: anchor.x - last.x, y: anchor.y - last.y)
                if delta.x != 0 || delta.y != 0, hypot(delta.x, delta.y) < 400 {
                    // Пока тянут саму заметку, она остаётся под пальцем; тянутся соседи.
                    for n in neighbors[node.id] ?? [] {
                        nudge(n, by: delta, k: linkPull)
                        for n2 in neighbors[n] ?? [] where n2 != node.id {
                            nudge(n2, by: delta, k: linkPull2)
                        }
                    }
                }
            }
            b.lastAnchor = anchor
            bodies[node.id] = bodies[node.id].map { var x = $0; x.lastAnchor = anchor; return x } ?? b
        }
        bodies = bodies.filter { alive.contains($0.key) }

        // 2. Расталкивание: заметки не налезают друг на друга.
        let placed = nodes.map { n -> (GraphNode, CGPoint, Double) in
            let o = bodies[n.id]?.offset ?? .zero
            let r = Double(max(n.size.width, n.size.height)) * 0.5
            return (n, CGPoint(x: n.position.x + o.x, y: n.position.y + o.y), r)
        }
        if placed.count > 1 {
            for i in 0..<(placed.count - 1) {
                for j in (i + 1)..<placed.count {
                    let (a, pa, ra) = placed[i]
                    let (b, pb, rb) = placed[j]
                    var dx = pb.x - pa.x, dy = pb.y - pa.y
                    let minDist = (ra + rb) * 0.85
                    if abs(dx) > minDist || abs(dy) > minDist { continue }
                    var dist = hypot(dx, dy)
                    if dist < 0.01 { dx = 1; dy = 0; dist = 1 }
                    guard dist < minDist else { continue }
                    let push = repelStrength * (minDist - dist) / minDist
                    let fx = dx / dist * push, fy = dy / dist * push
                    force[a.id, default: .zero].x -= fx
                    force[a.id, default: .zero].y -= fy
                    force[b.id, default: .zero].x += fx
                    force[b.id, default: .zero].y += fy
                }
            }
        }

        // 3. Пружина к «блуждающей» цели + затухание.
        var result: [UUID: CGPoint] = [:]
        var restless = false
        for node in nodes {
            guard var b = bodies[node.id] else { continue }
            if node.id == held {
                // Заметку держат — она точно под пальцем, без колебаний.
                b.offset = CGPoint(x: b.offset.x * 0.8, y: b.offset.y * 0.8)
                b.velocity = .zero
            } else if dt > 0 {
                let target = wander(node, time: time)
                let f = force[node.id] ?? .zero
                let ax = stiffness * (target.x - b.offset.x) - damping * b.velocity.x + f.x
                let ay = stiffness * (target.y - b.offset.y) - damping * b.velocity.y + f.y
                b.velocity.x += ax * dt
                b.velocity.y += ay * dt
                b.offset.x += b.velocity.x * dt
                b.offset.y += b.velocity.y * dt
                let len = hypot(b.offset.x, b.offset.y)
                if len > maxOffset {
                    b.offset.x *= maxOffset / len
                    b.offset.y *= maxOffset / len
                }
            }
            bodies[node.id] = b
            result[node.id] = b.offset
            // Спокойное плавание — около 10 точек в секунду; быстрее — значит, граф пружинит после рывка.
            if abs(b.velocity.x) > 30 || abs(b.velocity.y) > 30 { restless = true }
        }
        return Drift(offsets: result, restless: restless)
    }

    /// Мягко вернуть всё на место (когда плавание выключили).
    func reset() {
        bodies.removeAll()
        lastTime = nil
    }

    private func nudge(_ id: UUID, by delta: CGPoint, k: Double) {
        guard var b = bodies[id] else { return }
        b.offset.x += delta.x * k
        b.offset.y += delta.y * k
        // Немного скорости — чтобы после рывка сосед «доехал» и качнулся обратно.
        b.velocity.x += delta.x * k * 6
        b.velocity.y += delta.y * k * 6
        bodies[id] = b
    }

    /// Плавная «восьмёрка» у каждой заметки своя: свой темп и фаза.
    private func wander(_ node: GraphNode, time: Double) -> CGPoint {
        let s = node.id.seed
        let p1 = Double(s & 0xFFFF) / 65535 * .pi * 2
        let p2 = Double((s >> 16) & 0xFFFF) / 65535 * .pi * 2
        let f = 0.7 + Double((s >> 32) & 0xFF) / 255 * 0.6
        let a = node.isRoot ? wanderAmplitude * 0.45 : wanderAmplitude
        let w = 2 * Double.pi / 9 * f
        return CGPoint(
            x: a * (0.7 * sin(time * w + p1) + 0.3 * sin(time * w * 2.13 + p2)),
            y: a * (0.7 * cos(time * w * 0.87 + p2) + 0.3 * sin(time * w * 1.61 + p1))
        )
    }
}

/// Смещения заметок от физики на этот кадр (пусто — всё стоит на своих местах).
struct Drift {
    var offsets: [UUID: CGPoint] = [:]
    /// Граф пружинит после рывка — нужна полная частота кадров.
    var restless = false

    static let none = Drift()

    func offset(_ node: Node) -> CGPoint { offsets[node.id] ?? .zero }
    func offset(_ id: UUID) -> CGPoint { offsets[id] ?? .zero }
}
