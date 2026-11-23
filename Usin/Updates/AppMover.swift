#if os(macOS)
import AppKit
import UsinTools

/// Как в других приложениях Mac: Usin открыли прямо из скачанного образа (или из «Загрузок») —
/// предлагаем перенести его в «Программы». Копируем, открываем копию и извлекаем образ.
@MainActor
enum AppMover {
    static func offerMoveIfNeeded() {
        #if DEBUG
        return
        #else
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = current.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return }
        // Из образа macOS запускает приложение по временному пути AppTranslocation.
        let fromImage = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
        let fromDownloads = path.hasPrefix(home + "/Downloads/")
        guard fromImage || fromDownloads else { return }
        // Ждём, пока приложение запустится, — иначе окно вопроса появится раньше самого Usin.
        DispatchQueue.main.async { ask(current: current) }
        #endif
    }

    private static func ask(current: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Перенести Usin в «Программы»?")
        alert.informativeText = L("Так Usin останется на Mac, будет обновляться сам, а скачанный образ можно будет удалить.")
        alert.addButton(withTitle: L("Перенести"))
        alert.addButton(withTitle: L("Не сейчас"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(current.lastPathComponent)
        let fm = FileManager.default
        do {
            // Старая версия уходит в корзину, а не стирается насовсем.
            if fm.fileExists(atPath: destination.path) {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                where app.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    app.terminate()
                }
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: current, to: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = L("Не удалось перенести Usin")
            failed.informativeText = L("Перетащи Usin в папку «Программы» сам.")
            failed.runModal()
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            return
        }
        relaunch(destination, ejecting: imageVolumes())
    }

    /// Подключённые образы Usin — их извлекаем после переноса.
    private static func imageVolumes() -> [String] {
        let id = Bundle.main.bundleIdentifier
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { volume in
            volume.path.hasPrefix("/Volumes/Usin")
                && Bundle(url: volume.appendingPathComponent("Usin.app"))?.bundleIdentifier == id
        }.map(\.path)
    }

    /// Запущенную копию не заменить изнутри: маленький скрипт ждёт нашего выхода, открывает Usin
    /// из «Программ» и извлекает образ.
    private static func relaunch(_ app: URL, ejecting volumes: [String]) {
        let script = """
        pid="$1"; app="$2"; shift 2
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        xattr -dr com.apple.quarantine "$app" 2>/dev/null
        open "$app"
        for volume in "$@"; do hdiutil detach "$volume" -quiet || hdiutil detach "$volume" -force -quiet; done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "usin-move", String(ProcessInfo.processInfo.processIdentifier), app.path] + volumes
        do { try process.run() } catch {
            NSWorkspace.shared.open(app)
        }
        Updater.shared.beforeRelaunch?()
        NSApp.terminate(nil)
    }
}
#endif
