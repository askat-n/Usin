import Foundation
import SwiftData
import SwiftUI
import AuthenticationServices

/// Синхронизация заметок через скрытую папку приложения на Google Drive.
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case off
        case connecting
        case syncing
        case idle
        case failed(String)
    }

    private static let snapshotName = "byeknow-snapshot.json"

    let context: ModelContext
    private let auth = GoogleAuth()

    var status: Status
    var lastSync: Date?
    var email: String?
    var isConnected: Bool
    /// На устройстве и на Drive есть заметки — ждём ответа «стереть и подключить?».
    var needsReplaceConfirmation = false

    private var isApplying = false
    private var pending = false
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        isConnected = auth.isSignedIn
        email = auth.email
        status = auth.isSignedIn ? .idle : .off
        lastSync = UserDefaults.standard.object(forKey: "sync.lastSync") as? Date
    }

    // MARK: - Connect / disconnect

    func connect(using session: WebAuthenticationSession) async {
        status = .connecting
        do {
            try await auth.signIn(using: session)
            email = auth.email
            let remote = try await fetchRemote().snapshot
            let local = SyncSnapshot.current(in: context)
            if local.hasUserData && remote.hasUserData {
                needsReplaceConfirmation = true
                status = .off
                return
            }
            finishConnecting()
            await syncNow()
        } catch {
            auth.signOut()
            email = nil
            status = Self.isCancel(error) ? .off : .failed(Self.message(for: error))
        }
    }

    /// «Да, стереть и подключить»: всё на устройстве заменяется заметками с Drive.
    func confirmReplace() async {
        needsReplaceConfirmation = false
        finishConnecting()
        await syncNow(replaceLocal: true)
    }

    /// «Нет»: ничего не меняем и не подключаем.
    func cancelConnect() {
        needsReplaceConfirmation = false
        auth.signOut()
        email = nil
        status = .off
    }

    func disconnect() {
        auth.signOut()
        isConnected = false
        email = nil
        status = .off
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: "sync.lastSync")
        try? FileManager.default.removeItem(at: Self.baseURL)
        stopPeriodic()
    }

    private func finishConnecting() {
        auth.persist()
        isConnected = true
        status = .idle
        try? FileManager.default.removeItem(at: Self.baseURL)
        startPeriodic()
    }

    // MARK: - Triggers

    /// После правок — синхронизировать через пару секунд (правки подряд склеиваются).
    func scheduleSync(after seconds: Double = 2) {
        guard isConnected, !isApplying else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// Пока приложение открыто — забирать правки с других устройств каждые 20 секунд.
    func startPeriodic() {
        guard isConnected else { return }
        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await syncNow()
            }
        }
    }

    func stopPeriodic() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Sync

    func syncNow(replaceLocal: Bool = false) async {
        guard isConnected else { return }
        if status == .syncing {
            pending = true
            return
        }
        status = .syncing
        do {
            try await performSync(replaceLocal: replaceLocal)
            status = .idle
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "sync.lastSync")
        } catch {
            if !auth.isSignedIn {
                isConnected = false
                status = .failed(tr("Войди в Google ещё раз"))
            } else {
                status = .failed(Self.message(for: error))
            }
        }
        if pending {
            pending = false
            await syncNow()
        }
    }

    private func performSync(replaceLocal: Bool) async throws {
        let (remote, files, drive) = try await fetchRemote()
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let base = replaceLocal ? SyncSnapshot() : loadBase()

        func mergedNow() -> SyncSnapshot {
            if replaceLocal { return remote.sanitized().sorted() }
            var local = SyncSnapshot.current(in: context)
            local.adoptRoot(from: remote)
            return SyncSnapshot.merge(base: base, local: local, remote: remote)
        }

        // Картинки: загрузить свои новые, скачать чужие.
        let localImages = SyncSnapshot.localImages(in: context)
        let needed = Set(mergedNow().blocks.compactMap(\.imageHash))
        var images = localImages
        for hash in needed {
            let name = "img-\(hash)"
            if let data = localImages[hash] {
                if byName[name] == nil { try await drive.create(name: name, data: data) }
            } else if let file = byName[name] {
                images[hash] = try await drive.download(file.id)
            }
        }

        // Слияние считаем заново прямо перед записью — вдруг пока качали, что-то поправили.
        let merged = mergedNow()
        isApplying = true
        defer { isApplying = false }
        try merged.apply(to: context, images: images)

        if merged != remote {
            let data = try JSONEncoder().encode(merged)
            if let file = byName[Self.snapshotName] {
                try await drive.update(id: file.id, data: data)
            } else {
                try await drive.create(name: Self.snapshotName, data: data)
            }
        }
        saveBase(merged)
    }

    private func fetchRemote() async throws -> (snapshot: SyncSnapshot, files: [DriveFile], drive: DriveClient) {
        let drive = DriveClient(token: try await auth.validAccessToken())
        let files = try await drive.list()
        var snapshot = SyncSnapshot()
        if let file = files.first(where: { $0.name == Self.snapshotName }) {
            snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: try await drive.download(file.id))
        }
        return (snapshot, files, drive)
    }

    // MARK: - Base (state after the last sync)

    private static var baseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ByeKnow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-base.json")
    }

    private func loadBase() -> SyncSnapshot {
        guard let data = try? Data(contentsOf: Self.baseURL),
              let snapshot = try? JSONDecoder().decode(SyncSnapshot.self, from: data) else { return SyncSnapshot() }
        return snapshot
    }

    private func saveBase(_ snapshot: SyncSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.baseURL, options: .atomic) }
    }

    // MARK: - Errors

    private static func isCancel(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            || error is CancellationError
    }

    private static func message(for error: Error) -> String {
        if error is URLError { return tr("Нет интернета или Google не отвечает") }
        return error.localizedDescription
    }
}
