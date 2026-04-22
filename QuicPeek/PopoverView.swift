import SwiftUI
import FoundationModels
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Popover")

struct PopoverView: View {
    @State private var prompt: String = ""
    @State private var response: String = ""
    @State private var status: String = ""
    @State private var isGenerating: Bool = false
    @State private var placeholderText: String = ""
    @State private var typewriterStopped: Bool = false

    private let suggestions = [
        "How's my brand doing this week?",
        "What should we do to improve visibility?",
        "Show me top movers",
        "Summarize my visibility trend",
    ]
    @State private var session = LanguageModelSession(
        tools: [
            ListProjectsTool(),
            GetBrandReportTool(),
            GetActionsTool(),
        ],
        instructions: """
        You are an assistant inside the QuicPeek macOS menubar app. The user is a marketer
        monitoring their brand's visibility on AI search engines via Peec AI. You have
        read-only tools that query Peec AI over MCP. When the user's question needs data,
        call tools rather than guessing. If you don't know the project_id, call
        list_peec_projects first. Dates should be recent unless the user specifies otherwise.
        Keep answers concise; marketers want the headline, not the raw table.
        """
    )
    @StateObject private var auth = PeecOAuth.shared
    @StateObject private var mcp = PeecMCP.shared
    @StateObject private var approval = ToolApprovalCoordinator.shared
    @AppStorage("peec.selected_project_id") private var selectedProjectID: String = ""
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool

    private var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            responseArea

            if let pending = approval.pending {
                ApprovalBanner(pending: pending)
            }

            inputBar
        }
        .padding(12)
        .frame(width: 360, height: 320)
        .onAppear {
            status = availabilityMessage()
            if auth.isConnected {
                Task { await mcp.refreshProjects() }
            }
        }
        .onChange(of: mcp.projects) { _, newProjects in
            if selectedProjectID.isEmpty, let first = newProjects.first {
                selectedProjectID = first.id
            }
        }
    }

    @ViewBuilder
    private var projectSwitcher: some View {
        if !mcp.projects.isEmpty {
            Menu {
                ForEach(mcp.projects) { project in
                    Button {
                        selectedProjectID = project.id
                    } label: {
                        if project.id == selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder").font(.caption2)
                    Text(currentProjectName)
                        .font(.caption).fontWeight(.medium)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var currentProjectName: String {
        mcp.projects.first(where: { $0.id == selectedProjectID })?.name
            ?? mcp.projects.first?.name
            ?? "No project"
    }

    private var header: some View {
        HStack(spacing: 8) {
            projectSwitcher
            Spacer()
            peecStatus
            settingsMenu
        }
    }

    @ViewBuilder
    private var peecStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(peecStatusColor)
                .frame(width: 7, height: 7)
            if auth.isConnecting {
                Text("Connecting…")
            } else if auth.isConnected {
                Text("Peec AI")
            } else {
                Button("Click to connect") {
                    Task { await auth.connect() }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var peecStatusColor: Color {
        if auth.isConnected { return .green }
        if auth.isConnecting { return .yellow }
        return .red
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit QuicPeek") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var responseArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !response.isEmpty {
                    Text(formattedResponse)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Render the model's markdown as styled text (bold, italics, inline code, links),
    /// preserving newlines so bullet/numbered lists still break cleanly.
    private var formattedResponse: AttributedString {
        (try? AttributedString(
            markdown: response,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(response)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(placeholderText, text: $prompt)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { Task { await send() } }
                .onChange(of: inputFocused) { _, focused in
                    if focused {
                        placeholderText = ""
                        typewriterStopped = true
                    }
                }
                .disabled(isGenerating)
                .task { await runTypewriter() }

            if isGenerating {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func availabilityMessage() -> String {
        switch availability {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "This Mac isn't eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is still downloading. Try again in a few minutes."
        case .unavailable(let other):
            return "Model unavailable: \(String(describing: other))"
        @unknown default:
            return "Model unavailable (unknown reason)."
        }
    }

    @MainActor
    private func runTypewriter() async {
        var idx = 0
        while !Task.isCancelled && !typewriterStopped {
            let target = suggestions[idx % suggestions.count]
            var chars: [Character] = []

            for ch in target {
                if typewriterStopped || Task.isCancelled { return }
                chars.append(ch)
                placeholderText = String(chars)
                try? await Task.sleep(for: .milliseconds(55))
            }
            try? await Task.sleep(for: .seconds(1.6))
            if typewriterStopped || Task.isCancelled { return }
            while !chars.isEmpty {
                if typewriterStopped || Task.isCancelled { return }
                chars.removeLast()
                placeholderText = String(chars)
                try? await Task.sleep(for: .milliseconds(25))
            }
            idx += 1
        }
    }

    @MainActor
    private func send() async {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isGenerating else { return }

        if case .unavailable = availability {
            status = availabilityMessage()
            return
        }

        prompt = ""
        response = ""
        status = "Thinking…"
        isGenerating = true
        defer { isGenerating = false }

        do {
            let stream = session.streamResponse(to: input)
            for try await partial in stream {
                response = partial.content
                status = ""
            }
            if response.isEmpty {
                status = "Model returned an empty response."
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

private struct ApprovalBanner: View {
    let pending: ToolApprovalCoordinator.PendingApproval

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.message)
                    .font(.caption)
                    .lineLimit(2)
                Text(pending.toolName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny") { ToolApprovalCoordinator.shared.resolve(false) }
                .controlSize(.small)
            Button("Allow") { ToolApprovalCoordinator.shared.resolve(true) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.black)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview("Popover") {
    PopoverView()
}
