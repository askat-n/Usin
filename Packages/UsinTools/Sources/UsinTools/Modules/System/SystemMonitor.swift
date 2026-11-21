import AppKit
import ApplicationServices
import Darwin
import IOKit.ps
import IOKit.pwr_mgt
import UsinToolsCore
@preconcurrency import UserNotifications

/// Запущенная программа с тем, сколько она сейчас ест.
struct AppUsage: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let isBackground: Bool
    /// Процент одного ядра, как в «Мониторинге системы»: 100 — одно ядро целиком.
    var cpu: Double
    var memory: UInt64
    var notResponding = false
    /// Все процессы фоновой программы (у служебных процессов без значка их бывает несколько).
    var pids: [pid_t] = []

    var id: pid_t { pid }

    /// Finder нельзя закрыть из панели: без него пропадают окна с файлами и рабочий стол.
    var isProtected: Bool { AppUsage.isProtected(bundleID) }

    static func isProtected(_ bundleID: String?) -> Bool {
        bundleID == "com.apple.finder"
    }

    /// Доля всего процессора Mac: 100% — заняты все ядра. Так понятнее, чем проценты одного ядра.
    var cpuShare: Double { cpu / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1)) }

    static func == (lhs: AppUsage, rhs: AppUsage) -> Bool {
        lhs.pid == rhs.pid && lhs.cpu == rhs.cpu && lhs.memory == rhs.memory && lhs.notResponding == rhs.notResponding
    }
}

/// Сводка по Mac для панели в строке меню.
struct SystemSnapshot: Equatable {
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// 1 — всё хорошо, 2 — памяти мало, 4 — критично (как `kern.memorystatus_vm_pressure_level`).
    var memoryPressure: Int = 1
    var download: Double = 0
    var upload: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var batteryLevel: Int?
    var charging = false
    var onBattery = false
    /// Минуты до разряда (от батареи) или до полной зарядки (на зарядке).
    var batteryMinutes: Int?
    var thermal: ProcessInfo.ThermalState = .nominal
}

