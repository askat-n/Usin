import AppKit
import Combine
import EventKit
import UsinToolsCore
import SwiftUI

// MARK: - Модель

/// Виды виджетов. Каждый показывает живые данные Usin и обновляется сам.
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case system, topApps, battery, aiLimits, meeting, nowPlaying, clipboard, ports, keepAwake, clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Mac сейчас")
        case .topApps: return L("Кто грузит Mac")
        case .battery: return L("Батарея")
        case .aiLimits: return L("Лимиты ИИ")
        case .meeting: return L("Следующая встреча")
        case .nowPlaying: return L("Сейчас играет")
        case .clipboard: return L("Буфер обмена")
        case .ports: return L("Порты разработчика")
        case .keepAwake: return L("Не засыпать")
        case .clock: return L("Часы")
        }
    }

    var subtitle: String {
        switch self {
        case .system: return L("Процессор, память, сеть и диск")
        case .topApps: return L("Самые тяжёлые программы прямо сейчас")
        case .battery: return L("Заряд и сколько осталось")
        case .aiLimits: return L("Сколько осталось в Claude и ChatGPT")
        case .meeting: return L("Через сколько встреча и запись одной кнопкой")
        case .nowPlaying: return L("Обложка и кнопки плеера")
        case .clipboard: return L("Последнее скопированное: нажмите, чтобы вставить")
        case .ports: return L("Запущенные серверы на localhost")
        case .keepAwake: return L("Mac не уснёт, пока вы не разрешите")
        case .clock: return L("Время здесь и в других городах")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gauge.with.dots.needle.50percent"
        case .topApps: return "chart.bar.fill"
        case .battery: return "battery.75percent"
        case .aiLimits: return "sparkle"
        case .meeting: return "calendar"
        case .nowPlaying: return "music.note"
        case .clipboard: return "doc.on.clipboard.fill"
        case .ports: return "network"
        case .keepAwake: return "cup.and.heat.waves.fill"
        case .clock: return "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .system: return .blue
        case .topApps: return .orange
        case .battery: return .green
        case .aiLimits: return .purple
        case .meeting: return .red
        case .nowPlaying: return .pink
        case .clipboard: return .teal
        case .ports: return .indigo
        case .keepAwake: return .brown
        case .clock: return .gray
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .system, .clipboard, .topApps: return [.small, .medium, .large]
        case .keepAwake: return [.small]
        default: return [.small, .medium]
        }
    }
}

enum WidgetSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return L("Маленький")
        case .medium: return L("Средний")
        case .large: return L("Большой")
        }
    }

    /// Пропорции как у виджетов macOS.
    var size: CGSize {
        switch self {
        case .small: return CGSize(width: 164, height: 164)
        case .medium: return CGSize(width: 344, height: 164)
        case .large: return CGSize(width: 344, height: 344)
        }
    }
}

struct DesktopWidget: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize
    /// Левый верхний угол в координатах экрана AppKit.
    var x: Double
    var y: Double
}

// MARK: - Окна на рабочем столе

/// Живые виджеты Usin. Их рисует само приложение, поэтому цифры обновляются каждую секунду,
/// а не раз в 15 минут, как у системных виджетов. Стоят над значками рабочего стола и под окнами.
@MainActor
final class WidgetsController: ObservableObject {
    @Published private(set) var widgets: [DesktopWidget] = []
    @Published var visible: Bool {
        didSet {
            UserDefaults.standard.set(visible, forKey: "widgetsVisible")
            sync()
        }
    }
    @Published var clockZones: [String] {
        didSet { UserDefaults.standard.set(clockZones, forKey: "widgetClockZones") }
    }

