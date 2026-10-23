import Foundation

struct DriveFile: Decodable {
    let id: String
    let name: String
    /// Растёт при каждом изменении файла — по нему видно, менялся ли снимок.
    var version: String?
}

/// Скрытая папка приложения на Google Drive (appDataFolder): список, скачать, загрузить.
struct DriveClient {
    let token: String

    func list() async throws -> [DriveFile] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "fields", value: "files(id,name,version)"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        struct Response: Decodable { let files: [DriveFile] }
        let data = try await send(URLRequest(url: components.url!))
        return try JSONDecoder().decode(Response.self, from: data).files
    }

    func download(_ id: String) async throws -> Data {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        return try await send(URLRequest(url: url))
    }

    @discardableResult
    func create(name: String, data: Data) async throws -> DriveFile {
        let boundary = "byeknow-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try JSONDecoder().decode(DriveFile.self, from: try await send(request))
    }

    func update(id: String, data: Data) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media")!)
        request.httpMethod = "PATCH"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await send(request)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SyncError.server(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
