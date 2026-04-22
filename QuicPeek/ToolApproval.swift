import Foundation
import Combine

/// Bridges the `.ask` tool policy to an inline confirmation in the popover. When a tool with
/// `.ask` policy is about to run, it calls `requestApproval(...)` which suspends until the user
/// taps Allow or Deny in `ApprovalBanner`.
@MainActor
final class ToolApprovalCoordinator: ObservableObject {
    static let shared = ToolApprovalCoordinator()

    struct PendingApproval: Identifiable, Equatable {
        let id = UUID()
        let toolName: String
        let message: String
    }

    @Published private(set) var pending: PendingApproval?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Asks the user to approve a tool invocation. Returns true if allowed, false if denied or
    /// if another approval is already in flight (fails fast rather than deadlocking).
    func requestApproval(toolName: String, message: String) async -> Bool {
        if pending != nil { return false }
        return await withCheckedContinuation { cont in
            continuation = cont
            pending = PendingApproval(toolName: toolName, message: message)
        }
    }

    /// Called by the UI when the user picks Allow or Deny.
    func resolve(_ approved: Bool) {
        let cont = continuation
        continuation = nil
        pending = nil
        cont?.resume(returning: approved)
    }
}
