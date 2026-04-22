import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "PeecMCP")

@MainActor
final class PeecMCP: ObservableObject {
    static let shared = PeecMCP()

    @Published private(set) var tools: [MCPTool] = []
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

    func clear() {
        tools = []
        lastError = nil
        initialized = false
    }

    func refreshTools() async {
        guard let token = PeecOAuth.shared.accessToken else {
            lastError = "Not connected to Peec."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            if !initialized {
                _ = try await call(method: "initialize", params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "QuicPeek", "version": "0.1"],
                ], token: token)
                initialized = true
                log.info("mcp initialized")
            }

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
