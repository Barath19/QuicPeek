import Foundation
import SwiftData
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Chat")

/// Manages the chat thread for the currently-selected Peec AI project. Creates threads
/// lazily, appends user/assistant messages, and streams partial content into the last
/// assistant message as tokens arrive.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var activeProjectID: String?

    private var context: ModelContext?
    private var thread: ChatThread?

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
    }

    /// Loads (or creates) the thread for the given project and refreshes the published
    /// `messages` list. Call whenever the selected project changes.
    func loadThread(projectID: String) {
        guard let context, !projectID.isEmpty else { return }
        activeProjectID = projectID

        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.projectID == projectID }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            thread = existing
        } else {
            let new = ChatThread(projectID: projectID)
            context.insert(new)
            try? context.save()
            thread = new
        }
        refresh()
    }

    /// Inserts a user message and an empty assistant message, returns the assistant
    /// message so the caller can stream tokens into its `content`.
    @discardableResult
    func startTurn(userPrompt: String) -> ChatMessage? {
        guard let context, let thread else { return nil }
        let userMsg = ChatMessage(role: .user, content: userPrompt, thread: thread)
        let assistantMsg = ChatMessage(role: .assistant, content: "", thread: thread)
        context.insert(userMsg)
        context.insert(assistantMsg)
        thread.updatedAt = .now
        try? context.save()
        refresh()
        return assistantMsg
    }

    func updateAssistant(_ message: ChatMessage, content: String) {
        message.content = content
        try? context?.save()
        refresh()
    }

    /// Deletes all messages in the active thread. Keeps the thread row itself.
    func clearActiveThread() {
        guard let context, let thread else { return }
        for msg in thread.messages { context.delete(msg) }
        try? context.save()
        refresh()
        log.info("cleared thread for project \(thread.projectID, privacy: .public)")
    }

    private func refresh() {
        messages = (thread?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }
}