/// Собирает данные о Mac. Пока панель открыта — часто и подробно; когда закрыта — изредка и только то,
/// что нужно для цифр в строке меню и предупреждений о прожорливых программах.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory = History()
    @Published private(set) var memoryHistory = History()
    @Published private(set) var networkHistory = History()
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var ports: [ListeningPort] = []
    /// Программы, которые сейчас долго грузят процессор.
    @Published private(set) var heavyApps: Set<pid_t> = []

    let keepAwake = KeepAwake()

    private let settings = AppSettings.shared
    private let sampler = ProcessSampler()
    private var timer: Timer?
    private var portsTimer: Timer?
    private var panelOpen = false
    private var heavyTracker = HeavyUsageTracker()
    private var lastActive: [pid_t: Date] = [:]
    private let started = Date()
    private var activationObserver: NSObjectProtocol?
    private let iconCache = IconCache()

    /// Кто-то смотрит на цифры (панель или строка меню) — значит, есть смысл замерять.
    var onUpdate: (() -> Void)?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.lastActive[app.processIdentifier] = Date() }
            }
        }
        HeavyAppAlerts.shared.install()
    }

    // MARK: - Ритм замеров

    /// Вызывается при смене настроек и открытии/закрытии панели.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        let interval: TimeInterval
        if panelOpen {
            interval = 1.5
        } else if widgetDemand.system || widgetDemand.apps {
            interval = 3
        } else if settings.menuBarStats != "off" {
            interval = 3
        } else if settings.heavyAppAlerts {
            interval = 10
        } else if exportDemand {
            interval = 30
        } else {
            return
        }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = interval * 0.2
    }

    /// Что нужно виджетам на рабочем столе: общие цифры, список программ, порты.
    struct WidgetDemand: Equatable {
        var system = false
        var apps = false
        var ports = false
    }

    /// Системным виджетам macOS хватает замера раз в полминуты.
    var exportDemand = false {
        didSet { if exportDemand != oldValue { reschedule() } }
    }

    var widgetDemand = WidgetDemand() {
        didSet {
            guard widgetDemand != oldValue else { return }
            reschedule()
            updatePortsTimer()
        }
    }

    private func updatePortsTimer() {
        let needed = panelOpen || widgetDemand.ports
        if needed, portsTimer == nil {
            refreshPorts()
            portsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPorts() }
            }
        } else if !needed {
            portsTimer?.invalidate()
            portsTimer = nil
        }
    }

    func panelDidOpen() {
        panelOpen = true
        reschedule()
        refreshPorts()
        updatePortsTimer()
    }

    func panelDidClose() {
        panelOpen = false
        updatePortsTimer()
        reschedule()
    }

    private var sampling = false

    private func sample() {
        guard !sampling else { return }
        sampling = true
        let wantApps = panelOpen || settings.heavyAppAlerts || widgetDemand.apps || exportDemand
        let checkHangs = panelOpen && AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications
        let own = NSRunningApplication.current.processIdentifier
        let candidates = running.compactMap { app -> AppCandidate? in
            guard app.processIdentifier != own, app.processIdentifier > 0,
                  app.activationPolicy == .regular || Self.isUserBackgroundApp(app) else { return nil }
            return AppCandidate(
                pid: app.processIdentifier,
                bundlePath: app.bundleURL?.path,
                isRegular: app.activationPolicy == .regular
            )
        }
        let sampler = self.sampler
        Task.detached(priority: .utility) {
            let system = sampler.sampleSystem()
            let usage = wantApps ? sampler.sampleApps(candidates) : ProcessSampler.Sample()
            let hung = checkHangs ? sampler.unresponsive(candidates.filter(\.isRegular).map(\.pid)) : []
            await MainActor.run { [weak self] in
                self?.apply(system: system, usage: usage, hung: hung, running: running)
            }
        }
    }

    private func apply(system: SystemSnapshot, usage sample: ProcessSampler.Sample, hung: Set<pid_t>, running: [NSRunningApplication]) {
        let usage = sample.apps
        sampling = false
        var system = system
        fillBattery(&system)
        if system != snapshot { snapshot = system }
        cpuHistory.append(system.cpu)
        memoryHistory.append(system.memoryTotal > 0 ? Double(system.memoryUsed) / Double(system.memoryTotal) : 0)
        networkHistory.append(system.download + system.upload)

        guard !usage.isEmpty else {
            onUpdate?()
            return
        }
        let byPid = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [AppUsage] = []
        for (pid, value) in usage {
            guard let app = byPid[pid], !app.isTerminated else { continue }
            list.append(AppUsage(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "—",
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                isBackground: app.activationPolicy != .regular,
                cpu: value.cpu,
                memory: value.memory,
                notResponding: hung.contains(pid)
            ))
        }
        for group in sample.background {
            guard let first = group.pids.min() else { continue }
            let isBundle = group.key.hasSuffix(".app")
            let name = isBundle
                ? FileManager.default.displayName(atPath: group.key).replacingOccurrences(of: ".app", with: "")
                : URL(fileURLWithPath: group.key).lastPathComponent
            var item = AppUsage(
                pid: first,
                name: name,
                bundleID: isBundle ? Bundle(path: group.key)?.bundleIdentifier : nil,
                icon: isBundle ? iconCache.icon(for: group.key) : nil,
                isBackground: true,
                cpu: group.cpu,
                memory: group.memory
            )
            item.pids = group.pids.sorted()
            list.append(item)
        }
        list.sort { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        if panelOpen || widgetDemand.apps || exportDemand, list != apps { apps = list }

        // Прожорливые: не та программа, с которой человек сейчас работает, — её он и так видит.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let tracked = Dictionary(list.filter { $0.pid != front }.map { ("\($0.pid)", $0.cpu) }, uniquingKeysWith: { a, _ in a })
        let alerts = heavyTracker.update(tracked, at: Date())
        let heavy = Set(list.filter { $0.pid != front && $0.cpu >= heavyTracker.threshold }.map(\.pid))
        if heavy != heavyApps { heavyApps = heavy }
        if settings.heavyAppAlerts {
            for key in alerts {
                guard let pid = pid_t(key), let app = list.first(where: { $0.pid == pid }), !app.isProtected else { continue }
                HeavyAppAlerts.shared.post(app)
            }
        }
        onUpdate?()
    }

    private func fillBattery(_ system: inout SystemSnapshot) {
        system.thermal = ProcessInfo.processInfo.thermalState
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  raw[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = raw[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(raw[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            system.batteryLevel = current * 100 / maximum
            system.charging = raw[kIOPSIsChargingKey] as? Bool ?? false
            system.onBattery = (raw[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let key = system.onBattery ? kIOPSTimeToEmptyKey : kIOPSTimeToFullChargeKey
            if let minutes = raw[key] as? Int, minutes > 0, minutes < 24 * 60, system.onBattery || system.charging {
                system.batteryMinutes = minutes
            }
            return
        }
    }

    /// Фоновые программы человека: агенты, значки в строке меню. Системные службы Apple не показываем.
    static func isUserBackgroundApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy != .regular, let bundle = app.bundleURL?.path, let id = app.bundleIdentifier else { return false }
        if id.hasPrefix("com.apple.") || bundle.hasPrefix("/System/") || bundle.hasPrefix("/usr/") { return false }
        // Помощник внутри другой программы («Claude Helper») — часть самой программы, а не отдельная фоновая.
        return bundle.hasSuffix(".app") && !URL(fileURLWithPath: bundle).deletingLastPathComponent().path.contains(".app")
    }

    // MARK: - Порты

    private var portsLoading = false

    func refreshPorts() {
        guard !portsLoading else { return }
        portsLoading = true
        Task.detached(priority: .utility) {
            let found = Self.listeningPorts()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.portsLoading = false
                if found != self.ports { self.ports = found }
            }
        }
    }

    nonisolated private static func listeningPorts() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let own = getpid()
        // Службы macOS (AirPlay, Handoff) не трогаем: показываем только то, что запустил человек.
        let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]
        return ListeningPort.parse(lsof: String(decoding: data, as: UTF8.self)).filter { port in
            guard port.pid != own, let path = processPath(port.pid) else { return false }
            return !system.contains { path.hasPrefix($0) }
        }
    }

    // MARK: - Действия

    func quit(_ pid: pid_t) {
        if let group = apps.first(where: { $0.pid == pid && !$0.pids.isEmpty }) {
            // Фоновые процессы без значка закрываются сигналом — как «Завершить» в «Мониторинге системы».
            group.pids.forEach { kill($0, SIGTERM) }
            scheduleRefresh()
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !AppUsage.isProtected(app.bundleIdentifier) else { return }
        app.terminate()
        scheduleRefresh()
    }

    /// Принудительно и без вопросов — как просили.
    func forceQuit(_ pid: pid_t) {
        if AppUsage.isProtected(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) { return }
        if let group = apps.first(where: { $0.pid == pid && !$0.pids.isEmpty }) {
            group.pids.forEach { kill($0, SIGKILL) }
            apps.removeAll { $0.pid == pid }
            scheduleRefresh()
            return
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.forceTerminate() {
            apps.removeAll { $0.pid == pid }
        } else {
            kill(pid, SIGKILL)
        }
        scheduleRefresh()
    }

    /// Останавливает процесс на порту: сначала вежливо, через секунду — принудительно.
    func stop(_ port: ListeningPort) {
        let pid = port.pid
        kill(pid, SIGTERM)
        ports.removeAll { $0.pid == pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            MainActor.assumeIsolated { self?.refreshPorts() }
        }
    }

    func activate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Настройки macOS со списком программ, которым разрешено работать в фоне.
    func openBackgroundSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    // MARK: - Освободить память

    /// Программы с окнами, которыми не пользовались больше `hours` часов.
    func idleApps(hours: Double = 2) -> [AppUsage] {
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return apps.filter { usage in
            guard !usage.isBackground, usage.pid != front, usage.bundleID != "com.apple.finder",
                  let app = NSRunningApplication(processIdentifier: usage.pid) else { return false }
            let last = lastActive[usage.pid] ?? max(started, app.launchDate ?? started)
            return now.timeIntervalSince(last) >= hours * 3600
        }
        .sorted { $0.memory > $1.memory }
    }

    func quitAll(_ pids: [pid_t]) {
        for pid in pids { quit(pid) }
        scheduleRefresh()
    }

    // MARK: - Строка меню

    /// Короткие цифры для строки меню, например «23% · 8,1 ГБ».
    var menuBarText: String? {
        let cpu = "\(Int((snapshot.cpu * 100).rounded()))%"
        let memory = Format.gigabytes(snapshot.memoryUsed)
        switch settings.menuBarStats {
        case "cpu": return cpu
        case "memory": return memory
        case "both": return "\(cpu)  \(memory)"
        default: return nil
        }
    }
}

/// Значки фоновых программ по пути к пакету: читать их с диска каждые полторы секунды незачем.
@MainActor
private final class IconCache {
    private var icons: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// Путь к исполняемому файлу процесса.
private func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : nil
}

private struct AppCandidate: Sendable {
    let pid: pid_t
    let bundlePath: String?
    let isRegular: Bool
}

/// Низкоуровневые замеры. Работает в фоне и не трогает интерфейс.
private final class ProcessSampler: @unchecked Sendable {
    struct Usage: Sendable {
        var cpu: Double
        var memory: UInt64
    }

    private let lock = NSLock()
    private var lastTicks: CPUTicks?
    private var lastNetwork: (bytesIn: UInt64, bytesOut: UInt64, time: TimeInterval)?
    private var lastCPU: [pid_t: (ns: UInt64, time: TimeInterval)] = [:]
    private var identity: [pid_t: (path: String, parent: pid_t)] = [:]
    private var diskCache: (free: Int64, total: Int64, time: TimeInterval)?
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sampleSystem() -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = SystemSnapshot()
        let now = ProcessInfo.processInfo.systemUptime

        if let ticks = Self.cpuTicks() {
            if let lastTicks { snapshot.cpu = CPUTicks.usage(from: lastTicks, to: ticks) }
            lastTicks = ticks
        }

        snapshot.memoryUsed = Self.memoryUsed()
        snapshot.memoryPressure = Self.memoryPressure()

        let (bytesIn, bytesOut) = Self.networkBytes()
        if let last = lastNetwork, now > last.time, bytesIn >= last.bytesIn, bytesOut >= last.bytesOut {
            snapshot.download = Double(bytesIn - last.bytesIn) / (now - last.time)
            snapshot.upload = Double(bytesOut - last.bytesOut) / (now - last.time)
        }
        lastNetwork = (bytesIn, bytesOut, now)

        // Место на диске меняется медленно, а спрашивать о нём дорого.
        if let cache = diskCache, now - cache.time < 30 {
            snapshot.diskFree = cache.free
            snapshot.diskTotal = cache.total
        } else {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            snapshot.diskFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
            snapshot.diskTotal = Int64(values?.volumeTotalCapacity ?? 0)
            diskCache = (snapshot.diskFree, snapshot.diskTotal, now)
        }
        return snapshot
    }

    struct BackgroundGroup: Sendable {
        let key: String
        var pids: [pid_t]
        var cpu: Double
        var memory: UInt64
    }

    struct Sample: Sendable {
        var apps: [pid_t: Usage] = [:]
        var background: [BackgroundGroup] = []
    }

    private enum Owner {
        case app(pid_t)
        case background(String)
        case system
    }

    /// Пути системы: процессы оттуда — это macOS, их не показываем и не предлагаем закрыть.
    private static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/", "/Library/Developer/CommandLineTools/"]

    /// Загрузка программ вместе с их помощниками и дочерними процессами: вкладки Chrome, процессы Electron,
    /// сервер, запущенный из Терминала, — всё считается в программу, которая их породила.
    /// Остальные процессы человека, запущенные системой при входе (агенты, помощники обновлений), — это «В фоне».
    func sampleApps(_ apps: [AppCandidate]) -> Sample {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        var owners: [(prefix: String, pid: pid_t)] = apps.compactMap { app in
            guard let path = app.bundlePath else { return nil }
            return (path.hasSuffix("/") ? path : path + "/", app.pid)
        }
        // Самый длинный путь — первым: программа внутри другой программы (Simulator в Xcode) считается отдельно.
        owners.sort { $0.prefix.count > $1.prefix.count }
        let appPids = Set(apps.map(\.pid))
        let ownBundle = Bundle.main.bundlePath + "/"
        let own = getpid()

        let pids = Self.allPids()
        // Путь и родитель у процесса не меняются: узнаём их один раз, пока процесс жив.
        var paths: [pid_t: String] = [:]
        var parents: [pid_t: pid_t] = [:]
        for pid in pids {
            if let known = identity[pid] {
                paths[pid] = known.path
                parents[pid] = known.parent
                continue
            }
            let path = Self.path(of: pid) ?? ""
            let parent = Self.parent(of: pid) ?? 1
            paths[pid] = path
            parents[pid] = parent
            identity[pid] = (path, parent)
        }
        let alive = Set(pids)
        identity = identity.filter { alive.contains($0.key) }

        var resolved: [pid_t: Owner] = [:]
        func resolve(_ pid: pid_t, depth: Int = 0) -> Owner {
            if let known = resolved[pid] { return known }
            var owner: Owner
            let path = paths[pid] ?? ""
            if appPids.contains(pid) {
                owner = .app(pid)
            } else if pid == own || path.hasPrefix(ownBundle) || path.isEmpty {
                owner = .system
            } else if path.contains(".app/"), let match = owners.first(where: { path.hasPrefix($0.prefix) }) {
                owner = .app(match.pid)
            } else {
                let isSystem = Self.systemPrefixes.contains { path.hasPrefix($0) }
                let parent = parents[pid] ?? 1
                var parentOwner: Owner = .system
                if parent > 1, depth < 40 { parentOwner = resolve(parent, depth: depth + 1) }
                switch parentOwner {
                case .app, .background: owner = parentOwner
                case .system: owner = isSystem ? .system : .background(Self.groupKey(for: path))
                }
            }
            resolved[pid] = owner
            return owner
        }

        var sample = Sample()
        sample.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, Usage(cpu: 0, memory: 0)) })
        var groups: [String: BackgroundGroup] = [:]
        var seenCPU: [pid_t: (ns: UInt64, time: TimeInterval)] = [:]
        for pid in pids {
            let owner = resolve(pid)
            if case .system = owner { continue }
            guard let info = Self.rusage(pid) else { continue }
            let ns = UInt64(Double(info.ri_user_time + info.ri_system_time) * timebase)
            seenCPU[pid] = (ns, now)
            var cpu = 0.0
            if let last = lastCPU[pid], now > last.time, ns >= last.ns {
                cpu = Double(ns - last.ns) / ((now - last.time) * 1e9) * 100
            }
            switch owner {
            case .app(let app):
                sample.apps[app, default: Usage(cpu: 0, memory: 0)].cpu += cpu
                sample.apps[app, default: Usage(cpu: 0, memory: 0)].memory += info.ri_phys_footprint
            case .background(let key):
                groups[key, default: BackgroundGroup(key: key, pids: [], cpu: 0, memory: 0)].pids.append(pid)
                groups[key]?.cpu += cpu
                groups[key]?.memory += info.ri_phys_footprint
            case .system:
                break
            }
        }
        lastCPU = seenCPU
        sample.background = Array(groups.values)
        return sample
    }

    /// Группа фоновых процессов — по внешнему пакету `.app` или по самому исполняемому файлу.
    private static func groupKey(for path: String) -> String {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Программы, которые не отвечают: на запрос Accessibility нет ответа за четверть секунды два раза подряд.
    private var suspect: Set<pid_t> = []

    func unresponsive(_ pids: [pid_t]) -> Set<pid_t> {
        var failed = [Bool](repeating: false, count: pids.count)
        failed.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: pids.count) { index in
                let element = AXUIElementCreateApplication(pids[index])
                AXUIElementSetMessagingTimeout(element, 0.25)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
                pointer[index] = error == .cannotComplete
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let now = Set(zip(pids, failed).filter(\.1).map(\.0))
        let confirmed = now.intersection(suspect)
        suspect = now
        return confirmed
    }

    // MARK: Системные вызовы

    private static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, idle: idle)
    }

    /// «Использовано памяти», как в «Мониторинге системы»: память программ + неперемещаемая + сжатая.
    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private static func memoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    /// Байты через Wi‑Fi и Ethernet (интерфейсы en*). 64‑битные счётчики не переполняются на больших загрузках.
    private static func networkBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        bytesIn += info.ifm_data.ifi_ibytes
                        bytesOut += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (bytesIn, bytesOut)
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? { processPath(pid) }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }
}

