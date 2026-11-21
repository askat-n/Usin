import Foundation

// MCP-сервер ByeKnow: JSON-RPC 2.0 через stdin/stdout, по сообщению на строку.
// Папка с заметками: аргумент `--folder <путь>` или переменная BYEKNOW_NOTES_DIR.

let version = "1.2.0"
let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

func log(_ s: String) {
    FileHandle.standardError.write(Data(("[byeknow-mcp] " + s + "\n").utf8))
}

func folderPath() -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--folder"), i + 1 < args.count { return args[i + 1] }
    if let env = ProcessInfo.processInfo.environment["BYEKNOW_NOTES_DIR"], !env.isEmpty { return env }
    return nil
}

guard let rawPath = folderPath() else {
    log("Не указана папка с заметками: --folder <путь> или BYEKNOW_NOTES_DIR")
    exit(2)
}
let folder = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: true)
let tools = Tools(vault: Vault(root: folder))
log("папка: \(folder.path)")

func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(_ id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

@MainActor func handle(_ msg: [String: Any]) {
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    // Уведомления (без id) ответа не ждут.
    guard let id = msg["id"], !(id is NSNull) else { return }

    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String ?? supportedProtocols[0]
        reply(id, result: [
            "protocolVersion": supportedProtocols.contains(asked) ? asked : supportedProtocols[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "byeknow", "title": "ByeKnow", "version": version],
            "instructions": "Заметки ByeKnow — общая память о пользователе для всех ИИ. Экономь токены: overview → search_notes/list_notes(theme) → related_notes → read_note только нужного (длинное — outline, потом section). Память о пользователе — тема «Память»; правила записи и названия заметок — в заметке «Инструкция для ИИ» (прочитай её один раз, прежде чем писать). Узнал о пользователе или его проектах что-то новое и важное — запиши через write_note по этим правилам, в существующую заметку, не создавая копий.",
        ])
    case "ping":
        reply(id, result: [String: Any]())
    case "tools/list":
        reply(id, result: ["tools": Tools.definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try tools.call(name, args)
            reply(id, result: ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            reply(id, result: ["content": [["type": "text", "text": "\(error)"]], "isError": true])
        }
    case "resources/list":
        reply(id, result: ["resources": [Any]()])
    case "prompts/list":
        reply(id, result: ["prompts": [Any]()])
    default:
        fail(id, code: -32601, "Method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    if let batch = obj as? [[String: Any]] {
        batch.forEach(handle)
    } else if let msg = obj as? [String: Any] {
        handle(msg)
    }
}
