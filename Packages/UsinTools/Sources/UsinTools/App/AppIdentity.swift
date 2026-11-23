import Foundation

/// Обычный Usin или «Usin Beta» — тестовая сборка, которую запускает разработчик (Scripts/beta.sh).
/// У беты свой идентификатор, свои настройки и своя папка данных, поэтому настоящие заметки она не трогает.
public enum AppIdentity {
    public static let releaseBundleID = "com.askatbek.usin"
    public static let betaBundleID = "com.askatbek.usin.beta"

    public static var isBeta: Bool { Bundle.main.bundleIdentifier == betaBundleID }

    /// Папка в Application Support: «Usin» или «Usin Beta».
    public static var folderName: String { isBeta ? "Usin Beta" : "Usin" }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }
}
