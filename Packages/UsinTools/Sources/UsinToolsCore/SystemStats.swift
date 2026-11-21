import Foundation

/// Счётчики процессора (тики), из которых считается загрузка между двумя замерами.
public struct CPUTicks: Equatable, Sendable {
    public var busy: UInt64
    public var idle: UInt64

    public init(busy: UInt64, idle: UInt64) {
        self.busy = busy
        self.idle = idle
    }

    /// Доля занятого времени от 0 до 1 между двумя замерами.
    public static func usage(from old: CPUTicks, to new: CPUTicks) -> Double {
        let busy = new.busy &- old.busy
        let idle = new.idle &- old.idle
        let total = busy &+ idle
        guard total > 0, new.busy >= old.busy, new.idle >= old.idle else { return 0 }
        return min(max(Double(busy) / Double(total), 0), 1)
    }
}

/// Программа, которая слушает сетевой порт (например, сервер разработки на localhost:3000).
public struct ListeningPort: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let command: String
    public let port: Int

    public var id: String { "\(pid):\(port)" }

    public init(pid: Int32, command: String, port: Int) {
        self.pid = pid
        self.command = command
        self.port = port
    }

    /// Разбирает вывод `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`: строки вида `p123`, `cnode`, `n*:3000`.
    public static func parse(lsof output: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = String(value)
            case "n":
                // Адрес вида «127.0.0.1:5173», «*:3000» или «[::1]:8080» — порт всегда после последнего двоеточия.
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let item = ListeningPort(pid: pid, command: command, port: port)
                if seen.insert(item.id).inserted { result.append(item) }
            default:
                continue
            }
        }
        return result.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }
}

/// Замечает программы, которые долго и сильно грузят процессор.
/// Срабатывает один раз за эпизод: снова — только после того, как программа успокоилась.
public struct HeavyUsageTracker: Sendable {
    /// Загрузка в процентах одного ядра, как в «Мониторинге системы» (100 = одно ядро целиком).
    public var threshold: Double
    /// Сколько секунд подряд нагрузка должна держаться.
    public var duration: TimeInterval

    private var since: [String: Date] = [:]
    private var reported: Set<String> = []

    public init(threshold: Double = 80, duration: TimeInterval = 180) {
        self.threshold = threshold
        self.duration = duration
    }

    /// Принимает свежий замер (ключ программы → загрузка) и возвращает ключи, о которых пора сказать.
    public mutating func update(_ usage: [String: Double], at now: Date) -> [String] {
        var alerts: [String] = []
        for (key, value) in usage {
            if value >= threshold {
                let start = since[key] ?? now
                since[key] = start
                if now.timeIntervalSince(start) >= duration, !reported.contains(key) {
                    reported.insert(key)
                    alerts.append(key)
                }
            } else {
                since[key] = nil
                reported.remove(key)
            }
        }
        // Закрытые программы забываем.
        for key in since.keys where usage[key] == nil { since[key] = nil }
        reported = reported.filter { usage[$0] != nil }
        return alerts.sorted()
    }
}

/// История значений для маленького графика: хранит последние `capacity` точек.
public struct History: Sendable, Equatable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int = 40) {
        self.capacity = capacity
    }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}
