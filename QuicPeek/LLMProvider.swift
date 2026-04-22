import Foundation

/// Abstraction over the language-model backend. Each provider yields cumulative content
/// strings (each element in the stream is the full content so far), matching how we
/// already render token streams in the popover.
protocol LLMProvider {
    var displayName: String { get }
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
}

/// Which provider is currently active. Stored in `@AppStorage("llm.provider")`.
enum LLMProviderKind: String, CaseIterable, Identifiable {
    case apple
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:     return "Apple (on-device)"
        case .anthropic: return "Anthropic (cloud)"
        }
    }
}

/// Claude models the user can pick from when Anthropic is selected.
enum AnthropicModel: String, CaseIterable, Identifiable {
    case opus47   = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45  = "claude-haiku-4-5-20251001"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus47:   return "Claude Opus 4.7"
        case .sonnet46: return "Claude Sonnet 4.6"
        case .haiku45:  return "Claude Haiku 4.5"
        }
    }
}
