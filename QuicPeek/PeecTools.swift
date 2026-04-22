import Foundation
import FoundationModels

/// Hand-wired `Tool` wrappers around a small subset of Peec AI's MCP tools. Each one forwards
/// the call to `PeecMCP.callTool()` and returns the raw text response — the on-device model
/// interprets the columnar JSON directly and can summarise it for the user.
///
/// Every wrapper checks the user's per-tool policy first and throws if the tool is blocked.
/// `.ask` is currently treated as `.allow`; wiring a confirm dialog is a future enhancement.

@MainActor
private func checkPolicy(_ mcpName: String, message: String) async throws {
    switch ToolPolicyStore.shared.policy(forName: mcpName) {
    case .allow:
        return
    case .block:
        throw ToolPolicyError.blocked(name: mcpName)
    case .ask:
        let approved = await ToolApprovalCoordinator.shared.requestApproval(
            toolName: mcpName,
            message: message
        )
        if !approved {
            throw ToolPolicyError.denied(name: mcpName)
        }
    }
}

struct ListProjectsTool: Tool {
    let name = "list_peec_projects"
    let description = """
    List active Peec AI projects. Call this first if the user's question mentions a project
    whose ID you don't know yet. Returns a small table with id, name, status.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Set true to include ended or paused projects. Defaults to false.")
        let includeInactive: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        try await checkPolicy("list_projects", message: "List your Peec AI projects?")
        return try await PeecMCP.shared.callTool(
            name: "list_projects",
            arguments: ["include_inactive": arguments.includeInactive]
        )
    }
}

struct GetBrandReportTool: Tool {
    let name = "get_peec_brand_report"
    let description = """
    Fetch brand visibility, sentiment, position, and share-of-voice from Peec AI for a
    project over a date range. Useful for questions like "how is our brand doing" or
    "what's our share of voice vs competitors".
    """

    @Generable
    struct Arguments {
        @Guide(description: "Peec project ID (starts with 'or_'). Use list_peec_projects to find it.")
        let projectID: String
        @Guide(description: "Start date in YYYY-MM-DD format.")
        let startDate: String
        @Guide(description: "End date in YYYY-MM-DD format.")
        let endDate: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await checkPolicy("get_brand_report", message: "Fetch brand report \(arguments.startDate) → \(arguments.endDate)?")
        return try await PeecMCP.shared.callTool(
            name: "get_brand_report",
            arguments: [
                "project_id": arguments.projectID,
                "start_date": arguments.startDate,
                "end_date": arguments.endDate,
            ]
        )
    }
}

struct GetActionsTool: Tool {
    let name = "get_peec_actions"
    let description = """
    Get opportunity-scored recommendations for improving brand visibility on AI search engines.
    Use when the user asks "what should we do" or "how can we improve our visibility".
    """

    @Generable
    struct Arguments {
        @Guide(description: "Peec project ID (starts with 'or_').")
        let projectID: String
        @Guide(description: "Start date in YYYY-MM-DD format.")
        let startDate: String
        @Guide(description: "End date in YYYY-MM-DD format.")
        let endDate: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await checkPolicy("get_actions", message: "Fetch recommendations \(arguments.startDate) → \(arguments.endDate)?")
        return try await PeecMCP.shared.callTool(
            name: "get_actions",
            arguments: [
                "project_id": arguments.projectID,
                "start_date": arguments.startDate,
                "end_date": arguments.endDate,
            ]
        )
    }
}
