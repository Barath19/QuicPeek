import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "PeecMCP")

@MainActor
final class PeecMCP: ObservableObject {
    static let shared = PeecMCP()

    @Published private(set) var tools: [MCPTool] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let endpoint = URL(string: "https://api.peec.ai/mcp")!
    private var initialized: Bool = false
    private var nextID: Int = 1

    struct MCPTool: Identifiable, Hashable {
        let name: String
        let title: String?
        let description: String
        let readOnly: Bool
        var id: String { name }
    }

    struct Project: Identifiable, Hashable {
        let id: String
        let name: String
        let status: String
    }

    func clear() {
        tools = []
        projects = []
        lastError = nil
        initialized = false
    }

    private func ensureInitialized(token: String) async throws {
        guard !initialized else { return }
        _ = try await call(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "QuicPeek", "version": "0.1"],
        ], token: token)
        initialized = true
        log.info("mcp initialized")
    }

    func refreshTools() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await PeecOAuth.shared.validAccessToken()
            try await ensureInitialized(token: token)

            let result = try await call(method: "tools/list", params: [:], token: token)
            guard let list = result["tools"] as? [[String: Any]] else {
                throw MCPError.malformed("tools array missing")
            }
            tools = list.compactMap { dict -> MCPTool? in
                guard let name = dict["name"] as? String else { return nil }
                let annotations = dict["annotations"] as? [String: Any]
                let readOnly = (annotations?["readOnlyHint"] as? Bool) ?? false
                return MCPTool(
                    name: name,
                    title: dict["title"] as? String,
                    description: (dict["description"] as? String) ?? "",
                    readOnly: readOnly
                )
            }
            lastError = nil
            log.info("fetched \(self.tools.count, privacy: .public) tools")
        } catch {
            lastError = error.localizedDescription
            log.error("refreshTools failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshProjects() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await PeecOAuth.shared.validAccessToken()
            try await ensureInitialized(token: token)

            let result = try await call(
                method: "tools/call",
                params: ["name": "list_projects", "arguments": [:]],
                token: token
            )
            projects = try Self.parseProjects(from: result)
            lastError = nil
            log.info("fetched \(self.projects.count, privacy: .public) projects")
        } catch {
            lastError = error.localizedDescription
            log.error("refreshProjects failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Peec returns `tools/call` results as `{content: [{type: "text", text: "<json string>"}]}`
    /// where the inner JSON is a columnar table: `{columns, rows, rowCount}`.
    private static func parseProjects(from result: [String: Any]) throws -> [Project] {
        guard let content = result["content"] as? [[String: Any]],
              let firstText = content.first?["text"] as? String,
              let data = firstText.data(using: .utf8),
              let table = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = table["columns"] as? [String],
              let rows = table["rows"] as? [[Any]] else {
            throw MCPError.malformed("unexpected list_projects payload")
        }
        let idIdx = columns.firstIndex(of: "id")
        let nameIdx = columns.firstIndex(of: "name")
        let statusIdx = columns.firstIndex(of: "status")
        guard let idIdx, let nameIdx, let statusIdx else {
            throw MCPError.malformed("missing project columns")
        }
        return rows.compactMap { row in
            guard row.count > max(idIdx, nameIdx, statusIdx),
                  let id = row[idIdx] as? String,
                  let name = row[nameIdx] as? String,
                  let status = row[statusIdx] as? String
            else { return nil }
            return Project(id: id, name: name, status: status)
        }
    }

    private func call(method: String, params: [String: Any], token: String) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let id = nextID; nextID += 1
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MCPError.http(code: code, body: String(decoding: data, as: UTF8.self))
        }

        let text = String(decoding: data, as: UTF8.self)
        let jsonText = Self.extractJSON(from: text)

        guard let jsonData = jsonText.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MCPError.malformed("couldn't parse response")
        }

        if let err = parsed["error"] as? [String: Any] {
            throw MCPError.rpc(message: err["message"] as? String ?? "unknown")
        }
        guard let result = parsed["result"] as? [String: Any] else {
            throw MCPError.malformed("no result field")
        }
        return result
    }

    /// Peec returns MCP responses as SSE ("event: message\ndata: {...}"). Handle both SSE and plain JSON.
    private static func extractJSON(from text: String) -> String {
        let dataLines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("data: ") }
            .map { $0.dropFirst(6) }
        if dataLines.isEmpty { return text }
        return dataLines.joined()
    }

    enum MCPError: LocalizedError {
        case http(code: Int, body: String)
        case rpc(message: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .rpc(let msg): return "MCP error: \(msg)"
            case .malformed(let what): return "Malformed response (\(what))"
            }
        }
    }
}
