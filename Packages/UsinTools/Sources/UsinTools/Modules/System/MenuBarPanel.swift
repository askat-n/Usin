import AppKit
import Combine
import UsinToolsCore
import SwiftUI

/// Значок Usin в строке меню и панель, которая открывается по клику:
/// что сейчас работает, как себя чувствует Mac и быстрые действия. Правый клик — короткое меню.
@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private var panel: KeyablePanel?
    private let state = MenuBarPanelState()
    private var closedAt = Date.distantPast
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private var monitor: SystemMonitor { Coordinator.shared.system }
    static let width: CGFloat = 340

    var isInstalled: Bool { item != nil }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item

        let settings = AppSettings.shared
        settings.$menuBarStats.combineLatest(settings.$heavyAppAlerts)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.monitor.reschedule()
                self?.updateButton()
            }
            .store(in: &cancellables)
        monitor.keepAwake.$isOn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        monitor.onUpdate = { [weak self] in self?.updateButton() }
        updateButton()
    }

    func remove() {
        close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        cancellables.removeAll()
        monitor.onUpdate = nil
        monitor.reschedule()
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let symbol = monitor.keepAwake.isOn ? "cup.and.heat.waves.fill" : "circle.hexagongrid.fill"
        if button.image?.accessibilityDescription != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            image?.isTemplate = true
            button.image = image
        }
        if let text = monitor.menuBarText {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .baselineOffset: 0.5,
            ])
            item?.length = NSStatusItem.variableLength
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
            item?.length = NSStatusItem.squareLength
        }
        button.toolTip = "Usin"
    }

    // MARK: - Клики

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            // Клик по значку сначала снимает фокус с панели и закрывает её — не открываем её тут же снова.
            open()
        }
    }

    private func showMenu() {
        close()
        let menu = NSMenu()
        let note = NSMenuItem(title: L("Новая заметка"), action: #selector(newNote), keyEquivalent: "")
        note.target = self
        menu.addItem(note)
        let open = NSMenuItem(title: L("Открыть Usin"), action: #selector(openHub), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: L("Настройки…"), action: #selector(openAppSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: L("Проверить обновления…"), action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Выйти из Usin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func openHub() { ToolsHost.openApp() }
    @objc private func newNote() { ToolsHost.newNote() }
    @objc private func openAppSettings() { ToolsHost.openSettings(nil) }
    @objc private func checkUpdates() { ToolsHost.checkForUpdates() }

    // MARK: - Панель

    func open() {
        guard let button = item?.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        state.page = .main
        // Служебный режим для проверки снимком: сразу нужная страница.
        if CommandLine.arguments.contains("--panel-memory") { state.page = .memory }
        state.maxListHeight = min(330, max(160, screen.visibleFrame.height - 520))
        state.top = anchor.minY - 6
        state.anchorX = anchor.midX
        state.screenFrame = screen.visibleFrame

        let panel: KeyablePanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let view = MenuBarPanelView(
                monitor: monitor,
                keepAwake: monitor.keepAwake,
                state: state,
                actions: MenuBarActions(
                    close: { [weak self] in self?.close() },
                    resize: { [weak self] size in self?.resize(to: size) }
                )
            )
            let hosting = FirstMouseHostingView(rootView: view)
            hosting.sizingOptions = []
            // Окно обрезается по скруглению панели: иначе у активного окна видны тёмные прямые углы.
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 22
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
            self.panel = panel
        }
        layout(height: panel.frame.height)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        monitor.panelDidOpen()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Пока открыто выпадающее меню внутри панели, она не закрывается.
                guard let self, NSApp.windows.contains(where: { $0.isVisible && $0.level.rawValue > panel.level.rawValue && $0 !== panel }) == false else { return }
                self.close()
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        closedAt = Date()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        item?.button?.highlight(false)
        monitor.panelDidClose()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func resize(to size: CGSize) {
        guard let panel, abs(panel.frame.height - size.height) > 0.5 else { return }
        layout(height: size.height)
    }

    /// Верх панели всегда под значком; по ширине — не вылезает за край экрана.
    private func layout(height: CGFloat) {
        guard let panel else { return }
        let screen = state.screenFrame
        var x = state.anchorX - Self.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - Self.width - 8)
        panel.setFrame(NSRect(x: x, y: state.top - height, width: Self.width, height: height), display: true)
        panel.invalidateShadow()
    }
}

@MainActor
final class MenuBarPanelState: ObservableObject {
    enum Page { case main, freeMemory, cpu, memory }
    @Published var page: Page = .main
    @Published var maxListHeight: CGFloat = 320
    var top: CGFloat = 0
    var anchorX: CGFloat = 0
    var screenFrame: CGRect = .zero
}

struct MenuBarActions {
    let close: () -> Void
    let resize: (CGSize) -> Void
}

// MARK: - Вид панели

struct MenuBarPanelView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var state: MenuBarPanelState
    @ObservedObject private var settings = AppSettings.shared
    let actions: MenuBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.page {
            case .main: main
            case .freeMemory: FreeMemoryView(monitor: monitor, state: state)
            case .cpu: UsageDetailView(monitor: monitor, state: state, kind: .cpu, close: actions.close)
            case .memory: UsageDetailView(monitor: monitor, state: state, kind: .memory, close: actions.close)
            }
        }
        .padding(14)
        .frame(width: MenuBarController.width)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { actions.resize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private var main: some View {
        header
        StatsGrid(monitor: monitor) { page in withAnimation(Motion.panel) { state.page = page } }
        StatusLine(snapshot: monitor.snapshot)
        ScrollView {
            AppLists(monitor: monitor, close: actions.close)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: state.maxListHeight)
        QuickActions(monitor: monitor, keepAwake: keepAwake, state: state, close: actions.close)
        Divider().padding(.horizontal, 4)
        VStack(spacing: 0) {
            MenuRow(title: "Новая заметка") {
                actions.close()
                ToolsHost.newNote()
            }
            MenuRow(title: "Открыть Usin") {
                actions.close()
                ToolsHost.openApp()
            }
            MenuRow(title: "Виджеты…") {
                actions.close()
                Coordinator.shared.openSettings(.widgets)
            }
            MenuRow(title: "Настройки…") {
                actions.close()
                ToolsHost.openSettings(nil)
            }
            MenuRow(title: "Проверить обновления…") {
                actions.close()
                ToolsHost.checkForUpdates()
            }
            MenuRow(title: "Выйти из Usin") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Usin").font(.headline)
            HStack(spacing: 0) {
                ForEach(Module.allCases) { module in
                    ModuleButton(module: module, isOn: settings.isEnabled(module)) {
                        settings.setEnabled(module, !settings.isEnabled(module))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Круглая кнопка модуля, как в Пункте управления: цветная — включён, серая — выключен.
private struct ModuleButton: View {
    let module: Module
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: module.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 36, height: 36)
                // Как в Пункте управления macOS 26: выключено — полупрозрачное стекло, включено — белый кружок с синим значком.
                .background(ControlCircle(isOn: isOn, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: module.title))
        .accessibilityLabel(Text(verbatim: module.title))
        .animation(Motion.hover, value: isOn)
        .animation(Motion.hover, value: hovering)
    }
}

// MARK: - Показатели

private struct StatsGrid: View {
    @ObservedObject var monitor: SystemMonitor
    let show: (MenuBarPanelState.Page) -> Void

    var body: some View {
        let s = monitor.snapshot
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatTile(title: "Процессор", value: Format.percent(s.cpu * 100), detail: nil, history: monitor.cpuHistory.values, scale: 1, tint: .blue) { show(.cpu) }
                StatTile(
                    title: "Память",
                    value: Format.gigabytes(s.memoryUsed),
                    detail: String(format: L("из %@"), Format.gigabytes(s.memoryTotal)),
                    history: monitor.memoryHistory.values,
                    scale: 1,
                    tint: s.memoryPressure >= 4 ? .red : s.memoryPressure >= 2 ? .orange : .green
                ) { show(.memory) }
            }
            GridRow {
                StatTile(
                    title: "Сеть",
                    value: "↓ " + Format.rate(s.download),
                    detail: "↑ " + Format.rate(s.upload),
                    history: monitor.networkHistory.values,
                    scale: max(monitor.networkHistory.values.max() ?? 0, 50_000),
                    tint: .purple
                )
                DiskTile(free: s.diskFree, total: s.diskTotal)
            }
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String?
    let history: [Double]
    let scale: Double
    let tint: Color
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            Text(verbatim: value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: detail ?? " ").font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Sparkline(values: history, scale: scale, tint: tint).frame(height: 22).padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(action != nil && hovering ? 0.1 : 0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .animation(Motion.hover, value: hovering)
    }
}

private struct DiskTile: View {
    let free: Int64
    let total: Int64

    var body: some View {
        let used = total > 0 ? Double(total - free) / Double(total) : 0
        let low = total > 0 && Double(free) / Double(total) < 0.1
        VStack(alignment: .leading, spacing: 2) {
            Text("Диск").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: Format.disk(free)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: String(format: L("свободно из %@"), Format.disk(total))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(low ? Color.orange : Color.gray).frame(width: proxy.size.width * used)
                }
            }
            .frame(height: 6)
            .padding(.vertical, 8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

/// Маленький график за последнюю минуту.
private struct Sparkline: View {
    let values: [Double]
    let scale: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = self.points(in: proxy.size)
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

    private func points(in size: CGSize) -> [CGPoint] {
        let capacity = 40
        guard !values.isEmpty, scale > 0 else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let start = CGFloat(capacity - values.count) * step
        return values.enumerated().map { index, value in
            let ratio = min(max(value / scale, 0), 1)
            return CGPoint(x: start + CGFloat(index) * step, y: size.height - 1 - CGFloat(ratio) * (size.height - 2))
        }
    }
}

/// Батарея, перегрев и нехватка памяти — одной строкой, только когда есть что сказать.
private struct StatusLine: View {
    let snapshot: SystemSnapshot

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.text) { item in
                    Label {
                        Text(verbatim: item.text).lineLimit(1)
                    } icon: {
                        Image(systemName: item.symbol).foregroundStyle(item.tint)
                    }
                    .font(.callout)
                    .foregroundStyle(item.tint == .secondary ? .secondary : .primary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private struct Item { let symbol: String; let text: String; let tint: Color }

    private var items: [Item] {
        var result: [Item] = []
        if let level = snapshot.batteryLevel {
            var text = "\(level)%"
            if let minutes = snapshot.batteryMinutes {
                let time = Format.minutes(minutes)
                text += " · " + String(format: snapshot.onBattery ? L("ещё %@") : L("до полной %@"), time)
            } else if !snapshot.onBattery {
                text += " · " + L("от сети")
            }
            result.append(Item(symbol: batterySymbol(level), text: text, tint: level <= 15 && snapshot.onBattery ? .red : .secondary))
        }
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            result.append(Item(symbol: "thermometer.high", text: L("Mac перегревается — скорость снижена"), tint: .orange))
        }
        if snapshot.memoryPressure >= 4 {
            result.append(Item(symbol: "memorychip", text: L("Не хватает памяти — закройте лишние программы"), tint: .red))
        }
        return result
    }

    private func batterySymbol(_ level: Int) -> String {
        if snapshot.charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Программы

private struct AppLists: View {
    @ObservedObject var monitor: SystemMonitor
    let close: () -> Void
    @State private var showAllApps = false
    @State private var showAllBackground = false

    var body: some View {
        let ordered = monitor.apps.sorted { ($0.notResponding ? 1 : 0, $0.cpu) > ($1.notResponding ? 1 : 0, $1.cpu) }
        let regular = ordered.filter { !$0.isBackground }
        let background = ordered.filter(\.isBackground)
        VStack(alignment: .leading, spacing: 12) {
            if monitor.apps.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                section(title: "Программы", count: regular.count, expanded: $showAllApps) {
                    ForEach(showAllApps ? regular : Array(regular.prefix(6))) { app in
                        AppRow(app: app, isHeavy: monitor.heavyApps.contains(app.pid), quitSymbol: "xmark") {
                            monitor.activate(app.pid)
                            close()
                        } quit: {
                            monitor.quit(app.pid)
                        } force: {
                            monitor.forceQuit(app.pid)
                        }
                    }
                }
                section(title: "В фоне", count: background.count, expanded: $showAllBackground, settings: true) {
                    if background.isEmpty {
                        Text("Ничего не работает в фоне").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6).frame(height: 28)
                    }
                    ForEach(showAllBackground ? background : Array(background.prefix(6))) { app in
                            AppRow(app: app, isHeavy: monitor.heavyApps.contains(app.pid), quitSymbol: "power") {
                                monitor.openBackgroundSettings()
                                close()
                            } quit: {
                                monitor.quit(app.pid)
                            } force: {
                                monitor.forceQuit(app.pid)
                            }
                            .help(Text("Открыть настройки фоновых программ"))
                        }
                }
            }
            if !monitor.ports.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Порты")
                    ForEach(monitor.ports) { port in
                        PortRow(port: port) { monitor.stop(port) }
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        title: LocalizedStringKey, count: Int, expanded: Binding<Bool>, settings: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionTitle(title: title)
                Spacer()
                if settings {
                    Button("Настройки…") {
                        monitor.openBackgroundSettings()
                        close()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if count > 6 {
                    Button {
                        withAnimation(Motion.panel) { expanded.wrappedValue.toggle() }
                    } label: {
                        if expanded.wrappedValue { Text("Свернуть") } else { Text("Все (\(count))") }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            content()
        }
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 2)
    }
}

private struct AppRow: View {
    let app: AppUsage
    let isHeavy: Bool
    let quitSymbol: String
    let open: () -> Void
    let quit: () -> Void
    let force: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app.dashed").resizable() }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: app.name).lineLimit(1)
                if app.notResponding {
                    Text("Не отвечает").font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 6)
            if !app.isProtected, hovering || app.notResponding {
                QuitButton(quit: quit, force: force)
            } else {
                Text(verbatim: Format.percent(app.cpuShare))
                    .foregroundStyle(isHeavy ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 44, alignment: .trailing)
                Text(verbatim: Format.bytes(app.memory))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .frame(height: 30)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network").frame(width: 20).foregroundStyle(.secondary)
            Text(verbatim: "localhost:\(port.port)").monospacedDigit()
            Text(verbatim: port.command).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            IconButton(symbol: "stop.circle.fill", help: "Остановить", tint: hovering ? .red : .secondary, action: stop)
        }
        .font(.callout)
        .frame(height: 28)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
        }
        .onHover { hovering = $0 }
        .help(Text("Открыть в браузере"))
    }
}

private struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Быстрые действия

private struct QuickActions: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var state: MenuBarPanelState
    @ObservedObject private var meetings = Coordinator.shared.meetings
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("На 1 час") { keepAwake.turnOn(hours: 1) }
                Button("На 3 часа") { keepAwake.turnOn(hours: 3) }
                Button("Пока не выключу") { keepAwake.turnOn(hours: nil) }
                if keepAwake.isOn {
                    Divider()
                    Button("Выключить") { keepAwake.turnOff() }
                }
            } label: {
                QuickTile(symbol: keepAwake.isOn ? "cup.and.heat.waves.fill" : "cup.and.heat.waves", title: keepAwakeTitle, isOn: keepAwake.isOn, tint: .orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            Button {
                withAnimation(Motion.panel) { state.page = .freeMemory }
            } label: {
                QuickTile(symbol: "memorychip", title: L("Освободить память"), isOn: false, tint: .green)
            }
            .buttonStyle(.plain)

            Button {
                meetings.toggle()
            } label: {
                QuickTile(symbol: meetings.isRecording ? "stop.circle.fill" : "record.circle", title: meetings.isRecording ? L("Стоп") : L("Встреча"), isOn: meetings.isRecording, tint: .red)
            }
            .buttonStyle(.plain)

            Button {
                close()
                Coordinator.shared.clipboard.togglePanel()
            } label: {
                QuickTile(symbol: "doc.on.clipboard", title: L("Буфер"), isOn: false, tint: .blue)
            }
            .buttonStyle(.plain)
            .disabled(!AppSettings.shared.isEnabled(.clipboard))
        }
    }

    private var keepAwakeTitle: String {
        guard keepAwake.isOn else { return L("Не засыпать") }
        guard let until = keepAwake.until else { return L("Не спит") }
        return String(format: L("До %@"), until.formatted(date: .omitted, time: .shortened))
    }
}

private struct QuickTile: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let tint: Color
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 32, height: 32)
                .background(ControlCircle(isOn: isOn, hovering: false))
            Text(verbatim: title)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct MenuRow: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Освободить память

private struct FreeMemoryView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: MenuBarPanelState
    @State private var candidates: [AppUsage] = []
    @State private var selected: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.panel) { state.page = .main }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Освободить память").font(.headline)
            }
            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(.green)
                    Text("Все программы использовались недавно").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                Text("Эти программы не открывали больше двух часов. Несохранённые документы программы предложат сохранить.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(candidates) { app in
                            Toggle(isOn: Binding(
                                get: { selected.contains(app.pid) },
                                set: { if $0 { selected.insert(app.pid) } else { selected.remove(app.pid) } }
                            )) {
                                HStack(spacing: 8) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                                    Text(verbatim: app.name).lineLimit(1)
                                    Spacer()
                                    Text(verbatim: Format.bytes(app.memory)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .font(.callout)
                            .frame(height: 28)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: state.maxListHeight)
                let total = candidates.filter { selected.contains($0.pid) }.reduce(UInt64(0)) { $0 + $1.memory }
                HStack {
                    Text(verbatim: "≈ " + Format.bytes(total)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Закрыть выбранные") {
                        monitor.quitAll(Array(selected))
                        withAnimation(Motion.panel) { state.page = .main }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onAppear {
            candidates = monitor.idleApps()
            selected = Set(candidates.map(\.pid))
        }
    }
}

// MARK: - Подробно: процессор или память

/// Какие программы сколько занимают. Открывается нажатием на плитку «Процессор» или «Память».
private struct UsageDetailView: View {
    enum Kind { case cpu, memory }

    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: MenuBarPanelState
    let kind: Kind
    let close: () -> Void

    var body: some View {
        let s = monitor.snapshot
        let apps = monitor.apps.sorted { value($0) > value($1) }
        let total = kind == .cpu ? s.cpu * 100 : Double(s.memoryUsed)
        let rest = max(total - apps.reduce(0) { $0 + value($1) }, 0)
        let largest = max(apps.map(value).max() ?? 0, rest, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.panel) { state.page = .main }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(L(kind == .cpu ? "Процессор" : "Память")).font(.headline)
                Spacer()
                Text(verbatim: kind == .cpu ? Format.percent(s.cpu * 100) : Format.gigabytes(s.memoryUsed))
                    .font(.headline).monospacedDigit()
            }
            Text(verbatim: subtitle(s))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(apps) { app in
                        UsageRow(
                            icon: app.icon.map { Image(nsImage: $0) },
                            name: app.name,
                            notResponding: app.notResponding,
                            value: format(value(app)),
                            fraction: value(app) / largest,
                            tint: kind == .cpu ? .blue : .green,
                            quitSymbol: app.isProtected ? nil : app.isBackground ? "power" : "xmark",
                            quitHelp: app.isBackground ? "Выключить" : "Закрыть"
                        ) {
                            if app.isBackground { monitor.openBackgroundSettings() } else { monitor.activate(app.pid) }
                            close()
                        } quit: {
                            monitor.quit(app.pid)
                        } force: {
                            monitor.forceQuit(app.pid)
                        }
                    }
                    if rest > 0 {
                        UsageRow(
                            icon: Image(systemName: "apple.logo"),
                            name: L("macOS и системные службы"),
                            notResponding: false,
                            value: format(rest),
                            fraction: rest / largest,
                            tint: .gray,
                            quitSymbol: nil,
                            quitHelp: ""
                        ) {} quit: {} force: {}
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: state.maxListHeight + 160)
        }
    }

    private func value(_ app: AppUsage) -> Double {
        kind == .cpu ? app.cpuShare : Double(app.memory)
    }

    private func format(_ value: Double) -> String {
        kind == .cpu ? Format.percent(value) : Format.bytes(UInt64(value))
    }

    private func subtitle(_ s: SystemSnapshot) -> String {
        switch kind {
        case .cpu:
            return L("100% — заняты все ядра процессора. Чем больше у программы, тем сильнее она грузит Mac и батарею.")
        case .memory:
            return String(format: L("Занято %@ из %@."), Format.gigabytes(s.memoryUsed), Format.gigabytes(s.memoryTotal))
        }
    }
}

private struct UsageRow: View {
    let icon: Image?
    let name: String
    let notResponding: Bool
    let value: String
    let fraction: Double
    let tint: Color
    let quitSymbol: String?
    let quitHelp: LocalizedStringKey
    let open: () -> Void
    let quit: () -> Void
    let force: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { icon.resizable().scaledToFit() } else { Image(systemName: "app.dashed").resizable() }
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: name).lineLimit(1)
                    if notResponding { Text("Не отвечает").font(.caption2).foregroundStyle(.red) }
                    Spacer(minLength: 4)
                    if hovering, quitSymbol != nil {
                        QuitButton(quit: quit, force: force).frame(height: 16)
                    } else {
                        Text(verbatim: value).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(tint).frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 3))
                    }
                }
                .frame(height: 4)
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering && quitSymbol != nil ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// Кружок кнопки в стиле Пункта управления.
private struct ControlCircle: View {
    let isOn: Bool
    let hovering: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(.white)
            } else {
                Circle().fill(.primary.opacity(hovering ? 0.16 : 0.1))
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isOn ? 0.12 : 0), radius: 3, y: 1)
    }
}

/// Одна кнопка ✕: нажали — программа закрывается, как по ⌘Q (спросит про несохранённое).
/// Удержали полторы секунды — закрывается принудительно; пока держите, вокруг заполняется красное кольцо.
struct QuitButton: View {
    let quit: () -> Void
    let force: () -> Void
    static let holdDuration: Double = 1.5

    @State private var pressing = false
    @State private var fired = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 20, height: 20)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(pressing ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0.06)))
        }
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 30) {
            fired = true
            force()
        } onPressingChanged: { isPressing in
            if isPressing {
                fired = false
                withAnimation(.linear(duration: Self.holdDuration)) { pressing = true }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { pressing = false }
                if !fired { quit() }
            }
        }
        .help(Text("Закрыть. Удерживайте 1,5 секунды, чтобы закрыть принудительно"))
        .accessibilityLabel(Text("Закрыть"))
        .accessibilityAction(named: Text("Закрыть принудительно"), force)
    }
}
