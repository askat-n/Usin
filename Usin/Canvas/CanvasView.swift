import SwiftUI
import SwiftData

struct CanvasView: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Анимация только когда приложение на переднем плане — в фоне батарея не тратится.
    private var animate: Bool { AppSettings.shared.cosmosMotion && !reduceMotion && scenePhase == .active }
    /// Живой граф: заметки плавают и пружинят (можно выключить в настройках).
    private var drifting: Bool {
        AppSettings.shared.classicMotion && !reduceMotion && scenePhase == .active && windowActive
    }
    #if os(macOS)
    /// Mac: когда работаешь в другом приложении, граф замирает — батарея не тратится.
    @Environment(\.controlActiveState) private var controlActiveState
    private var windowActive: Bool { controlActiveState != .inactive }
    #else
    private let windowActive = true
    #endif
    @State private var physics = GraphPhysics()
    /// Граф пружинит (или заметку тянут) — 60 кадров; спокойное плавание медленное — хватает 12.
    @State private var lively = false
    private var frameInterval: Double { lively || dragOrigin != nil ? 1.0 / 60 : 1.0 / 12 }
    /// Где курсор (Mac). Заметку под ним ищем каждый кадр — она ведь плывёт.
    @State private var pointer: CGPoint?
    /// Заметки в корзине на холсте не показываются (и их стрелки тоже).
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }, sort: \Node.createdAt) private var nodes: [Node]
    @Query(sort: \Connection.createdAt) private var connections: [Connection]

    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: (scale: CGFloat, offset: CGSize)?
    @State private var dragOrigin: (id: UUID, position: CGPoint)?
    @State private var bendOrigin: (x: Double, y: Double, style: String)?
    @State private var linkDraft: (from: UUID, point: CGPoint)?
    @State private var press: HoldPress?
    @State private var holdTask: Task<Void, Never>?
    @State private var createdCount = 0
    @State private var lastTap: (id: UUID, time: Date)?


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
                    // Фон уходит под полоску «домой» на iPhone — без тёмной полосы снизу.
                    .ignoresSafeArea(.container, edges: .bottom)

                // Всё, что зависит от положения заметок, — внутри часов: в «Классическом» заметки плавают.
                TimelineView(.animation(minimumInterval: frameInterval, paused: !drifting)) { tl in
                    let snaps = nodes.map(GraphNode.init)
                    let snapByID = Dictionary(snaps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let d = drifting
                        ? physics.step(time: tl.date.timeIntervalSinceReferenceDate, nodes: snaps,
                                       links: connections.map { ($0.fromID, $0.toID) }, held: dragOrigin?.id)
                        : Drift.none
                    let hoveredID = hoveredNode(t, d, snaps)
                    let _ = updateLively(d.restless)
                    let lit = litIDs(hoveredID)
                    ZStack {
                        ForEach(connections) { c in
                            if let a = byID[c.fromID], let b = byID[c.toID],
                                   let ga = snapByID[c.fromID], let gb = snapByID[c.toID] {
                                ConnectionView(
                                    geometry: EdgeGeometry(from: ga, to: gb, connection: c, transform: t,
                                                           driftA: d.offset(ga.id), driftB: d.offset(gb.id)),
                                    connection: c,
                                    selected: ws.selection == .connection(c.id)
                                        || (lit != nil && (c.fromID == hoveredID || c.toID == hoveredID)),
                                    scale: t.scale,
                                    cosmos: AppSettings.shared.isCosmos,
                                    terminal: AppSettings.shared.isTerminal
                                )
                                .opacity(isDimmed(a) || isDimmed(b) ? 0.12
                                         : (lit != nil && c.fromID != hoveredID && c.toID != hoveredID ? 0.2 : 1))
                                .onTapGesture { ws.select(.connection(c.id)) }
                            }
                        }

                        if let draft = linkDraft, let a = byID[draft.from] {
                            Path { p in
                                p.move(to: t.toScreen(a.position + d.offset(a)))
                                p.addLine(to: draft.point)
                            }
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                            .allowsHitTesting(false)
                        }

                        if AppSettings.shared.isCosmos {
                            cosmicLayers(t, byID: byID, d, lit: lit)
                        } else if AppSettings.shared.isTerminal {
                            terminalLayers(t, byID: byID, d)
                        }

                        ForEach(nodes) { node in
                            nodeView(node, t, d, lit: lit, hovered: hoveredID == node.id)
                        }

                        if AppSettings.shared.isTerminal, let root = nodes.first(where: \.isRoot),
                           ws.editingTitleID != root.id {
                            terminalCaret(root, t, d)
                        }

                        if case .node(let id) = ws.selection, ws.editingTitleID != id, let n = byID[id] {
                            linkHandle(n, t, d)
                        }

                        if case .connection(let id) = ws.selection,
                           let c = connections.first(where: { $0.id == id }),
                           let a = byID[c.fromID], let b = byID[c.toID] {
                            bendHandle(c, a, b, t, d)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if let p = press, !p.moved, !p.fired {
                    HoldRing(duration: AppSettings.shared.holdDuration)
                        .id(p.id)
                        .position(p.location)
                        .allowsHitTesting(false)
                }

            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named("canvas"))
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                switch phase {
                case .active(let p): pointer = p
                case .ended: pointer = nil
                }
            }
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
        .overlay(alignment: .topTrailing) {
            if AppSettings.shared.isTerminal {
                TerminalStatus(transform: CanvasTransform(size: ws.canvasSize, offset: ws.offset, scale: ws.scale),
                               count: nodes.count - 1)
                    .padding(.top, 14)
                    .padding(.trailing, 12)
            }
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
    /// удержал палец на месте (время — в настройках) — новая заметка.
    private func background(_ t: CanvasTransform) -> some View {
        ZStack {
            if AppSettings.shared.isTerminal {
                TerminalBackground(transform: t, animate: animate, showGrid: AppSettings.shared.showGrid)
            } else if AppSettings.shared.isCosmos {
                CosmicBackground(transform: t, animate: animate, showGrid: AppSettings.shared.showGrid)
            } else {
                Color.canvas
                if AppSettings.shared.showGrid {
                    DotGrid(transform: t)
                }
            }
        }
        .allowsHitTesting(true)
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
            try? await Task.sleep(for: .seconds(AppSettings.shared.holdDuration))
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

    // MARK: - Cosmos layers

    /// Огоньки на стрелках, свечение заметок и живая сфера — на Core Animation.
    @ViewBuilder
    private func cosmicLayers(_ t: CanvasTransform, byID: [UUID: Node], _ d: Drift, lit: Set<UUID>?) -> some View {
        let k = max(0.6, min(t.scale, 1.5))
        let edges: [CosmicFlows.Edge] = connections.compactMap { c in
            guard let a = byID[c.fromID], let b = byID[c.toID] else { return nil }
            let g = EdgeGeometry(from: a, to: b, connection: c, transform: t, drift: d.offset)
            return CosmicFlows.Edge(id: c.id, path: g.path, width: 2.6 * k,
                                    opacity: isDimmed(a) || isDimmed(b) ? 0.12 : 1)
        }
        let glows: [CosmicFlows.Glow] = nodes.filter { !$0.isRoot }.map { node in
            let size = CGSize(width: node.size.width * t.scale, height: node.size.height * t.scale)
            let c = t.toScreen(node.position + d.offset(node))
            let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            return CosmicFlows.Glow(id: node.id, path: node.shape.outline.path(in: rect), color: node.glowColor,
                                    radius: 14 * t.scale,
                                    opacity: isDimmed(node) ? 0.15 : (lit.map { $0.contains(node.id) } == false ? 0.3 : 1),
                                    seed: node.id.seed)
        }
        CosmicFlows(edges: edges, glows: glows, animate: animate)
        if let root = nodes.first(where: \.isRoot) {
            CosmicOrb(center: t.toScreen(root.position + d.offset(root)), diameter: root.size.width * t.scale, scale: t.scale,
                      base: root.glowColor, animate: animate)
        }
    }

    /// «Пакеты данных» на стрелках и мигающий курсор у сферы — на Core Animation.
    @ViewBuilder
    private func terminalLayers(_ t: CanvasTransform, byID: [UUID: Node], _ d: Drift) -> some View {
        let k = max(0.6, min(t.scale, 1.5))
        let edges: [TerminalFlows.Edge] = connections.compactMap { c in
            guard let a = byID[c.fromID], let b = byID[c.toID] else { return nil }
            let g = EdgeGeometry(from: a, to: b, connection: c, transform: t, drift: d.offset)
            return TerminalFlows.Edge(id: c.id, path: g.path, width: 2.4 * k,
                                      opacity: isDimmed(a) || isDimmed(b) ? 0.12 : 1,
                                      color: c.colorIndex == 0 ? Term.green : Palette.swatch(c.colorIndex).ink)
        }
        TerminalFlows(edges: edges, animate: animate)
    }

    /// Курсор сразу после надписи на сфере (шрифт моноширинный — ширину легко посчитать).
    private func terminalCaret(_ root: Node, _ t: CanvasTransform, _ d: Drift) -> some View {
        let fontSize: CGFloat = 20
        let textWidth = CGFloat(min(root.title.count, 10)) * fontSize * Term.charWidth
        let c = t.toScreen(root.position + d.offset(root))
        let rect = CGRect(x: c.x + (textWidth / 2 + 3) * t.scale, y: c.y - fontSize * 0.55 * t.scale,
                          width: fontSize * 0.55 * t.scale, height: fontSize * 1.1 * t.scale)
        return TerminalCaret(rect: rect, color: Term.ink(root.inkIndex), animate: animate)
            .opacity(isDimmed(root) ? 0.15 : 1)
    }

    // MARK: - Nodes

    private func isDimmed(_ node: Node) -> Bool {
        guard ws.filterThemeID != nil, !node.isRoot else { return false }
        return !ws.passesFilter(themeID: node.theme?.id, isForAI: node.isForAI)
    }

    /// Заметка под курсором и её соседи по стрелкам (nil — курсор ни на чём).
    private func litIDs(_ hoveredID: UUID?) -> Set<UUID>? {
        guard let id = hoveredID, dragOrigin == nil else { return nil }
        var set: Set<UUID> = [id]
        for c in connections {
            if c.fromID == id { set.insert(c.toID) }
            if c.toID == id { set.insert(c.fromID) }
        }
        return set
    }

    private func updateLively(_ restless: Bool) {
        guard restless != lively else { return }
        // Менять состояние прямо во время отрисовки нельзя — на следующем шаге.
        DispatchQueue.main.async { lively = restless }
    }

    /// Верхняя заметка под курсором — с учётом того, куда она уплыла.
    private func hoveredNode(_ t: CanvasTransform, _ d: Drift, _ snaps: [GraphNode]) -> UUID? {
        guard let pointer, panOrigin == nil, zoomOrigin == nil else { return nil }
        let world = t.toWorld(pointer)
        return snaps.last { $0.contains(world, offset: d.offset($0.id)) }?.id
    }

    private func nodeView(_ node: Node, _ t: CanvasTransform, _ d: Drift, lit: Set<UUID>?, hovered: Bool) -> some View {
        let editing = ws.editingTitleID == node.id
        return NodeView(
            node: node,
            selected: ws.selection == .node(node.id),
            isOpen: ws.openTabs.contains(node.id),
            editing: editing,
            onEndEditing: { ws.editingTitleID = nil }
        )
        // Содержимое заметки не пересчитывается каждый кадр — двигается только её место.
        .equatable()
        .scaleEffect(t.scale)
        .opacity(isDimmed(node) ? 0.15 : (lit.map { $0.contains(node.id) } == false ? 0.35 : 1))
        .scaleEffect(hovered && dragOrigin == nil ? 1.04 : 1)
        .animation(.easeOut(duration: 0.2), value: lit)
        .animation(.spring(duration: 0.3, bounce: 0.4), value: hovered)
        .position(t.toScreen(node.position + d.offset(node)))
        .gesture(nodeDrag(node), isEnabled: !editing)
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
    }

    private func nodeDrag(_ node: Node) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if dragOrigin?.id != node.id {
                    dragOrigin = (node.id, node.position)
                    ws.select(.node(node.id))
                    // Пока тянем, каждый кадр в ⌘Z не записываем — только итог.
                    ws.context.undoManager?.disableUndoRegistration()
                }
                guard let origin = dragOrigin else { return }
                node.x = origin.position.x + v.translation.width / ws.scale
                node.y = origin.position.y + v.translation.height / ws.scale
            }
            .onEnded { _ in
                guard let origin = dragOrigin else { return }
                dragOrigin = nil
                commitAsOneUndoStep {
                    let final = node.position
                    node.x = origin.position.x
                    node.y = origin.position.y
                    return { node.x = final.x; node.y = final.y }
                }
            }
    }

    /// Вернуть значения «как до перетаскивания» без записи, включить запись и поставить итог —
    /// так перетаскивание отменяется одним ⌘Z.
    private func commitAsOneUndoStep(_ resetAndGetFinal: () -> () -> Void) {
        let applyFinal = resetAndGetFinal()
        ws.context.undoManager?.enableUndoRegistration()
        applyFinal()
    }

    // MARK: - Arrows

    /// Кнопка «+» справа от выбранной фигуры: тянешь — стрелка, нажал — новая связанная заметка.
    private func linkHandle(_ node: Node, _ t: CanvasTransform, _ d: Drift) -> some View {
        let edge = t.toScreen(CGPoint(x: node.x + node.size.width / 2, y: node.y) + d.offset(node))
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
            .help(tr("Тяни к другой фигуре — стрелка. Нажми — новая связанная заметка"))
    }

    private func finishLink(from source: Node, at point: CGPoint, moved: Bool, _ t: CanvasTransform) {
        let inheritedTheme = source.isRoot ? nil : source.theme
        guard moved else {
            // На узком экране (iPhone) — снизу, чтобы не уходила за край; на широком — справа.
            let p = t.size.width < 600
                ? CGPoint(x: source.x + .random(in: -30...30), y: source.y + source.size.height / 2 + 120)
                : CGPoint(x: source.x + source.size.width / 2 + 190, y: source.y + .random(in: -40...40))
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
    private func bendHandle(_ c: Connection, _ a: Node, _ b: Node, _ t: CanvasTransform, _ d: Drift) -> some View {
        let g = EdgeGeometry(from: a, to: b, connection: c, transform: t, drift: d.offset)
        return Circle()
            .fill(Color.editor)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -12))
            .position(g.handle)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if bendOrigin == nil {
                            bendOrigin = (c.bendX, c.bendY, c.styleRaw)
                            ws.context.undoManager?.disableUndoRegistration()
                        }
                        let mid = EdgeGeometry.midpoint(t.toScreen(a.position + d.offset(a)), t.toScreen(b.position + d.offset(b)))
                        c.bendX = (v.location.x - mid.x) / t.scale
                        c.bendY = (v.location.y - mid.y) / t.scale
                        c.style = .curved
                    }
                    .onEnded { _ in
                        guard let origin = bendOrigin else { return }
                        bendOrigin = nil
                        commitAsOneUndoStep {
                            let final = (c.bendX, c.bendY, c.styleRaw)
                            (c.bendX, c.bendY, c.styleRaw) = origin
                            return { (c.bendX, c.bendY, c.styleRaw) = final }
                        }
                    }
            )
            .onTapGesture(count: 2) {
                c.bendX = 0
                c.bendY = 0
                c.style = .straight
            }
            .help(tr("Тяни, чтобы изогнуть. Двойной тап — выпрямить"))
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
        if ws.trashToastID != nil {
            TrashToast().transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            selectionPanel
        }
    }

    @ViewBuilder
    private var selectionPanel: some View {
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
                Text(tr("Удержи палец на пустом месте — появится заметка"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .panelBackground()
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
        // Настройки и другие листы — отдельные окна поверх холста: их прокрутку не трогаем.
        guard ws.isOnCanvas, !ws.showSettings, !ws.showAllNotes,
              let window = event.window, window.styleMask.contains(.titled),
              window.sheetParent == nil, window.attachedSheet == nil,
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
