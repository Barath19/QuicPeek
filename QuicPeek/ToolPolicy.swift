import Foundation
import SwiftUI
import Combine

enum ToolPolicy: String, CaseIterable, Identifiable {
    case allow
    case ask
    case block

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allow: return "Always allow"
        case .ask:   return "Needs approval"
        case .block: return "Blocked"
        }
    }

    var symbolName: String {
        switch self {
        case .allow: return "checkmark.circle"
        case .ask:   return "hand.raised"
        case .block: return "nosign"
        }
    }

    /// Picks a sensible starting policy from MCP tool annotations.
    static func defaultPolicy(for tool: PeecMCP.MCPTool) -> ToolPolicy {
        tool.readOnly ? .allow : .ask
    }
}

@MainActor
final class ToolPolicyStore: ObservableObject {
    static let shared = ToolPolicyStore()

    @Published private var overrides: [String: String]

    private let defaults = UserDefaults.standard
    private let key = "peec.tool_policies"

    init() {
        overrides = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func policy(for tool: PeecMCP.MCPTool) -> ToolPolicy {
        if let raw = overrides[tool.name], let p = ToolPolicy(rawValue: raw) {
            return p
        }
        return ToolPolicy.defaultPolicy(for: tool)
    }

    func setPolicy(_ policy: ToolPolicy, for tool: PeecMCP.MCPTool) {
        overrides[tool.name] = policy.rawValue
        defaults.set(overrides, forKey: key)
    }

    func binding(for tool: PeecMCP.MCPTool) -> Binding<ToolPolicy> {
        Binding(
            get: { self.policy(for: tool) },
            set: { self.setPolicy($0, for: tool) }
        )
    }

    /// Policy lookup by MCP tool name, for enforcement in code paths that don't hold an MCPTool.
    /// Falls back to the default policy derived from annotations if the tool is loaded, else `.allow`.
    func policy(forName name: String) -> ToolPolicy {
        if let raw = overrides[name], let p = ToolPolicy(rawValue: raw) { return p }
        if let tool = PeecMCP.shared.tools.first(where: { $0.name == name }) {
            return ToolPolicy.defaultPolicy(for: tool)
        }
        return .allow
    }
}

enum ToolPolicyError: LocalizedError {
    case blocked(name: String)
    case denied(name: String)
    var errorDescription: String? {
        switch self {
        case .blocked(let name):
            return "The user has blocked the '\(name)' tool in QuicPeek settings. Tell them this directly — do not try again."
        case .denied(let name):
            return "The user denied the request to use the '\(name)' tool. Acknowledge it and offer a path that doesn't need this tool."
        }
    }
}
