import SwiftUI
import SwiftData

struct CanvasView: View {
    @Environment(Workspace.self) private var ws
    @Query(sort: \Node.createdAt) private var nodes: [Node]
    @Query(sort: \Connection.createdAt) private var connections: [Connection]

    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: (scale: CGFloat, offset: CGSize)?
    @State private var dragOrigin: (id: UUID, position: CGPoint)?
    @State private var linkDraft: (from: UUID, point: CGPoint)?
    @State private var press: HoldPress?
    @State private var holdTask: Task<Void, Never>?
    @State private var createdCount = 0
    @State private var pressedNodeID: UUID?
    @State private var lastTap: (id: UUID, time: Date)?

    /// Сколько секунд держать палец: на пустом месте — новая заметка, на заметке — переименовать.
    static let holdDuration: Double = 1.25

    struct HoldPress {
        let id = UUID()
        var location: CGPoint
        var moved = false
        var fired = false
    }

    var body: some View {
        GeometryReader { geo in
            let t = CanvasTransform(size: geo.size, offset: ws.offset, scale: ws.scale)
            let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            ZStack {
                background(t)

                ForEach(connections) { c in
                    if let a = byID[c.fromID], let b = byID[c.toID] {
                        ConnectionView(
                            geometry: EdgeGeometry(from: a, to: b, connection: c, transform: t),
                            connection: c,
                            selected: ws.selection == .connection(c.id),
                            scale: t.scale
                        )
                        .opacity(isDimmed(a) || isDimmed(b) ? 0.12 : 1)
                        .onTapGesture { ws.select(.connection(c.id)) }
                    }
                }

                if let draft = linkDraft, let a = byID[draft.from] {
                    Path { p in
                        p.move(to: t.toScreen(a.position))
                        p.addLine(to: draft.point)
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                    .allowsHitTesting(false)
                }

                ForEach(nodes) { node in
                    nodeView(node, t)
                }

                if let p = press, !p.moved, !p.fired {
                    HoldRing(duration: Self.holdDuration)
                        .id(p.id)
                        .position(p.location)
                        .allowsHitTesting(false)
                }

                if case .node(let id) = ws.selection, ws.editingTitleID != id, let n = byID[id] {
                    linkHandle(n, t)
                }

                if case .connection(let id) = ws.selection,
                   let c = connections.first(where: { $0.id == id }),
                   let a = byID[c.fromID], let b = byID[c.toID] {
                    bendHandle(c, a, b, t)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named("canvas"))
            .simultaneousGesture(magnify(t))
            .clipped()
            .sensoryFeedback(.impact, trigger: createdCount)
            .onAppear {
                ws.canvasSize = geo.size
                ws.canvasFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size) { _, size in
                ws.canvasSize = size
                ws.canvasFrame = geo.frame(in: .global)
            }
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .top) {
            FilterBar().padding(.top, 10)
        }
        .overlay(alignment: .trailing) {
            ZoomControls().padding(.trailing, 12)
        }
        .overlay(alignment: .bottom) {
            inspector.padding(.bottom, 16).padding(.horizontal, 12)
        }
        #if os(macOS)
        .modifier(ScrollWheelPan(ws: ws))
        #endif
    }

    // MARK: - Background

    /// Фон холста: потянул — двигаешь холст, коснулся — снял выделение,
    /// удержал палец на месте `holdDuration` секунд — новая заметка.
    private func background(_ t: CanvasTransform) -> some View {
        Color.canvas
            .overlay { DotGrid(transform: t).allowsHitTesting(false) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        cancelHold()
                        let origin = panOrigin ?? ws.offset
                        panOrigin = origin
                        ws.offset = CGSize(width: origin.width + v.translation.width,
                                           height: origin.height + v.translation.height)
                    }
                    .onEnded { _ in panOrigin = nil }
            )
            .onTapGesture { ws.select(.empty) }
            // Сырые касания приходят сразу, даже если палец не двигается.
            .simultaneousGesture(
                SpatialEventGesture()
                    .onChanged { events in
                        guard events.count == 1, let e = events.first, e.phase == .active else {
                            cancelHold()
                            return
                        }
                        if press == nil {
                            press = HoldPress(location: e.location)
                            startHoldTimer(t)
                        } else if let p = press,
                                  hypot(e.location.x - p.location.x, e.location.y - p.location.y) > 6 {
                            cancelHold()
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        press = nil
                    }
            )
    }

    private func startHoldTimer(_ t: CanvasTransform) {
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled, let p = press, !p.moved else { return }
            press?.fired = true
            ws.createNode(at: t.toWorld(p.location))
            createdCount += 1
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        press?.moved = true
    }

    // MARK: - Nodes

    private func isDimmed(_ node: Node) -> Bool {
        guard let filter = ws.filterThemeID, !node.isRoot else { return false }
        return node.theme?.id != filter
    }

    private func nodeView(_ node: Node, _ t: CanvasTransform) -> some View {
        let editing = ws.editingTitleID == node.id
        return NodeView(
            node: node,
            selected: ws.selection == .node(node.id),
            isOpen: ws.openTabs.contains(node.id),
            editing: editing,
            onEndEditing: { ws.editingTitleID = nil }
        )
        .overlay {
            if pressedNodeID == node.id {
                HoldRing(duration: Self.holdDuration).allowsHitTesting(false)
            }
        }
        .scaleEffect(t.scale)
        .opacity(isDimmed(node) ? 0.15 : 1)
        .position(t.toScreen(node.position))
        .gesture(nodeDrag(node), isEnabled: !editing)
        // Порядок важен: сначала касания, потом удержание — иначе удержание глушит касания.
        // Двойное касание считаем сами: так одно касание выделяет сразу, без ожидания второго.
        .onTapGesture {
            guard !editing else { return }
            let now = Date()
            if let last = lastTap, last.id == node.id, now.timeIntervalSince(last.time) < 0.35 {
                lastTap = nil
                if node.isRoot { ws.startRenaming(node) } else { ws.open(node) }
            } else {
                lastTap = (node.id, now)
                ws.select(.node(node.id))
            }
        }
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 6) {
            guard !editing else { return }
            ws.startRenaming(node)
            createdCount += 1
        } onPressingChanged: { pressing in
            pressedNodeID = pressing && !editing ? node.id : nil
        }
    }

    private func nodeDrag(_ node: Node) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if dragOrigin?.id != node.id {
                    dragOrigin = (node.id, node.position)
                    ws.select(.node(node.id))
                }
                guard let origin = dragOrigin else { return }
                node.x = origin.position.x + v.translation.width / ws.scale
                node.y = origin.position.y + v.translation.height / ws.scale
            }
            .onEnded { _ in dragOrigin = nil }
    }

    // MARK: - Arrows

    /// Кнопка «+» справа от выбранной фигуры: тянешь — стрелка, нажал — новая связанная заметка.
    private func linkHandle(_ node: Node, _ t: CanvasTransform) -> some View {
        let edge = t.toScreen(CGPoint(x: node.x + node.size.width / 2, y: node.y))
        return Image(systemName: "plus")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .contentShape(Circle().inset(by: -10))
            .position(x: edge.x + 22, y: edge.y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { v in linkDraft = (node.id, v.location) }
                    .onEnded { v in
                        linkDraft = nil
                        let moved = hypot(v.translation.width, v.translation.height) > 12
                        finishLink(from: node, at: v.location, moved: moved, t)
                    }
            )
            .help("Тяни к другой фигуре — стрелка. Нажми — новая связанная заметка")
    }

    private func finishLink(from source: Node, at point: CGPoint, moved: Bool, _ t: CanvasTransform) {
        let inheritedTheme = source.isRoot ? nil : source.theme
        guard moved else {
            let p = CGPoint(x: source.x + source.size.width / 2 + 190, y: source.y + .random(in: -40...40))
            let new = ws.createNode(at: p, theme: inheritedTheme)
            ws.connect(from: source.id, to: new.id)
            return
        }
        let world = t.toWorld(point)
        if let target = nodes.last(where: { $0.id != source.id && $0.contains(world) }) {
            ws.connect(from: source.id, to: target.id)
        } else {
            let new = ws.createNode(at: world, theme: inheritedTheme)
            ws.connect(from: source.id, to: new.id)
        }
    }

    /// Точка посередине выбранной стрелки — тянешь, и стрелка изгибается.
    private func bendHandle(_ c: Connection, _ a: Node, _ b: Node, _ t: CanvasTransform) -> some View {
        let g = EdgeGeometry(from: a, to: b, connection: c, transform: t)
        return Circle()
            .fill(Color.editor)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -12))
            .position(g.handle)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        let mid = EdgeGeometry.midpoint(t.toScreen(a.position), t.toScreen(b.position))
                        c.bendX = (v.location.x - mid.x) / t.scale
                        c.bendY = (v.location.y - mid.y) / t.scale
                        c.style = .curved
                    }
            )
            .onTapGesture(count: 2) {
                c.bendX = 0
                c.bendY = 0
                c.style = .straight
            }
            .help("Тяни, чтобы изогнуть. Двойной тап — выпрямить")
    }

    // MARK: - Zoom

    private func magnify(_ t: CanvasTransform) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { v in
                if zoomOrigin == nil { cancelHold() }
                let origin = zoomOrigin ?? (ws.scale, ws.offset)
                zoomOrigin = origin
                let s = min(max(origin.scale * v.magnification, Workspace.minScale), Workspace.maxScale)
                let a = v.startLocation
                let c = t.center
                let wx = (a.x - c.x - origin.offset.width) / origin.scale
                let wy = (a.y - c.y - origin.offset.height) / origin.scale
                ws.offset = CGSize(width: a.x - c.x - wx * s, height: a.y - c.y - wy * s)
                ws.scale = s
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    // MARK: - Bottom panel

    @ViewBuilder
    private var inspector: some View {
        switch ws.selection {
        case .node(let id):
            if let node = nodes.first(where: { $0.id == id }) {
                NodeInspector(node: node)
            }
        case .connection(let id):
            if let c = connections.first(where: { $0.id == id }) {
                ConnectionInspector(connection: c)
            }
        case .empty:
            if nodes.count <= 1 {
                Text("Удержи палец на пустом месте — появится заметка")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }
}

/// Кольцо, которое заполняется, пока держишь палец на пустом месте.
private struct HoldRing: View {
    let duration: Double
    @State private var progress: CGFloat = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 56, height: 56)
        .opacity(visible ? 1 : 0)
        .task {
            // Короткое касание не показывает кольцо.
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
            withAnimation(.linear(duration: duration - 0.25)) { progress = 1 }
        }
    }
}

#if os(macOS)
/// Mac: прокрутка двумя пальцами двигает холст, ⌘ + прокрутка — масштаб.
private struct ScrollWheelPan: ViewModifier {
    let ws: Workspace
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [ws] event in
                    Self.handle(event, ws: ws)
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private static func handle(_ event: NSEvent, ws: Workspace) -> NSEvent? {
        guard ws.activeTab == nil,
              let window = event.window, window.styleMask.contains(.titled),
              let content = window.contentView else { return event }
        let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        // Верхняя полоса с фильтром остаётся прокручиваемой.
        guard ws.canvasFrame.contains(p), p.y > ws.canvasFrame.minY + 60 else { return event }

        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            let anchor = CGPoint(x: p.x - ws.canvasFrame.minX, y: p.y - ws.canvasFrame.minY)
            ws.zoom(by: exp(event.scrollingDeltaY * k * 0.01), around: anchor)
        } else {
            ws.offset.width += event.scrollingDeltaX * k
            ws.offset.height += event.scrollingDeltaY * k
        }
        return nil
    }
}
#endif
