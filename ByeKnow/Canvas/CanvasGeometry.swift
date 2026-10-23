import SwiftUI

/// Перевод координат: «мир» холста ↔ экран.
struct CanvasTransform {
    var size: CGSize
    var offset: CGSize
    var scale: CGFloat

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + offset.width + p.x * scale, y: center.y + offset.height + p.y * scale)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x - offset.width) / scale, y: (p.y - center.y - offset.height) / scale)
    }
}

/// Геометрия стрелки на экране.
/// Изгиб хранится как смещение «ручки» от середины между центрами фигур;
/// ручка лежит прямо на кривой, поэтому её удобно тянуть.
struct EdgeGeometry {
    let start: CGPoint
    let end: CGPoint
    let control: CGPoint
    let handle: CGPoint
    let curved: Bool

    init(from a: Node, to b: Node, connection: Connection, transform t: CanvasTransform) {
        let ca = t.toScreen(a.position)
        let cb = t.toScreen(b.position)
        let mid = Self.midpoint(ca, cb)
        let bend = CGPoint(x: connection.bendX * t.scale, y: connection.bendY * t.scale)
        let curved = connection.style == .curved && (bend.x != 0 || bend.y != 0)
        let control = curved ? CGPoint(x: mid.x + 2 * bend.x, y: mid.y + 2 * bend.y) : mid

        self.curved = curved
        self.control = control
        self.handle = curved ? CGPoint(x: mid.x + bend.x, y: mid.y + bend.y) : mid
        self.start = Self.boundary(of: a, center: ca, scale: t.scale, toward: curved ? control : cb, gap: 3)
        self.end = Self.boundary(of: b, center: cb, scale: t.scale, toward: curved ? control : ca,
                                 gap: connection.head == .none ? 3 : 5)
    }

    var path: Path {
        var p = Path()
        p.move(to: start)
        if curved { p.addQuadCurve(to: end, control: control) } else { p.addLine(to: end) }
        return p
    }

    func arrowHead(size: CGFloat) -> Path {
        let from = curved ? control : start
        let angle = atan2(end.y - from.y, end.x - from.x)
        let spread: CGFloat = 0.45
        var p = Path()
        p.move(to: end)
        p.addLine(to: CGPoint(x: end.x - size * cos(angle - spread), y: end.y - size * sin(angle - spread)))
        p.addLine(to: CGPoint(x: end.x - size * cos(angle + spread), y: end.y - size * sin(angle + spread)))
        p.closeSubpath()
        return p
    }

    func dot(radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2))
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Точка на краю фигуры в направлении `target`.
    static func boundary(of node: Node, center c: CGPoint, scale: CGFloat, toward target: CGPoint, gap: CGFloat) -> CGPoint {
        let dx = target.x - c.x, dy = target.y - c.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return c }
        let ux = dx / len, uy = dy / len
        let w = node.size.width * scale / 2
        let h = node.size.height * scale / 2
        let k: CGFloat
        if node.isRoot || node.shape == .circle {
            k = w
        } else {
            let kx = abs(ux) > 0.0001 ? w / abs(ux) : .infinity
            let ky = abs(uy) > 0.0001 ? h / abs(uy) : .infinity
            k = min(kx, ky)
        }
        let d = min(k + gap, len)
        return CGPoint(x: c.x + ux * d, y: c.y + uy * d)
    }
}
