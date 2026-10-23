import Foundation
import CryptoKit
import Security
import AuthenticationServices
import SwiftUI

enum GoogleConfig {
    /// OAuth Client ID (тип iOS) из Google Cloud Console. Не секрет.
    static let clientID = "202618515633-uughsb9c9erqf0dlvefhg1uvkqe3r4f9.apps.googleusercontent.com"
    static var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    static var redirectURI: String { redirectScheme + ":/oauthredirect" }
    /// drive.appdata — только скрытая папка приложения, остальной Drive приложение не видит.
    static let scopes = "openid email https://www.googleapis.com/auth/drive.appdata"
}

enum SyncError: LocalizedError {
    case notSignedIn
    case noAuthCode
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn, .noAuthCode: tr("Войди в Google ещё раз")
        case .server(let code, let message): "\(code): \(message)"
        }
    }
}

/// Вход через Google (OAuth 2.0 с PKCE) и хранение токена в Связке ключей.
final class GoogleAuth {
    private static let refreshKey = "google.refreshToken"
    private static let emailKey = "google.email"

    private(set) var email: String? = UserDefaults.standard.string(forKey: emailKey)
    private var refreshToken: String? = Keychain.read(refreshKey)
    private var accessToken: String?
    private var expiresAt = Date.distantPast

    /// Токен сохранён на устройстве — значит, Drive подключён.
    var isSignedIn: Bool { Keychain.read(Self.refreshKey) != nil }

    /// Адрес страницы входа Google и проверочный код к нему (PKCE).
    func makeSignInRequest() -> (url: URL, verifier: String) {
        let verifier = Self.randomString(64)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleConfig.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return (components.url!, verifier)
    }

    /// iPhone/iPad: окно входа Google внутри приложения.
    func signIn(using session: WebAuthenticationSession) async throws {
        let request = makeSignInRequest()
        let callback = try await session.authenticate(using: request.url, callbackURLScheme: GoogleConfig.redirectScheme)
        try await finishSignIn(callback: callback, verifier: request.verifier)
    }

    /// Google вернул в приложение адрес с кодом — меняем код на токен.
    /// Токен пока держим в памяти — сохраняем только после `persist()`.
    func finishSignIn(callback: URL, verifier: String) async throws {
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw SyncError.noAuthCode }

        let json = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": GoogleConfig.redirectURI,
            "client_id": GoogleConfig.clientID,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw SyncError.noAuthCode }
        refreshToken = refresh
        store(json)
        if let idToken = json["id_token"] as? String { email = Self.email(fromIDToken: idToken) }
    }

    /// Запомнить вход на устройстве (после согласия пользователя).
    func persist() {
        guard let refreshToken else { return }
        Keychain.save(refreshToken, for: Self.refreshKey)
        UserDefaults.standard.set(email, forKey: Self.emailKey)
    }

    func signOut() {
        Keychain.delete(Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        refreshToken = nil
        accessToken = nil
        email = nil
        expiresAt = .distantPast
    }

    func validAccessToken() async throws -> String {
        if let accessToken, Date() < expiresAt.addingTimeInterval(-60) { return accessToken }
        guard let refreshToken else { throw SyncError.notSignedIn }
        let json = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": GoogleConfig.clientID,
        ])
        store(json)
        guard let accessToken else { throw SyncError.notSignedIn }
        return accessToken
    }

    // MARK: - Private

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3000
        expiresAt = Date().addingTimeInterval(seconds)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            if json["error"] as? String == "invalid_grant" {
                signOut()
                throw SyncError.notSignedIn
            }
            let message = json["error_description"] as? String ?? String(decoding: data, as: UTF8.self)
            throw SyncError.server(status, message)
        }
        return json
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

/// Минимальная обёртка над Связкой ключей для одной строки.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ByeKnow",
            kSecAttrAccount as String: key,
        ]
    }

    static func save(_ value: String, for key: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
