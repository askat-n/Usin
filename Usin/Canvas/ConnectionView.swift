import SwiftUI

struct ConnectionView: View {
    let geometry: EdgeGeometry
    let connection: Connection
    let selected: Bool
    let scale: CGFloat
    var cosmos = false
    var terminal = false

    var body: some View {
        let k = max(0.6, min(scale, 1.5))
        let color: Color = {
            if connection.colorIndex != 0 { return Palette.swatch(connection.colorIndex).ink }
            if terminal { return Term.green }
            return cosmos ? Cosmos.defaultGlow : .secondary
        }()
        let style = StrokeStyle(
            lineWidth: (selected ? 2.2 : (terminal ? 1 : (cosmos ? 1.4 : 1.8))) * k,
            lineCap: terminal ? .butt : .round,
            lineJoin: .round,
            dash: connection.dashed ? [6 * k, 5 * k] : []
        )

        ZStack {
            if cosmos {
                // Мягкое свечение вокруг линии — два широких полупрозрачных штриха (без размытия, оно дорогое).
                geometry.path.stroke(color.opacity(selected ? 0.18 : 0.08), style: StrokeStyle(lineWidth: 10 * k, lineCap: .round))
                geometry.path.stroke(color.opacity(selected ? 0.3 : 0.15), style: StrokeStyle(lineWidth: 5 * k, lineCap: .round))
            } else if selected {
                geometry.path.stroke((terminal ? Term.green : Color.accentColor).opacity(0.18), lineWidth: 10 * k)
            }
            geometry.path.stroke(terminal ? color.opacity(0.6) : (cosmos ? color.opacity(0.75) : color), style: style)
            switch connection.head {
            case .arrow:
                geometry.arrowHead(size: (terminal ? 9 : 12) * k).fill(color)
            case .dot:
                geometry.dot(radius: 4 * k).fill(color)
            case .none:
                EmptyView()
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
