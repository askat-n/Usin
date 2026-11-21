import Foundation

/// Данные для системных виджетов macOS («Изменить виджеты»). Usin пишет их в общую папку группы,
/// расширение виджетов читает. Расширение работает в песочнице и само собирать эти данные не может.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var cpu: Double
        public var memory: UInt64
        public init(name: String, cpu: Double, memory: UInt64) {
            self.name = name
            self.cpu = cpu
            self.memory = memory
        }
    }

    public struct Limit: Codable, Equatable, Sendable {
        public var provider: String
        public var title: String
        public var used: Double
        public var resetsAt: Date?
        public init(provider: String, title: String, used: Double, resetsAt: Date?) {
            self.provider = provider
            self.title = title
            self.used = used
            self.resetsAt = resetsAt
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var link: URL?
        public init(title: String, start: Date, end: Date, link: URL?) {
            self.title = title
            self.start = start
            self.end = end
            self.link = link
        }
    }

    public var date: Date
    public var cpu: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryPressure: Int
    public var diskFree: Int64
    public var diskTotal: Int64
    public var batteryLevel: Int?
    public var charging: Bool
    public var onBattery: Bool
    public var batteryMinutes: Int?
    public var apps: [App]
    public var limits: [Limit]
    public var nextEvent: Event?
    public var calendarAllowed: Bool

    public init(date: Date = Date(), cpu: Double = 0, memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0, memoryPressure: Int = 1,
                diskFree: Int64 = 0, diskTotal: Int64 = 0, batteryLevel: Int? = nil, charging: Bool = false, onBattery: Bool = false,
                batteryMinutes: Int? = nil, apps: [App] = [], limits: [Limit] = [], nextEvent: Event? = nil, calendarAllowed: Bool = false) {
        self.date = date
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryPressure = memoryPressure
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.batteryLevel = batteryLevel
        self.charging = charging
        self.onBattery = onBattery
        self.batteryMinutes = batteryMinutes
        self.apps = apps
        self.limits = limits
        self.nextEvent = nextEvent
        self.calendarAllowed = calendarAllowed
    }

    /// Группа приложений с префиксом команды: такой группе на macOS не нужен профиль обеспечения.
    public static let appGroup = "A3R7X7XVXB.com.askatbek.usin"
    public static let fileName = "widget-snapshot.json"

    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = Self.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
