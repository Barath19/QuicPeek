import Foundation
import SwiftData

/// Per-project conversation thread. One row per Peec AI project the user has chatted with.
@Model
final class ChatThread {
    @Attribute(.unique) var projectID: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage] = []

    init(projectID: String) {
        self.projectID = projectID
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// A single user or assistant turn inside a `ChatThread`.
@Model
final class ChatMessage {
    enum Role: String, Codable { case user, assistant }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var thread: ChatThread?

    init(role: Role, content: String, thread: ChatThread? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = .now
        self.thread = thread
    }
}
