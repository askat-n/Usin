import AppKit
import UsinToolsCore
import WidgetKit

/// Готовит данные для системных виджетов Usin (те, что добавляются через «Изменить виджеты»).
/// macOS сама решает, когда их перерисовать, — обычно раз в несколько минут, поэтому здесь
/// данные пишутся в общую папку, а перерисовка запрашивается не чаще раза в 5 минут.
@MainActor
final class SystemWidgetExporter {
    /// Виды системных виджетов; совпадают с `kind` в расширении.
    enum Kind {
        static let system = "usin.system"
        static let battery = "usin.battery"
        static let limits = "usin.limits"
        static let meeting = "usin.meeting"
    }

    private var timer: Timer?
    private var installed: Set<String> = []
    private var lastReload = Date.distantPast
    private var lastSaved: WidgetSnapshot?
    /// Первые полминуты после запуска замеры идут в любом случае, чтобы первый снимок был настоящим.
    private var warmingUp = true

    func start() {
        Coordinator.shared.system.exportDemand = true
        checkInstalled()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 10
        // Первый снимок — после двух замеров: загрузку процессора можно посчитать только между ними.
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self else { return }
            self.warmingUp = false
            self.write(force: true)
            self.apply(self.installed)
        }
    }

    private func tick() {
        // Проверка дешёвая, а без неё только что добавленный виджет ждал бы данных до 10 минут.
        checkInstalled()
        if !installed.isEmpty, !warmingUp { write(force: false) }
    }

    /// Какие системные виджеты Usin человек поставил: только для них собираем данные.
    private func checkInstalled() {
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let kinds = Set((try? result.get())?.map(\.kind) ?? [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(kinds) }
            }
        }
    }

    private func apply(_ kinds: Set<String>) {
        let added = !kinds.subtracting(installed).isEmpty
        installed = kinds
        let coordinator = Coordinator.shared
        coordinator.system.exportDemand = warmingUp || kinds.contains(Kind.system) || kinds.contains(Kind.battery)
        if kinds.contains(Kind.limits) { coordinator.limits.retain("system-widgets") } else { coordinator.limits.release("system-widgets") }
        if kinds.contains(Kind.meeting) { coordinator.widgets.calendar.retain("system-widgets") } else { coordinator.widgets.calendar.release("system-widgets") }
        if added, !warmingUp { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.write(force: true) } }
    }

    private func write(force: Bool) {
        let coordinator = Coordinator.shared
        let s = coordinator.system.snapshot
        let calendar = coordinator.widgets.calendar
        var limits: [WidgetSnapshot.Limit] = []
        for provider in AILimitsMonitor.providers {
            for window in coordinator.limits.windows[provider] ?? [] {
                limits.append(.init(provider: provider.title, title: window.title, used: window.usedPercent, resetsAt: window.resetsAt))
            }
        }
        let snapshot = WidgetSnapshot(
            cpu: s.cpu,
            memoryUsed: s.memoryUsed,
            memoryTotal: s.memoryTotal,
            memoryPressure: s.memoryPressure,
            diskFree: s.diskFree,
            diskTotal: s.diskTotal,
            batteryLevel: s.batteryLevel,
            charging: s.charging,
            onBattery: s.onBattery,
            batteryMinutes: s.batteryMinutes,
            apps: coordinator.system.apps.filter { !$0.isBackground }.prefix(5).map { .init(name: $0.name, cpu: $0.cpuShare, memory: $0.memory) },
            limits: limits,
            nextEvent: calendar.next.map { .init(title: $0.title, start: $0.start, end: $0.end, link: $0.link) },
            calendarAllowed: calendar.access == .fullAccess
        )
        do {
            try snapshot.save()
        } catch {
            NSLog("Usin: widget snapshot not saved: \(error)")
            return
        }
        // Перерисовка у macOS ограничена, поэтому просим её редко: при заметных изменениях или раз в 5 минут.
        let changed = lastSaved.map { Self.differs($0, snapshot) } ?? true
        if force || (changed && Date().timeIntervalSince(lastReload) > 300) {
            WidgetCenter.shared.reloadAllTimelines()
            lastReload = Date()
        }
        lastSaved = snapshot
    }

    private static func differs(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        abs(a.cpu - b.cpu) > 0.1 || a.batteryLevel != b.batteryLevel || a.limits != b.limits || a.nextEvent != b.nextEvent
            || a.memoryPressure != b.memoryPressure || a.apps.first?.name != b.apps.first?.name
    }
}