    let calendar = CalendarFeed()
    private var windows: [UUID: WidgetWindow] = [:]
    private var screenObserver: NSObjectProtocol?
    private static let storageKey = "desktopWidgets"
    static let grid: CGFloat = 8

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["widgetsVisible": true, "widgetClockZones": ["Europe/London", "America/New_York"]])
        visible = defaults.bool(forKey: "widgetsVisible")
        clockZones = defaults.stringArray(forKey: "widgetClockZones") ?? []
        if let data = defaults.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode([DesktopWidget].self, from: data) {
            widgets = stored
        }
    }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
        sync()
    }

    // MARK: Изменения

    func add(_ kind: WidgetKind, size: WidgetSize? = nil) {
        let size = size ?? kind.sizes.first ?? .small
        let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        // Новый виджет — у правого края, ниже уже стоящих, как в macOS.
        var origin = CGPoint(x: screen.maxX - size.size.width - 24, y: screen.maxY - 24)
        let occupied = widgets.map { frame(of: $0) }
        while occupied.contains(where: { $0.intersects(CGRect(x: origin.x, y: origin.y - size.size.height, width: size.size.width, height: size.size.height)) }),
              origin.y - size.size.height > screen.minY + 200 {
            origin.y -= 16
        }
        widgets.append(DesktopWidget(kind: kind, size: size, x: origin.x, y: origin.y))
        visible = true
        save()
        sync()
    }

    func remove(_ id: UUID) {
        widgets.removeAll { $0.id == id }
        save()
        sync()
    }

    func resize(_ id: UUID, to size: WidgetSize) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        widgets[index].size = size
        save()
        sync()
    }

    func move(_ id: UUID, to topLeft: CGPoint, snap: Bool) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        var point = topLeft
        if snap {
            point.x = (point.x / Self.grid).rounded() * Self.grid
            point.y = (point.y / Self.grid).rounded() * Self.grid
        }
        widgets[index].x = point.x
        widgets[index].y = point.y
        windows[id]?.place(frame(of: widgets[index]))
        if snap { save() }
    }

    func frame(of widget: DesktopWidget) -> CGRect {
        let size = widget.size.size
        return CGRect(x: widget.x, y: widget.y - size.height, width: size.width, height: size.height)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    // MARK: Окна

    private func sync() {
        let shown = visible ? widgets : []
        let ids = Set(shown.map(\.id))
        for (id, window) in windows where !ids.contains(id) {
            window.dispose()
            window.orderOut(nil)
            window.contentView = nil
            windows[id] = nil
        }
        for widget in shown {
            let window = windows[widget.id] ?? makeWindow(for: widget)
            windows[widget.id] = window
            window.place(frame(of: widget))
            window.update(widget)
            window.orderFront(nil)
        }
        updateDemand(shown)
    }

    private func makeWindow(for widget: DesktopWidget) -> WidgetWindow {
        WidgetWindow(widget: widget, controller: self)
    }

    /// Если монитор отключили, виджеты с него переезжают на главный экран.
    private func keepOnScreen() {
        guard let main = NSScreen.main?.visibleFrame else { return }
        var changed = false
        for index in widgets.indices {
            let frame = frame(of: widgets[index])
            if !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                widgets[index].x = main.maxX - frame.width - 24
                widgets[index].y = main.maxY - 24
                changed = true
            }
        }
        if changed { save() }
        sync()
    }

    /// Данные собираются, только пока есть виджет, которому они нужны.
    private func updateDemand(_ shown: [DesktopWidget]) {
        let kinds = Set(shown.map(\.kind))
        let system = Coordinator.shared.system
        system.widgetDemand = SystemMonitor.WidgetDemand(
            system: kinds.contains(.system) || kinds.contains(.battery),
            apps: kinds.contains(.topApps) || shown.contains { $0.kind == .battery && $0.size != .small } || shown.contains { $0.kind == .system && $0.size == .large },
            ports: kinds.contains(.ports)
        )
        let nowPlaying = Coordinator.shared.nowPlaying
        if kinds.contains(.nowPlaying) { nowPlaying.retain("widgets") } else { nowPlaying.release("widgets") }
        let limits = Coordinator.shared.limits
        if kinds.contains(.aiLimits) { limits.retain("widgets") } else { limits.release("widgets") }
        if kinds.contains(.meeting) { calendar.retain("desktop") } else { calendar.release("desktop") }
    }
}

