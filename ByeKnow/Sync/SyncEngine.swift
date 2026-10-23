import Foundation
import SwiftData
import SwiftUI
import AuthenticationServices
#if os(macOS)
import AppKit
#endif

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

    /// Общий файл первой версии синхронизации — читаем только при переходе на журналы.
    private static let legacyName = "byeknow-snapshot.json"
    static let pollInterval: Double = 1

    let context: ModelContext
    private let auth = GoogleAuth()

    var status: Status
    var lastSync: Date?
    var email: String?
    var isConnected: Bool
    /// На устройстве и на Drive есть заметки — ждём ответа «стереть и подключить?».
    var needsReplaceConfirmation = false
    /// Есть правки на устройстве, которые ещё не дошли до Google Drive.
    var hasUnsavedChanges = false
    private var editCount = 0

    /// Журнал этого устройства (все записи со временем изменения).
    private var ledger: Ledger?
    /// Последний отправленный на Drive журнал.
    private var lastUploaded: Ledger?
    /// Скачанные журналы других устройств и их версии на Drive.
    private var remoteCache: [String: (version: String?, ledger: Ledger)] = [:]
    private var ownFileID: String?
    private var driveImages: Set<String> = []
    /// Картинки, которые нужны, но ещё не скачаны.
    private var missingImages: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "sync.missingImages") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "sync.missingImages") }
    }
    private var isBusy = false

    private var isApplying = false
    private var connectAttempt = 0
    private var browserContinuation: CheckedContinuation<URL, Error>?
    private var pending = false
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        isConnected = auth.isSignedIn
        email = auth.email
        status = auth.isSignedIn ? .idle : .off
        lastSync = UserDefaults.standard.object(forKey: "sync.lastSync") as? Date
        ledger = Self.loadLedger()
    }

    /// Свой файл на Drive у каждого устройства.
    private static var deviceFileName: String {
        let key = "sync.deviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: key)
            return new
        }()
        return "device-\(id).json"
    }

    // MARK: - Connect / disconnect

    func connect(using session: WebAuthenticationSession) async {
        status = .connecting
        connectAttempt += 1
        let attempt = connectAttempt
        do {
            #if os(macOS)
            try await signInInBrowser(attempt: attempt)
            #else
            try await auth.signIn(using: session)
            #endif
            guard attempt == connectAttempt else { return } // нажали «Отмена»
            email = auth.email
            let remoteHasData = try await fetchRemoteHasData()
            let local = SyncSnapshot.current(in: context)
            if local.hasUserData && remoteHasData {
                needsReplaceConfirmation = true
                status = .off
                return
            }
            finishConnecting()
            await syncNow()
        } catch {
            guard attempt == connectAttempt else { return }
            auth.signOut()
            email = nil
            status = Self.isCancel(error) ? .off : .failed(Self.message(for: error))
        }
    }

    /// Отменить подключение, пока ждём входа в Google.
    func cancelConnecting() {
        connectAttempt += 1
        browserContinuation?.resume(throwing: CancellationError())
        browserContinuation = nil
        auth.signOut()
        email = nil
        status = .off
    }

    #if os(macOS)
    /// Mac: вход в обычном браузере. Google возвращает в приложение адрес
    /// `com.googleusercontent.apps…:/oauthredirect?code=…`, его ловит `handleRedirect`.
    private func signInInBrowser(attempt: Int) async throws {
        let request = auth.makeSignInRequest()
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            browserContinuation = continuation
            NSWorkspace.shared.open(request.url)
            // Не ждать вечно: через 5 минут считаем, что вход отменён.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.connectAttempt == attempt, let c = self.browserContinuation else { return }
                self.browserContinuation = nil
                c.resume(throwing: CancellationError())
            }
        }
        try await auth.finishSignIn(callback: callback, verifier: request.verifier)
    }
    #endif

    /// Браузер вернул нас в приложение после входа в Google.
    func handleRedirect(_ url: URL) {
        guard url.scheme == GoogleConfig.redirectScheme, let continuation = browserContinuation else { return }
        browserContinuation = nil
        continuation.resume(returning: url)
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
        resetSyncState()
        stopPeriodic()
    }

    private func finishConnecting() {
        auth.persist()
        isConnected = true
        status = .idle
        resetSyncState()
        startPeriodic()
    }

    // MARK: - Triggers

    /// После правок — отправить через 0,3 с (правки подряд склеиваются).
    func scheduleSync(after seconds: Double = 0.3) {
        guard isConnected, !isApplying else { return }
        editCount += 1
        hasUnsavedChanges = true
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// Пока приложение открыто — каждую секунду отправлять свои правки и проверять чужие.
    func startPeriodic() {
        guard isConnected else { return }
        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await pollRemote()
            }
        }
    }

    func stopPeriodic() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Sync

    /// Каждую секунду: сохранить свои правки и спросить у Drive, не поменялось ли что-то.
    /// Если ничего не поменялось — это один короткий запрос, облачко не мигает.
    func pollRemote() async {
        guard isConnected, !isBusy, status != .connecting else { return }
        // Не ждём автосохранения базы (оно бывает раз в несколько секунд) — сохраняем сами.
        if context.hasChanges, (try? context.save()) != nil {
            editCount += 1
            hasUnsavedChanges = true
        }
        await syncNow()
    }

    func syncNow(replaceLocal: Bool = false) async {
        guard isConnected else { return }
        if isBusy {
            pending = true
            return
        }
        isBusy = true
        let editsAtStart = editCount
        do {
            try await performSync(replaceLocal: replaceLocal)
            status = .idle
            // Правки, сделанные во время синхронизации, ещё не на Drive.
            if editCount == editsAtStart { hasUnsavedChanges = false }
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
        isBusy = false
        if pending {
            pending = false
            await syncNow()
        }
    }

    private func performSync(replaceLocal: Bool) async throws {
        let drive = DriveClient(token: try await auth.validAccessToken())
        let files = try await drive.list()
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let ownName = Self.deviceFileName
        ownFileID = byName[ownName]?.id
        driveImages = Set(files.compactMap { $0.name.hasPrefix("img-") ? String($0.name.dropFirst(4)) : nil })

        let deviceFiles = files.filter { $0.name.hasPrefix("device-") && $0.name != ownName }
        let remoteChanged = deviceFiles.contains { file in
            guard let cached = remoteCache[file.name], let version = file.version else { return true }
            return cached.version != version
        } || remoteCache.keys.contains { name in !deviceFiles.contains { $0.name == name } }
        let firstBuild = ledger == nil || replaceLocal
        let missing = missingImages.intersection(driveImages)

        // Ничего не поменялось ни тут, ни там — выходим после одного запроса.
        if !replaceLocal, !firstBuild, !remoteChanged, !hasUnsavedChanges, missing.isEmpty,
           ownFileID != nil, lastUploaded != nil {
            return
        }

        // 1. Скачать журналы других устройств, которые изменились.
        var remotes: [Ledger] = []
        for file in deviceFiles {
            if let cached = remoteCache[file.name], file.version != nil, cached.version == file.version {
                remotes.append(cached.ledger)
                continue
            }
            status = .syncing
            let ledger = try JSONDecoder().decode(Ledger.self, from: try await drive.download(file.id))
            remoteCache[file.name] = (file.version, ledger)
            remotes.append(ledger)
        }
        remoteCache = remoteCache.filter { name, _ in deviceFiles.contains { $0.name == name } }

        // Первая версия синхронизации хранила всё в одном общем файле.
        var legacy: SyncSnapshot?
        if firstBuild, let file = byName[Self.legacyName] {
            status = .syncing
            var snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: try await drive.download(file.id))
            snapshot.remapRoot()
            legacy = snapshot
            remotes.append(Ledger(legacy: snapshot))
        }

        // 2. Скачать картинки, которых на устройстве нет.
        let preview = Ledger.merge([ledger ?? Ledger()] + remotes).snapshot
        let localHashes = localImageHashes()
        var wanted = Set(preview.blocks.compactMap(\.imageHash)).subtracting(localHashes).union(missing)
        wanted.formIntersection(driveImages)
        var images: [String: Data] = [:]
        for hash in wanted {
            guard let file = byName["img-\(hash)"] else { continue }
            status = .syncing
            images[hash] = try await drive.download(file.id)
        }

        // 3. Записать правки устройства в журнал и объединить с остальными.
        //    Между чтением устройства и записью на него нет ожиданий — правки не потеряются.
        let now = Date()
        var merged: Ledger
        var localChanged = false
        if replaceLocal {
            merged = Ledger.merge(remotes)
        } else {
            var mine = ledger ?? Ledger()
            let before = mine
            let local = SyncSnapshot.current(in: context)
            mine.record(local, now: now, firstStamp: firstBuild ? firstStamp(legacy: legacy, now: now) : { _ in now })
            localChanged = mine != before
            merged = Ledger.merge([mine] + remotes)
        }

        let target = merged.snapshot
        if replaceLocal || remoteChanged || firstBuild || !images.isEmpty
            || target != SyncSnapshot.current(in: context) {
            isApplying = true
            defer { isApplying = false }
            var stillMissing = try target.apply(to: context, images: images)
            stillMissing.formUnion(missingImages.subtracting(images.keys))
            try repairImages(images)
            missingImages = stillMissing
        }
        ledger = merged
        Self.saveLedger(merged)

        // 4. Отправить свой журнал, если на этом устройстве что-то изменилось.
        if localChanged || replaceLocal || ownFileID == nil || lastUploaded == nil {
            status = .syncing
            try await uploadImages(for: target, drive: drive)
            let data = try JSONEncoder().encode(merged)
            if let id = ownFileID {
                try await drive.update(id: id, data: data)
            } else {
                ownFileID = try await drive.create(name: ownName, data: data).id
            }
            lastUploaded = merged
        }
    }

    /// Какое время поставить записи, которую журнал видит впервые
    /// (переход с первой версии синхронизации или первое подключение).
    private func firstStamp(legacy: SyncSnapshot?, now: Date) -> (any SyncRecord) -> Date {
        var base = Self.loadLegacyBase()
        base?.remapRoot()
        let encoder = JSONEncoder()
        func index(_ s: SyncSnapshot?) -> [UUID: Data] {
            guard let s else { return [:] }
            var result: [UUID: Data] = [:]
            for r in s.themes { result[r.id] = try? encoder.encode(r) }
            for r in s.nodes { result[r.id] = try? encoder.encode(r) }
            for r in s.blocks { result[r.id] = try? encoder.encode(r) }
            for r in s.connections { result[r.id] = try? encoder.encode(r) }
            return result
        }
        let legacyIndex = index(legacy)
        let baseIndex = index(base)
        return { rec in
            let data = try? encoder.encode(rec)
            if legacyIndex[rec.id] == data { return Ledger.legacyStamp }
            // Сфера по умолчанию на новом устройстве не должна перебить настроенную.
            if let node = rec as? NodeRecord, node.isRoot,
               node.title == "ByeKnow", node.x == 0, node.y == 0, node.fillIndex == 6, node.inkIndex == 0 {
                return Ledger.freshRootStamp
            }
            if baseIndex[rec.id] == data { return Ledger.staleCopyStamp }
            return now
        }
    }

    /// Есть ли на Drive чьи-то заметки (для вопроса «стереть и заменить?»).
    private func fetchRemoteHasData() async throws -> Bool {
        let drive = DriveClient(token: try await auth.validAccessToken())
        for file in try await drive.list() {
            if file.name.hasPrefix("device-") {
                let ledger = try JSONDecoder().decode(Ledger.self, from: try await drive.download(file.id))
                if ledger.hasUserData { return true }
            } else if file.name == Self.legacyName {
                let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: try await drive.download(file.id))
                if snapshot.hasUserData { return true }
            }
        }
        return false
    }

    // MARK: - Images

    private func localImageHashes() -> Set<String> {
        let blocks = (try? context.fetch(FetchDescriptor<NoteBlock>())) ?? []
        return Set(blocks.compactMap { $0.kind == .image ? $0.imageHash : nil }).subtracting(missingImages)
    }

    /// Докачанные картинки — в блоки, которые их ждали.
    private func repairImages(_ images: [String: Data]) throws {
        for (hash, data) in images {
            let wanted: String? = hash
            let d = FetchDescriptor<NoteBlock>(predicate: #Predicate { $0.imageHash == wanted })
            for block in (try? context.fetch(d)) ?? [] { block.setImage(data) }
        }
        if context.hasChanges { try context.save() }
    }

    private func uploadImages(for snapshot: SyncSnapshot, drive: DriveClient) async throws {
        for hash in Set(snapshot.blocks.compactMap(\.imageHash)) where !driveImages.contains(hash) {
            let wanted: String? = hash
            var d = FetchDescriptor<NoteBlock>(predicate: #Predicate { $0.imageHash == wanted })
            d.fetchLimit = 1
            guard let data = try? context.fetch(d).first?.imageData else { continue }
            try await drive.create(name: "img-\(hash)", data: data)
            driveImages.insert(hash)
        }
    }

    // MARK: - Local state

    private static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ByeKnow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var ledgerURL: URL { supportDir.appendingPathComponent("sync-ledger.json") }
    /// Состояние после последней синхронизации из первой версии.
    private static var legacyBaseURL: URL { supportDir.appendingPathComponent("sync-base.json") }

    private static func loadLedger() -> Ledger? {
        guard let data = try? Data(contentsOf: ledgerURL) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: data)
    }

    private static func saveLedger(_ ledger: Ledger) {
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL, options: .atomic) }
    }

    private static func loadLegacyBase() -> SyncSnapshot? {
        guard let data = try? Data(contentsOf: legacyBaseURL) else { return nil }
        return try? JSONDecoder().decode(SyncSnapshot.self, from: data)
    }

    private func resetSyncState() {
        try? FileManager.default.removeItem(at: Self.ledgerURL)
        try? FileManager.default.removeItem(at: Self.legacyBaseURL)
        ledger = nil
        lastUploaded = nil
        remoteCache = [:]
        ownFileID = nil
        driveImages = []
        missingImages = []
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
