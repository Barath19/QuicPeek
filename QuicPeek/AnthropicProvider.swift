import Foundation
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Anthropic")

/// Streams a response from Anthropic's Messages API with Peec MCP passed through natively
/// (no hand-wired tool definitions — Claude discovers tools from Peec itself and calls them
/// via the beta `mcp_servers` parameter).
struct AnthropicProvider: LLMProvider {
    let displayName: String
    let apiKey: String
    let model: String
    let instructions: String
    let peecAccessToken: String?

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: AnthropicModel, instructions: String, peecAccessToken: String?) {
        self.apiKey = apiKey
        self.model = model.rawValue
        self.displayName = "Anthropic · \(model.displayName)"
        self.instructions = instructions
        self.peecAccessToken = peecAccessToken
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamInternal(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamInternal(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // MCP connector is in beta — opt in via this header.
        req.setValue("mcp-client-2025-04-04", forHTTPHeaderField: "anthropic-beta")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "system": instructions,
            "messages": [
                ["role": "user", "content": prompt]
            ],
        ]
        if let peecAccessToken, !peecAccessToken.isEmpty {
            body["mcp_servers"] = [[
                "type": "url",
                "url": "https://api.peec.ai/mcp",
                "name": "peec",
                "authorization_token": peecAccessToken,
            ]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody.append(line + "\n")
                if errorBody.count > 2000 { break }
            }
            throw AnthropicError.http(code: http.statusCode, body: errorBody)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String,
                   deltaType == "text_delta",
                   let text = delta["text"] as? String {
                    accumulated += text
                    continuation.yield(accumulated)
                }
            case "message_stop":
                break
            case "error":
                if let err = json["error"] as? [String: Any],
                   let message = err["message"] as? String {
                    throw AnthropicError.api(message: message)
                }
            default:
                continue
            }
        }
        log.info("anthropic stream complete — \(accumulated.count, privacy: .public) chars")
    }

    enum AnthropicError: LocalizedError {
        case http(code: Int, body: String)
        case api(message: String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Anthropic HTTP \(code): \(body.prefix(200))"
            case .api(let message):
                return "Anthropic API error: \(message)"
            }
        }
    }
}
