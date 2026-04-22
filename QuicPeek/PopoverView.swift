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
        instructions: Self.makeInstructions()
    )

    private static func makeInstructions() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return """
        You are an assistant inside the QuicPeek macOS menubar app. The user is a marketer
        monitoring their brand's visibility on AI search engines via Peec AI.

        Today is \(today). Default date window is the last 7 days unless the user specifies otherwise.

        You have three read-only Peec AI tools:
        • list_peec_projects — discover available projects
        • get_peec_brand_report — visibility / sentiment / share-of-voice per brand for a date range
        • get_peec_actions — opportunity-scored recommendations for a date range

        When a question needs live data, call a tool rather than guessing. If you don't
        know the project_id yet, call list_peec_projects first and pick the first active one.

        IMPORTANT: zero is a valid answer. When a tool returns visibility 0, mention_count 0,
        or null sentiment, that means "no mentions recorded in this window" — NOT "data
        missing" or "project not found." Report zero honestly ("no mentions this week
        across X tracked brands"). Never claim you couldn't find data if the tool
        returned rows.

        If the user asks what tools or capabilities you have, just list them in plain
        text — do NOT call a tool to answer that.

        Keep answers concise and specific; marketers want the headline, not the raw table.
        """
    }
    @StateObject private var auth = PeecOAuth.shared
    @StateObject private var mcp = PeecMCP.shared
    @StateObject private var approval = ToolApprovalCoordinator.shared
    @AppStorage("app.theme") private var theme: AppTheme = .system
    @AppStorage("peec.selected_project_id") private var selectedProjectID: String = ""
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool

    private var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            metricsBar

            responseArea

            if let pending = approval.pending {
                ApprovalBanner(pending: pending)
            }

            quickActions

            inputBar
        }
        .padding(12)
        .frame(width: 360, height: 320)
        .containerBackground(.ultraThinMaterial, for: .window)
        .preferredColorScheme(theme.resolve())
        .background(WindowAppearance(appearance: theme.nsAppearance))
        .id(theme)
        .onAppear {
            status = availabilityMessage()
            if auth.isConnected {
                Task {
                    await mcp.refreshProjects()
                    if !selectedProjectID.isEmpty {
                        await mcp.refreshBrandReport(projectID: selectedProjectID)
                    }
                }
            }
        }
        .onChange(of: mcp.projects) { _, newProjects in
            if selectedProjectID.isEmpty, let first = newProjects.first {
                selectedProjectID = first.id
            }
        }
        .onChange(of: selectedProjectID) { _, newID in
            guard !newID.isEmpty else { return }
            Task { await mcp.refreshBrandReport(projectID: newID) }
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
    private var metricsBar: some View {
        if let brand = mcp.brandReport?.primary {
            HStack(spacing: 10) {
                MetricTile(
                    label: "Visibility",
                    value: Self.formatPercent(brand.visibility),
                    deltaText: Self.deltaPPString(brand.visibilityDelta),
                    deltaSign: Self.sign(brand.visibilityDelta)
                )
                MetricTile(
                    label: "Share of Voice",
                    value: Self.formatPercent(brand.shareOfVoice),
                    deltaText: Self.deltaPPString(brand.shareOfVoiceDelta),
                    deltaSign: Self.sign(brand.shareOfVoiceDelta)
                )
                MetricTile(
                    label: "Sentiment",
                    value: Self.formatSentiment(brand.sentiment),
                    deltaText: Self.deltaRawString(brand.sentimentDelta),
                    deltaSign: Self.sign(brand.sentimentDelta)
                )
            }
        } else if auth.isConnected && mcp.isLoadingMetrics {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    MetricTile(label: "—", value: "…", deltaText: nil, deltaSign: .zero)
                }
            }
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        HStack(spacing: 6) {
            QuickActionChip(
                icon: "sun.max",
                title: "Morning Brief",
                action: { runPresetPrompt(.morningBrief) }
            )
            QuickActionChip(
                icon: "doc.text.magnifyingglass",
                title: "Postmortem",
                action: { runPresetPrompt(.postmortem) }
            )
            QuickActionChip(
                icon: "chart.line.uptrend.xyaxis",
                title: "Top Movers",
                action: { runPresetPrompt(.topMovers) }
            )
        }
        .disabled(isGenerating || !auth.isConnected)
    }

    private enum PresetPrompt {
        case morningBrief, postmortem, topMovers

        var text: String {
            switch self {
            case .morningBrief:
                return "Give me a morning brief for my brand: visibility, share of voice, and sentiment for this week vs last week. 3–5 bullets max."
            case .postmortem:
                return "Write a short postmortem of the last 7 days — what moved, what didn't, and the single most actionable next step."
            case .topMovers:
                return "What are the biggest changes this week? Top 3 movers across brands or topics, with the direction and magnitude."
            }
        }
    }

    private func runPresetPrompt(_ preset: PresetPrompt) {
        prompt = preset.text
        Task { await send() }
    }

    private static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func formatSentiment(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f/100", value)
    }

    /// Formats a 0–1 fraction delta as percentage points, e.g. 0.021 → "+2.1pp".
    private static func deltaPPString(_ value: Double?) -> String? {
        guard let value else { return nil }
        let pp = value * 100
        let sign = pp > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", pp))pp"
    }

    /// Formats a raw delta (e.g. sentiment), 5.0 → "+5".
    private static func deltaRawString(_ value: Double?) -> String? {
        guard let value else { return nil }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", value))"
    }

    private static func sign(_ value: Double?) -> DeltaSign {
        guard let value else { return .zero }
        if value > 0.0001 { return .up }
        if value < -0.0001 { return .down }
        return .zero
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
                .tint(Color.primary)
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

private struct QuickActionChip: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

enum DeltaSign { case up, down, zero }

private struct MetricTile: View {
    let label: String
    let value: String
    let deltaText: String?
    let deltaSign: DeltaSign

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.callout, design: .rounded))
                .fontWeight(.semibold)
                .lineLimit(1)
            if let deltaText {
                HStack(spacing: 2) {
                    Image(systemName: symbolName)
                        .font(.system(size: 8))
                    Text(deltaText)
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(deltaColor)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private var symbolName: String {
        switch deltaSign {
        case .up:   return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case .zero: return "minus"
        }
    }

    private var deltaColor: Color {
        switch deltaSign {
        case .up:   return .green
        case .down: return .red
        case .zero: return .secondary
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
                .tint(Color.primary)
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

#Preview("Popover — Light") {
    PopoverView()
        .preferredColorScheme(.light)
}

#Preview("Popover — Dark") {
    PopoverView()
        .preferredColorScheme(.dark)
}
