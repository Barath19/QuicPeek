import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "PeecMCP")

@MainActor
final class PeecMCP: ObservableObject {
    static let shared = PeecMCP()

    @Published private(set) var tools: [MCPTool] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var brandReport: BrandReport?
    @Published private(set) var actions: [Action] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingMetrics: Bool = false
    @Published private(set) var isLoadingActions: Bool = false
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

    struct BrandMetrics: Hashable, Identifiable {
        let brandID: String
        let brandName: String
        /// Visibility as a fraction 0…1 (nil if Peec hasn't scored it yet).
        let visibility: Double?
        /// Share of voice as a fraction 0…1.
        let shareOfVoice: Double?
        /// Sentiment on a 0…100 scale.
        let sentiment: Double?
        let mentionCount: Int

        /// Raw-unit deltas vs the prior window (same scale as the value).
        /// Nil when prior data is unavailable or missing.
        let visibilityDelta: Double?
        let shareOfVoiceDelta: Double?
        let sentimentDelta: Double?

        var id: String { brandID }
    }

    struct Action: Identifiable, Hashable {
        let id: String
        let title: String
        let summary: String?
        let category: String?
        /// 0…1 if Peec returns a normalized score, otherwise the raw value (often 0…100).
        let score: Double?
    }

    struct BrandReport: Hashable {
        let projectID: String
        let startDate: String
        let endDate: String
        let brands: [BrandMetrics]

        var primary: BrandMetrics? { brands.first }
    }

    func clear() {
        tools = []
        projects = []
        brandReport = nil
        actions = []
        lastError = nil
        initialized = false
    }