// MARK: - Не засыпать

/// Не даёт Mac уснуть и погасить экран: на час, на три или пока не выключат.
@MainActor
final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    /// Когда выключится само; nil — пока не выключат.
    @Published private(set) var until: Date?

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func turnOn(hours: Double?) {
        if !isOn {
            let created = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Usin: не засыпать" as CFString,
                &assertion
            )
            guard created == kIOReturnSuccess else { return }
            isOn = true
        }
        timer?.invalidate()
        timer = nil
        if let hours {
            let end = Date().addingTimeInterval(hours * 3600)
            until = end
            timer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.turnOff() }
            }
        } else {
            until = nil
        }
    }

    func turnOff() {
        timer?.invalidate()
        timer = nil
        if isOn { IOPMAssertionRelease(assertion) }
        isOn = false
        until = nil
    }
}

// MARK: - Предупреждения

/// Уведомление «Программа долго грузит процессор» с кнопками «Закрыть» и «Закрыть принудительно».
final class HeavyAppAlerts: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = HeavyAppAlerts()
    private let category = "usin.heavyApp"
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let quit = UNNotificationAction(identifier: "quit", title: L("Закрыть"))
        let force = UNNotificationAction(identifier: "force", title: L("Закрыть принудительно"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [quit, force], intentIdentifiers: [])])
    }

    @MainActor
    func post(_ app: AppUsage) {
        let center = UNUserNotificationCenter.current()
        let category = self.category
        let title = app.name
        let body = L("Уже несколько минут сильно грузит процессор. Закрыть?")
        let pid = Int(app.pid)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = ["pid": pid]
            center.add(UNNotificationRequest(identifier: "heavy-\(pid)", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pid = response.notification.request.content.userInfo["pid"] as? Int else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            let monitor = Coordinator.shared.system
            switch action {
            case "quit": monitor.quit(pid_t(pid))
            case "force": monitor.forceQuit(pid_t(pid))
            default: ToolsRuntime.showMenuBarPanel()
            }
        }
    }
}

// MARK: - Форматы

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func gigabytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func disk(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Скорость сети: «1,2 МБ/с».
    static func rate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = value < 1_000_000 ? [.useKB] : [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(value)) + L("/с")
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// «2 ч 15 мин» или «40 мин».
    static func minutes(_ value: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = value >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(value * 60)) ?? ""
    }
}
