import Foundation
import FoundationModels

struct AppleProvider: LLMProvider {
    let displayName = "Apple on-device"
    let instructions: String
    let tools: [any Tool]

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        let instructions = self.instructions
        let tools = self.tools
        return AsyncThrowingStream { continuation in
            Task {
                // Fresh session per turn — the 4096-token context window fills fast when
                // tool responses (columnar JSON) pile up across turns.
                let session = LanguageModelSession(tools: tools, instructions: instructions)
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
