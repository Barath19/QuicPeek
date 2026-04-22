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
}
