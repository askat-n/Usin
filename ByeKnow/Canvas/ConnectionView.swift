import SwiftUI

struct ConnectionView: View {
    let geometry: EdgeGeometry
    let connection: Connection
    let selected: Bool
    let scale: CGFloat

    var body: some View {
        let color = connection.colorIndex == 0 ? Color.secondary : Palette.swatch(connection.colorIndex).ink
        let k = max(0.6, min(scale, 1.5))
        let style = StrokeStyle(
            lineWidth: (selected ? 2.6 : 1.8) * k,
            lineCap: .round,
            lineJoin: .round,
            dash: connection.dashed ? [6 * k, 5 * k] : []
        )

        ZStack {
            if selected {
                geometry.path.stroke(Color.accentColor.opacity(0.18), lineWidth: 10 * k)
            }
            geometry.path.stroke(color, style: style)
            switch connection.head {
            case .arrow: geometry.arrowHead(size: 12 * k).fill(color)
            case .dot: geometry.dot(radius: 4 * k).fill(color)
            case .none: EmptyView()
            }
        }
        .contentShape(geometry.path.strokedPath(StrokeStyle(lineWidth: 22, lineCap: .round)))
    }
}

/// Сетка из точек на фоне холста.
struct DotGrid: View {
    let transform: CanvasTransform

    var body: some View {
        Canvas { ctx, size in
            var spacing = 28 * transform.scale
            while spacing < 14 { spacing *= 2 }
            let origin = transform.toScreen(.zero)
            var startX = origin.x.truncatingRemainder(dividingBy: spacing)
            var startY = origin.y.truncatingRemainder(dividingBy: spacing)
            if startX < 0 { startX += spacing }
            if startY < 0 { startY += spacing }

            var path = Path()
            for x in stride(from: startX, through: size.width, by: spacing) {
                for y in stride(from: startY, through: size.height, by: spacing) {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                }
            }
            ctx.fill(path, with: .color(.gridDot))
        }
    }
}