/// Окно одного виджета: без рамки, на уровне рабочего стола, на всех рабочих столах.
@MainActor
final class WidgetWindow: NSPanel {
    private var widget: DesktopWidget
    private weak var controller: WidgetsController?
    private let model: WidgetModel

    init(widget: DesktopWidget, controller: WidgetsController) {
        self.widget = widget
        self.controller = controller
        self.model = WidgetModel(widget: widget)
        super.init(contentRect: controller.frame(of: widget), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let hosting = WidgetHostingView(rootView: WidgetContainer(model: model, controller: controller))
        // Окно двигает сама macOS; когда оно остановилось, выравниваем по сетке и запоминаем место.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettle() }
        }
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 24
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var moveObserver: NSObjectProtocol?

    func dispose() {
        settleWork?.cancel()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
    }
    private var settleWork: DispatchWorkItem?
    private var placing = false

    private func scheduleSettle() {
        guard !placing else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller, NSEvent.pressedMouseButtons & 1 == 0 else {
                    self?.scheduleSettle()
                    return
                }
                controller.move(self.widget.id, to: CGPoint(x: self.frame.minX, y: self.frame.maxY), snap: true)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func update(_ widget: DesktopWidget) {
        self.widget = widget
        if model.widget != widget { model.widget = widget }
    }

    func place(_ frame: CGRect) {
        if self.frame != frame {
            placing = true
            setFrame(frame, display: true)
            invalidateShadow()
            placing = false
        }
    }
}

/// Перетаскивание виджета отдаём самой macOS (`performDrag`): окно едет за мышью без задержек,
/// как обычное окно. Короткое нажатие по-прежнему достаётся кнопкам внутри виджета.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let window else {
            super.mouseDragged(with: event)
            return
        }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard distance >= 3 else { return }
        mouseDownEvent = nil
        // Кнопка под курсором не должна сработать после перетаскивания: «отпускаем» мышь вне виджета.
        if let cancel = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
                                           timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 0) {
            super.mouseUp(with: cancel)
        }
        window.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        super.mouseUp(with: event)
    }
}

@MainActor
final class WidgetModel: ObservableObject {
    @Published var widget: DesktopWidget
    init(widget: DesktopWidget) { self.widget = widget }
}

/// Стеклянная карточка виджета: перетаскивается за любое место, правый клик — размер и удаление.
private struct WidgetContainer: View {
    @ObservedObject var model: WidgetModel
    let controller: WidgetsController

    var body: some View {
        let widget = model.widget
        WidgetContent(kind: widget.kind, size: widget.size, controller: controller)
            .padding(14)
            .frame(width: widget.size.size.width, height: widget.size.size.height, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .contentShape(Rectangle())
            .contextMenu {
                if widget.kind.sizes.count > 1 {
                    ForEach(widget.kind.sizes) { size in
                        Button {
                            controller.resize(widget.id, to: size)
                        } label: {
                            if size == widget.size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                        }
                    }
                    Divider()
                }
                Button("Изменить виджеты…") { Coordinator.shared.openSettings(.widgets) }
                Button("Удалить виджет", role: .destructive) { controller.remove(widget.id) }
            }
            .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// Содержимое виджета по его виду. Используется и на рабочем столе, и в галерее настроек.
struct WidgetContent: View {
    let kind: WidgetKind
    let size: WidgetSize
    let controller: WidgetsController

    var body: some View {
        switch kind {
        case .system: SystemWidget(monitor: Coordinator.shared.system, size: size)
        case .topApps: TopAppsWidget(monitor: Coordinator.shared.system, size: size)
        case .battery: BatteryWidget(monitor: Coordinator.shared.system, size: size)
        case .aiLimits: AILimitsWidget(limits: Coordinator.shared.limits, size: size)
        case .meeting: MeetingWidget(calendar: controller.calendar, meetings: Coordinator.shared.meetings, size: size)
        case .nowPlaying: NowPlayingWidget(player: Coordinator.shared.nowPlaying, size: size)
        case .clipboard: ClipboardWidget(clipboard: Coordinator.shared.clipboard, size: size)
        case .ports: PortsWidget(monitor: Coordinator.shared.system, size: size)
        case .keepAwake: KeepAwakeWidget(keepAwake: Coordinator.shared.system.keepAwake)
        case .clock: ClockWidget(controller: controller, timer: Coordinator.shared.timer, size: size)
        }
    }
}

// MARK: - Общие детали

private struct WidgetTitle: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(verbatim: title).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// Кольцо прогресса, как в виджете «Батареи» macOS.
private struct Ring: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.4), value: value)
        }
    }
}