    /// Fetches the last-7-days opportunity-scored recommendations and parses them into typed
    /// `Action` rows. Column names are looked up defensively because the Peec MCP schema
    /// hasn't been pinned in code yet.
    func refreshActions(projectID: String) async {
        guard !projectID.isEmpty else { return }
        isLoadingActions = true
        defer { isLoadingActions = false }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let start = fmt.string(from: weekAgo)
        let end = fmt.string(from: now)

        do {
            let token = try await PeecOAuth.shared.validAccessToken()
            try await ensureInitialized(token: token)

            let result = try await call(
                method: "tools/call",
                params: [
                    "name": "get_actions",
                    "arguments": [
                        "project_id": projectID,
                        "start_date": start,
                        "end_date": end,
                    ],
                ],
                token: token
            )
            if let content = result["content"] as? [[String: Any]],
               let firstText = content.first?["text"] as? String {
                log.debug("get_actions payload — \(firstText.prefix(800), privacy: .private)")
            }
            do {
                actions = try Self.parseActions(from: result)
                log.info("fetched \(self.actions.count, privacy: .public) actions")
            } catch {
                actions = []
                log.error("parseActions failed — \(error.localizedDescription, privacy: .private)")
            }
        } catch {
            lastError = error.localizedDescription
            log.error("refreshActions failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func parseActions(from result: [String: Any]) throws -> [Action] {
        guard let content = result["content"] as? [[String: Any]],
              let firstText = content.first?["text"] as? String,
              let data = firstText.data(using: .utf8),
              let table = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = table["columns"] as? [String],
              let rows = table["rows"] as? [[Any]] else {
            throw MCPError.malformed("unexpected get_actions payload")
        }
        // Tolerate column-name drift across Peec versions.
        let firstIdx: ([String]) -> Int? = { candidates in
            for c in candidates {
                if let i = columns.firstIndex(of: c) { return i }
            }
            return nil
        }
        let idIdx     = firstIdx(["id", "action_id", "recommendation_id"])
        let titleIdx  = firstIdx(["title", "name", "recommendation", "headline"])
        let summaryIdx = firstIdx(["summary", "description", "details", "rationale"])
        let categoryIdx = firstIdx(["category", "type", "topic"])
        let scoreIdx   = firstIdx(["opportunity_score", "score", "priority", "impact"])

        return rows.enumerated().compactMap { (offset, row) -> Action? in
            func string(at i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                if let s = row[i] as? String, !s.isEmpty { return s }
                return nil
            }
            func double(at i: Int?) -> Double? {
                guard let i, i < row.count else { return nil }
                if let d = row[i] as? Double { return d }
                if let n = row[i] as? NSNumber { return n.doubleValue }
                return nil
            }
            guard let title = string(at: titleIdx) else { return nil }
            return Action(
                id: string(at: idIdx) ?? "row-\(offset)",
                title: title,
                summary: string(at: summaryIdx),
                category: string(at: categoryIdx),
                score: double(at: scoreIdx)
            )
        }
    }

    /// Fetches the last-7-days brand report *and* the prior 7 days in parallel, then merges
    /// them into `BrandMetrics` objects carrying absolute deltas for the tiles in the popover.
    func refreshBrandReport(projectID: String) async {
        guard !projectID.isEmpty else { return }
        isLoadingMetrics = true
        defer { isLoadingMetrics = false }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let currentStart = fmt.string(from: weekAgo)
        let currentEnd = fmt.string(from: now)
        let priorStart = fmt.string(from: twoWeeksAgo)
        let priorEnd = fmt.string(from: weekAgo)

        do {
            let token = try await PeecOAuth.shared.validAccessToken()
            try await ensureInitialized(token: token)

            async let currentRaw = call(
                method: "tools/call",
                params: [
                    "name": "get_brand_report",
                    "arguments": [
                        "project_id": projectID,
                        "start_date": currentStart,
                        "end_date": currentEnd,
                    ],
                ],
                token: token
            )
            async let priorRaw = call(
                method: "tools/call",
                params: [
                    "name": "get_brand_report",
                    "arguments": [
                        "project_id": projectID,
                        "start_date": priorStart,
                        "end_date": priorEnd,
                    ],
                ],
                token: token
            )

            let (currentResult, priorResult) = try await (currentRaw, priorRaw)
            let currentBrands = try Self.parseBrandMetrics(from: currentResult)
            let priorBrands = try Self.parseBrandMetrics(from: priorResult)
            let merged = Self.mergeDeltas(current: currentBrands, prior: priorBrands)

            brandReport = BrandReport(
                projectID: projectID,
                startDate: currentStart,
                endDate: currentEnd,
                brands: merged
            )
            lastError = nil
            log.info("fetched brand report — \(merged.count, privacy: .public) brands with deltas")
        } catch {
            lastError = error.localizedDescription
            log.error("refreshBrandReport failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Combines current + prior brand metrics into a single list with delta fields populated.
    private static func mergeDeltas(current: [BrandMetrics], prior: [BrandMetrics]) -> [BrandMetrics] {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.brandID, $0) })
        return current.map { cur -> BrandMetrics in
            let p = priorByID[cur.brandID]
            func diff(_ a: Double?, _ b: Double?) -> Double? {
                guard let a, let b else { return nil }
                return a - b
            }
            return BrandMetrics(
                brandID: cur.brandID,
                brandName: cur.brandName,
                visibility: cur.visibility,
                shareOfVoice: cur.shareOfVoice,
                sentiment: cur.sentiment,
                mentionCount: cur.mentionCount,
                visibilityDelta: diff(cur.visibility, p?.visibility),
                shareOfVoiceDelta: diff(cur.shareOfVoice, p?.shareOfVoice),
                sentimentDelta: diff(cur.sentiment, p?.sentiment)
            )
        }
    }

    private static func parseBrandMetrics(from result: [String: Any]) throws -> [BrandMetrics] {
        guard let content = result["content"] as? [[String: Any]],
              let firstText = content.first?["text"] as? String,
              let data = firstText.data(using: .utf8),
              let table = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = table["columns"] as? [String],
              let rows = table["rows"] as? [[Any]] else {
            throw MCPError.malformed("unexpected brand_report payload")
        }
        let idx = { (name: String) -> Int? in columns.firstIndex(of: name) }
        guard let brandIDIdx = idx("brand_id"),
              let brandNameIdx = idx("brand_name") else {
            throw MCPError.malformed("missing brand columns")
        }
        let visIdx = idx("visibility")
        let sovIdx = idx("share_of_voice")
        let sentIdx = idx("sentiment")
        let mentIdx = idx("mention_count")

        return rows.compactMap { row -> BrandMetrics? in
            guard row.count > brandIDIdx,
                  let bid = row[brandIDIdx] as? String,
                  row.count > brandNameIdx,
                  let name = row[brandNameIdx] as? String
            else { return nil }
            func double(at i: Int?) -> Double? {
                guard let i, i < row.count else { return nil }
                if let d = row[i] as? Double { return d }
                if let n = row[i] as? NSNumber { return n.doubleValue }
                return nil
            }
            func int(at i: Int?) -> Int {
                guard let i, i < row.count else { return 0 }
                if let n = row[i] as? Int { return n }
                if let n = row[i] as? NSNumber { return n.intValue }
                return 0
            }
            return BrandMetrics(
                brandID: bid,
                brandName: name,
                visibility: double(at: visIdx),
                shareOfVoice: double(at: sovIdx),
                sentiment: double(at: sentIdx),
                mentionCount: int(at: mentIdx),
                visibilityDelta: nil,
                shareOfVoiceDelta: nil,
                sentimentDelta: nil
            )
        }
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

    /// Invoke an MCP tool by name and return the text payload from the first content block.
    /// Used by the Foundation Models tool wrappers in `PeecTools.swift`.
    func callTool(name: String, arguments: [String: Any] = [:]) async throws -> String {
        let token = try await PeecOAuth.shared.validAccessToken()
        try await ensureInitialized(token: token)

        let result = try await call(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            token: token
        )
        guard let content = result["content"] as? [[String: Any]],
              let firstText = content.first?["text"] as? String else {
            throw MCPError.malformed("tool call returned no text content")
        }
        log.info("called tool \(name, privacy: .public) — \(firstText.count, privacy: .public) chars")
        return firstText
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
            log.error("refreshTools failed — \(error.localizedDescription, privacy: .private)")
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
            log.error("refreshProjects failed — \(error.localizedDescription, privacy: .private)")
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