private struct Bar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: max(proxy.size.width * min(max(value, 0), 1), 3))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.4), value: value)
    }
}

private struct MiniGraph: View {
    let values: [Double]
    let scale: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let capacity = 40
            let step = proxy.size.width / CGFloat(capacity - 1)
            let start = CGFloat(capacity - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step, y: proxy.size.height - 1 - CGFloat(min(max(value / max(scale, 0.0001), 0), 1)) * (proxy.size.height - 2))
            }
            if points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private struct EmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
            Text(verbatim: text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Mac сейчас

private struct SystemWidget: View {
    @ObservedObject var monitor: SystemMonitor
    let size: WidgetSize

    var body: some View {
        let s = monitor.snapshot
        let memory = s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0
        let memoryTint: Color = s.memoryPressure >= 4 ? .red : s.memoryPressure >= 2 ? .orange : .green
        switch size {
        case .small:
            VStack(alignment: .leading, spacing: 10) {
                WidgetTitle(symbol: "gauge.with.dots.needle.50percent", title: L("Mac сейчас"), tint: .blue)
                HStack(spacing: 12) {
                    ringStat(value: s.cpu, label: L("Процессор"), text: Format.percent(s.cpu * 100), tint: .blue)
                    ringStat(value: memory, label: L("Память"), text: Format.percent(memory * 100), tint: memoryTint)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text(verbatim: "↓ " + Format.rate(s.download) + "  ↑ " + Format.rate(s.upload))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
        case .medium, .large:
            VStack(alignment: .leading, spacing: 10) {
                WidgetTitle(symbol: "gauge.with.dots.needle.50percent", title: L("Mac сейчас"), tint: .blue)
                Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        stat(L("Процессор"), Format.percent(s.cpu * 100), monitor.cpuHistory.values, 1, .blue)
                        stat(L("Память"), Format.gigabytes(s.memoryUsed), monitor.memoryHistory.values, 1, memoryTint)
                    }
                    GridRow {
                        stat(L("Сеть"), "↓ " + Format.rate(s.download), monitor.networkHistory.values, max(monitor.networkHistory.values.max() ?? 0, 50_000), .purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Диск").font(.caption2).foregroundStyle(.secondary)
                            Text(verbatim: Format.disk(s.diskFree)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                            Bar(value: s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) : 0, tint: .gray)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if size == .large {
                    Divider()
                    TopAppsList(apps: Array(monitor.apps.prefix(5)), heavy: monitor.heavyApps)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func ringStat(value: Double, label: String, text: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Ring(value: value, tint: tint, lineWidth: 6)
                Text(verbatim: text).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 58, height: 58)
            Text(verbatim: label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func stat(_ title: String, _ value: String, _ history: [Double], _ scale: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            MiniGraph(values: history, scale: scale, tint: tint).frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Кто грузит Mac

private struct TopAppsList: View {
    let apps: [AppUsage]
    let heavy: Set<pid_t>
    var showMemory = true

    var body: some View {
        let top = apps.map(\.cpuShare).max() ?? 1
        VStack(spacing: 6) {
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    AppIcon(image: app.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: app.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: Format.percent(app.cpuShare))
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(heavy.contains(app.pid) ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            if showMemory {
                                Text(verbatim: Format.bytes(app.memory)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                        Bar(value: top > 0 ? app.cpuShare / max(top, 1) : 0, tint: heavy.contains(app.pid) ? .orange : .blue)
                    }
                }
            }
        }
    }
}

private struct TopAppsWidget: View {
    @ObservedObject var monitor: SystemMonitor
    let size: WidgetSize

    var body: some View {
        let count = size == .small ? 3 : size == .medium ? 4 : 9
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitle(symbol: "chart.bar.fill", title: L("Кто грузит Mac"), tint: .orange)
            if monitor.apps.isEmpty {
                EmptyState(symbol: "hourglass", text: L("Собираю данные…"))
            } else if size == .small {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(monitor.apps.prefix(count)) { app in
                        HStack(spacing: 7) {
                            AppIcon(image: app.icon, size: 20)
                            Text(verbatim: app.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(verbatim: Format.percent(app.cpuShare)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            } else {
                TopAppsList(apps: Array(monitor.apps.prefix(count)), heavy: monitor.heavyApps)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Батарея

private struct BatteryWidget: View {
    @ObservedObject var monitor: SystemMonitor
    let size: WidgetSize

    var body: some View {
        let s = monitor.snapshot
        if let level = s.batteryLevel {
            let tint: Color = s.charging ? .green : level <= 20 ? .red : level <= 40 ? .orange : .green
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetTitle(symbol: s.charging ? "battery.100percent.bolt" : "battery.75percent", title: L("Батарея"), tint: tint)
                    ZStack {
                        Ring(value: Double(level) / 100, tint: tint, lineWidth: 8)
                        VStack(spacing: 0) {
                            Text(verbatim: "\(level)%").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            if s.charging { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
                        }
                    }
                    .frame(width: 84, height: 84)
                    .frame(maxWidth: .infinity)
                    Text(verbatim: caption(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: size == .small ? nil : 136)
                if size != .small {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Больше всего тратят").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TopAppsList(apps: Array(monitor.apps.prefix(3)), heavy: monitor.heavyApps, showMemory: false)
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            VStack(alignment: .leading) {
                WidgetTitle(symbol: "powerplug.fill", title: L("Батарея"), tint: .green)
                EmptyState(symbol: "powerplug", text: L("У этого Mac нет батареи: он работает от сети"))
            }
        }
    }

    private func caption(_ s: SystemSnapshot) -> String {
        if let minutes = s.batteryMinutes {
            return String(format: s.onBattery ? L("ещё %@") : L("до полной %@"), Format.minutes(minutes))
        }
        return s.onBattery ? L("от батареи") : L("от сети")
    }
}

// MARK: - Лимиты ИИ

private struct AILimitsWidget: View {
    @ObservedObject var limits: AILimitsMonitor
    let size: WidgetSize

    var body: some View {
        let providers = AILimitsMonitor.providers.filter { limits.windows[$0]?.isEmpty == false }
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitle(symbol: "sparkle", title: L("Лимиты ИИ"), tint: .purple)
            if providers.isEmpty {
                VStack(spacing: 6) {
                    EmptyState(symbol: "gauge.with.dots.needle.33percent", text: L("Войдите в Claude и ChatGPT, чтобы видеть лимиты"))
                    Button("Открыть настройки") { Coordinator.shared.openSettings(.ai) }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            } else if size == .small {
                HStack(spacing: 12) {
                    ForEach(providers.prefix(2)) { provider in
                        let window = limits.windows[provider]?.first
                        VStack(spacing: 4) {
                            ZStack {
                                Ring(value: (window?.usedPercent ?? 0) / 100, tint: color(window?.usedPercent ?? 0), lineWidth: 6)
                                Image(systemName: provider.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(provider.tint)
                            }
                            .frame(width: 54, height: 54)
                            Text(verbatim: "\(Int((window?.usedPercent ?? 0).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                            Text(verbatim: provider.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 9) {
                    ForEach(providers) { provider in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: provider.symbol).foregroundStyle(provider.tint).frame(width: 16)
                            VStack(spacing: 6) {
                                ForEach(limits.windows[provider] ?? []) { window in
                                    VStack(spacing: 3) {
                                        HStack {
                                            Text(verbatim: window.title).font(.caption).foregroundStyle(.secondary)
                                            Text(verbatim: "\(Int(window.usedPercent.rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                                            Spacer()
                                            if let date = window.resetsAt {
                                                Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                            }
                                        }
                                        Bar(value: window.usedPercent / 100, tint: color(window.usedPercent))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { limits.refresh() }
    }

    private func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : .green
    }
}

// MARK: - Следующая встреча

/// Ближайшие события календаря. Доступ к календарю спрашивается, только когда добавлен этот виджет.
@MainActor
final class CalendarFeed: ObservableObject {
    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let link: URL?
        let color: Color
    }

    @Published private(set) var next: Event?
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private var holders = Set<String>()

    /// Календарь читается, пока он нужен хоть кому-то: виджету на столе или системному виджету.
    func retain(_ holder: String) {
        holders.insert(holder)
        start()
    }

    func release(_ holder: String) {
        holders.remove(holder)
        if holders.isEmpty { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            access = EKEventStore.authorizationStatus(for: .event)
            reload()
        }
    }

    private func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else {
            next = nil
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let event else {
            next = nil
            return
        }
        let value = Event(
            title: event.title ?? L("Без названия"),
            start: event.startDate,
            end: event.endDate,
            link: Self.meetingLink(event),
            color: Color(nsColor: event.calendar?.color ?? .systemRed)
        )
        if value != next { next = value }
    }

    /// Ссылка на звонок: Zoom, Google Meet, Teams, FaceTime — из адреса, места или заметок события.
    private static func meetingLink(_ event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|facetime\.apple\.com|whereby\.com|telemost\.yandex)[^\s<>"]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

private struct MeetingWidget: View {
    @ObservedObject var calendar: CalendarFeed
    @ObservedObject var meetings: MeetingRecorder
    let size: WidgetSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTitle(symbol: "calendar", title: L("Следующая встреча"), tint: .red)
            if calendar.access != .fullAccess {
                VStack(spacing: 8) {
                    EmptyState(symbol: "calendar.badge.lock", text: L("Разрешите доступ к календарю"))
                    Button("Разрешить") { calendar.requestAccess() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else if let event = calendar.next {
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(event.color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: event.title).font(.callout.weight(.semibold)).lineLimit(size == .small ? 2 : 1)
                        Text(verbatim: event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(verbatim: countdown(event, now: context.date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(event.start <= context.date ? Color.red : Color.primary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let link = event.link {
                        Button {
                            NSWorkspace.shared.open(link)
                        } label: {
                            Label("Подключиться", systemImage: "video.fill").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    recordButton
                }
            } else {
                EmptyState(symbol: "calendar.badge.checkmark", text: L("Сегодня встреч больше нет"))
                recordButton
            }
        }
    }

    private var recordButton: some View {
        Button {
            meetings.toggle()
        } label: {
            if meetings.isRecording {
                Label("Стоп", systemImage: "stop.fill")
            } else {
                Label("Записать", systemImage: "record.circle")
            }
        }
        .buttonStyle(.bordered)
        .tint(meetings.isRecording ? .red : nil)
        .controlSize(.small)
    }

    private func countdown(_ event: CalendarFeed.Event, now: Date) -> String {
        if event.start <= now { return L("Идёт сейчас") }
        let minutes = Int(event.start.timeIntervalSince(now) / 60) + 1
        if minutes < 60 * 12 { return String(format: L("Через %@"), Format.minutes(minutes)) }
        return event.start.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

// MARK: - Сейчас играет

private struct NowPlayingWidget: View {
    @ObservedObject var player: NowPlaying
    let size: WidgetSize

    var body: some View {
        if let title = player.title {
            let artwork = Group {
                if let art = player.artwork {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.pink.gradient)
                        Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white)
                    }
                }
            }
            if size == .small {
                VStack(alignment: .leading, spacing: 6) {
                    artwork.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(verbatim: title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(verbatim: player.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    controls.frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 14) {
                    artwork.frame(width: 132, height: 132).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: title).font(.headline).lineLimit(2)
                        Text(verbatim: player.artist ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
        } else {
            VStack(alignment: .leading) {
                WidgetTitle(symbol: "music.note", title: L("Сейчас играет"), tint: .pink)
                EmptyState(symbol: "music.note", text: L("Ничего не играет"))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            button("backward.fill") { player.previousTrack() }
            button(player.isPlaying ? "pause.fill" : "play.fill", large: true) { player.togglePlayPause() }
            button("forward.fill") { player.nextTrack() }
        }
    }

    private func button(_ symbol: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: large ? 20 : 14, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Буфер обмена

private struct ClipboardWidget: View {
    @ObservedObject var clipboard: ClipboardController
    let size: WidgetSize
    @State private var pasted: UUID?

    @MainActor private static var thumbnails: [UUID: NSImage] = [:]

    /// Маленькая картинка для скопированного изображения; с диска читается один раз.
    @MainActor static func thumbnail(_ item: ClipItem, _ clipboard: ClipboardController) -> NSImage? {
        guard case .image = item.content else { return nil }
        if let cached = thumbnails[item.id] { return cached }
        guard let image = clipboard.image(for: item) else { return nil }
        if thumbnails.count > 40 { thumbnails.removeAll() }
        thumbnails[item.id] = image
        return image
    }

    var body: some View {
        let count = size == .small ? 2 : size == .medium ? 3 : 8
        VStack(alignment: .leading, spacing: 8) {
            WidgetTitle(symbol: "doc.on.clipboard.fill", title: L("Буфер обмена"), tint: .teal)
            let items = Array(clipboard.history.items.prefix(count))
            if items.isEmpty {
                EmptyState(symbol: "doc.on.clipboard", text: L("Скопируйте что-нибудь — оно появится здесь"))
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        WidgetClipRow(item: item, image: Self.thumbnail(item, clipboard), done: pasted == item.id) {
                            clipboard.paste(item)
                            pasted = item.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if pasted == item.id { pasted = nil } }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WidgetClipRow: View {
    let item: ClipItem
    let image: NSImage?
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let image, !done {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 28, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : symbol)
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                Text(verbatim: done ? L("Вставлено") : text).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("Вставить"))
    }

    private var symbol: String {
        switch item.content {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    private var text: String {
        switch item.content {
        case .text(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Изображение")
        case .files(let paths): return paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
    }
}

// MARK: - Порты

private struct PortsWidget: View {
    @ObservedObject var monitor: SystemMonitor
    let size: WidgetSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTitle(symbol: "network", title: L("Порты разработчика"), tint: .indigo)
            if monitor.ports.isEmpty {
                EmptyState(symbol: "powersleep", text: L("Серверы не запущены"))
            } else {
                VStack(spacing: 4) {
                    ForEach(monitor.ports.prefix(size == .small ? 3 : 4)) { port in
                        HStack(spacing: 6) {
                            Button {
                                if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                    Text(verbatim: ":\(port.port)").font(.caption.weight(.semibold)).monospacedDigit()
                                    Text(verbatim: port.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(Text("Открыть в браузере"))
                            if size != .small {
                                Button {
                                    monitor.stop(port)
                                } label: {
                                    Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(Text("Остановить"))
                            }
                        }
                        .frame(height: 20)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Не засыпать

private struct KeepAwakeWidget: View {
    @ObservedObject var keepAwake: KeepAwake

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if keepAwake.isOn { keepAwake.turnOff() } else { keepAwake.turnOn(hours: nil) }
            } label: {
                Image(systemName: keepAwake.isOn ? "cup.and.heat.waves.fill" : "cup.and.heat.waves")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(keepAwake.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(keepAwake.isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary.opacity(0.1))))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text(verbatim: status).font(.caption.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) {
                chip("1 " + L("ч"), hours: 1)
                chip("3 " + L("ч"), hours: 3)
                chip("∞", hours: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: String {
        guard keepAwake.isOn else { return L("Не засыпать") }
        guard let until = keepAwake.until else { return L("Не спит") }
        return String(format: L("До %@"), until.formatted(date: .omitted, time: .shortened))
    }

    private func chip(_ title: String, hours: Double?) -> some View {
        Button {
            keepAwake.turnOn(hours: hours)
        } label: {
            Text(verbatim: title).font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Часы

private struct ClockWidget: View {
    @ObservedObject var controller: WidgetsController
    @ObservedObject var timer: NotchTimer
    let size: WidgetSize

    var body: some View {
        // Раз в минуту хватает часам; каждую секунду — только пока идёт таймер.
        TimelineView(ClockSchedule(seconds: timer.endDate != nil)) { context in
            let now = context.date
            if size == .small {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: now.formatted(.dateTime.weekday(.wide))).font(.caption.weight(.semibold)).foregroundStyle(.red)
                    Text(verbatim: now.formatted(.dateTime.day().month(.wide))).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(verbatim: now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    timerLine(now)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    zone(nil, now: now, primary: true)
                    ForEach(controller.clockZones.prefix(2), id: \.self) { id in
                        Divider()
                        zone(TimeZone(identifier: id), now: now, primary: false)
                    }
                }
            }
        }
    }

    @ViewBuilder private func timerLine(_ now: Date) -> some View {
        if timer.endDate != nil || timer.pausedRemaining != nil {
            Label(NotchTimer.format(timer.remaining(at: now)), systemImage: "timer").font(.caption.weight(.semibold)).foregroundStyle(.orange).monospacedDigit()
        }
    }

    private func zone(_ zone: TimeZone?, now: Date, primary: Bool) -> some View {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let zone { style.timeZone = zone }
        let name = zone.map(Self.city) ?? L("Здесь")
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(primary ? .red : .secondary).lineLimit(1)
            Text(verbatim: now.formatted(style)).font(.system(size: primary ? 30 : 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let zone {
                Text(verbatim: Self.offset(zone, now: now)).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(verbatim: now.formatted(.dateTime.weekday(.abbreviated).day().month())).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if primary { timerLine(now) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func city(_ zone: TimeZone) -> String { cityName(zone) }

    /// «+3 ч» относительно текущего пояса.
    static func offset(_ zone: TimeZone, now: Date) -> String {
        let diff = zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        if diff == 0 { return L("Как здесь") }
        let hours = Double(diff) / 3600
        let text = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(format: "%.1f", hours)
        return (diff > 0 ? "+" : "") + text + " " + L("ч")
    }
}

/// Город часового пояса: «Europe/London» → «London».
func cityName(_ zone: TimeZone) -> String {
    let raw = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
    return raw.replacingOccurrences(of: "_", with: " ")
}

/// Расписание обновления часов: ровно в начале каждой минуты или каждую секунду.
private struct ClockSchedule: TimelineSchedule {
    let seconds: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let step: TimeInterval = seconds ? 1 : 60
        var next = Date(timeIntervalSinceReferenceDate: (startDate.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        return AnyIterator {
            defer { next = next.addingTimeInterval(step) }
            return next
        }
    }
}
