import SwiftUI
import SwiftData
import FoundationModels
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Popover")

struct PopoverView: View {
    @State private var prompt: String = ""
    @State private var status: String = ""
    @State private var isGenerating: Bool = false
    @Environment(\.modelContext) private var modelContext
    @StateObject private var chat = ChatStore()
    @State private var placeholderText: String = ""
    @State private var typewriterStopped: Bool = false
    @State private var gradientAngle: Double = 0

    private let suggestions = [
        "How's my brand doing this week?",
        "What should we do to improve visibility?",
        "Show me top movers",
        "Summarize my visibility trend",
    ]
    @AppStorage("llm.provider") private var providerKind: LLMProviderKind = .apple
    @AppStorage("anthropic.model") private var anthropicModel: AnthropicModel = .sonnet46

    /// Builds the provider the user currently has selected. Apple uses a fresh on-device
    /// session per turn (4096-token context); Anthropic streams from the cloud with Peec
    /// MCP passed through natively.
    private func makeProvider() -> LLMProvider {
        let instructions = Self.makeInstructions()
        switch providerKind {
        case .apple:
            return AppleProvider(
                instructions: instructions,
                tools: [ListProjectsTool(), GetBrandReportTool(), GetActionsTool()]
            )
        case .anthropic:
            let key = Keychain.get(forKey: "anthropic.api_key") ?? ""
            return AnthropicProvider(
                apiKey: key,
                model: anthropicModel,
                instructions: instructions,
                peecAccessToken: PeecOAuth.shared.accessToken
            )
        }
    }

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

            if chat.messages.isEmpty { Spacer(minLength: 0) }

            metricsBar

            topActionBanner

            if !chat.messages.isEmpty {
                clearChatBar
                responseArea
            } else {
                Spacer(minLength: 0)
            }

            if let pending = approval.pending {
                ApprovalBanner(pending: pending)
            }

            quickActions

            inputBar
        }
        .animation(.easeInOut(duration: 0.35), value: chat.messages.isEmpty)
        .padding(12)
        .frame(width: 360, height: 320)
        .containerBackground(.ultraThinMaterial, for: .window)
        .preferredColorScheme(theme.resolve())
        .background(WindowAppearance(appearance: theme.nsAppearance))
        .id(theme)
        .onAppear {
            status = availabilityMessage()
            chat.configure(context: modelContext)
            if !selectedProjectID.isEmpty {
                chat.loadThread(projectID: selectedProjectID)
            }
            if auth.isConnected {
                Task {
                    await mcp.refreshProjects()
                    if !selectedProjectID.isEmpty {
                        async let r1: Void = mcp.refreshBrandReport(projectID: selectedProjectID)
                        async let r2: Void = mcp.refreshActions(projectID: selectedProjectID)
                        _ = await (r1, r2)
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
            chat.loadThread(projectID: newID)
            Task {
                async let r1: Void = mcp.refreshBrandReport(projectID: newID)
                async let r2: Void = mcp.refreshActions(projectID: newID)
                _ = await (r1, r2)
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
    private var clearChatBar: some View {
        if !chat.messages.isEmpty {
            HStack {
                Spacer()
                Button {
                    chat.clearActiveThread()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("Clear")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
                .help("Clear chat")
            }
        }
    }

    @ViewBuilder
    private var metricsBar: some View {
        let compact = !chat.messages.isEmpty
        if let brand = mcp.brandReport?.primary {
            HStack(spacing: compact ? 10 : 18) {
                MetricRing(
                    label: "Visibility",
                    progress: brand.visibility ?? 0,
                    centerText: Self.ringPercent(brand.visibility),
                    deltaText: Self.deltaPPString(brand.visibilityDelta),
                    deltaSign: Self.sign(brand.visibilityDelta),
                    tint: .cyan,
                    compact: compact
                )
                MetricRing(
                    label: "Share of Voice",
                    progress: brand.shareOfVoice ?? 0,
                    centerText: Self.ringPercent(brand.shareOfVoice),
                    deltaText: Self.deltaPPString(brand.shareOfVoiceDelta),
                    deltaSign: Self.sign(brand.shareOfVoiceDelta),
                    tint: .pink,
                    compact: compact
                )
                MetricRing(
                    label: "Sentiment",
                    progress: (brand.sentiment ?? 0) / 100,
                    centerText: Self.ringSentiment(brand.sentiment),
                    deltaText: Self.deltaRawString(brand.sentimentDelta),
                    deltaSign: Self.sign(brand.sentimentDelta),
                    tint: .green,
                    compact: compact
                )
            }
            .frame(maxWidth: .infinity)
        } else if auth.isConnected && mcp.isLoadingMetrics {
            HStack(spacing: compact ? 10 : 18) {
                ForEach(0..<3, id: \.self) { _ in
                    MetricRing(label: "—", progress: 0, centerText: "…",
                               deltaText: nil, deltaSign: .zero,
                               tint: .secondary, compact: compact)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var topActionBanner: some View {
        if let action = mcp.actions.first {
            Button {
                prompt = "Tell me more about this action: \(action.title). What's the rationale and how should I act on it?"
                Task { await send() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text(action.title)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let score = action.score {
                        Text(formatActionScore(score))
                            .font(.system(.caption2, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
        }
    }

    /// Peec sometimes returns a 0…1 fraction and sometimes a 0…100 integer for action
    /// scores — display whichever scale fits best.
    private func formatActionScore(_ score: Double) -> String {
        if score <= 1 {
            return "\(Int((score * 100).rounded()))"
        }
        return "\(Int(score.rounded()))"
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
                icon: "chart.line.uptrend.xyaxis",
                title: "Top Movers",
                action: { runPresetPrompt(.topMovers) }
            )
        }
        .disabled(isGenerating || !auth.isConnected)
    }

    private enum PresetPrompt {
        case morningBrief, topMovers

        var text: String {
            switch self {
            case .morningBrief:
                return "Give me a morning brief for my brand: visibility, share of voice, and sentiment for this week vs last week. 3–5 bullets max."
            case .topMovers:
                return "What are the biggest changes this week? Top 3 movers across brands or topics, with the direction and magnitude."
            }
        }
    }

    private func runPresetPrompt(_ preset: PresetPrompt) {
        prompt = preset.text
        Task { await send() }
    }

    /// Prepends the current project context to every user turn so the model never has to
    /// ask the user for a project_id — it already knows which project is active.
    private func augmentedPrompt(for input: String) -> String {
        guard let project = mcp.projects.first(where: { $0.id == selectedProjectID }) else {
            return input
        }
        return """
        [Selected Peec AI project: name="\(project.name)", project_id="\(project.id)". Use this project_id for any tool call unless the user asks for a different project.]

        \(input)
        """
    }

    private static func ringPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private static func ringSentiment(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onChange(of: chat.messages.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 1.00, green: 0.40, blue: 0.45),
                            Color(red: 0.90, green: 0.35, blue: 0.85),
                            Color(red: 0.45, green: 0.45, blue: 1.00),
                            Color(red: 0.30, green: 0.80, blue: 1.00),
                            Color(red: 1.00, green: 0.65, blue: 0.30),
                            Color(red: 1.00, green: 0.40, blue: 0.45),
                        ],
                        center: .center,
                        angle: .degrees(gradientAngle)
                    ),
                    lineWidth: 1.5
                )
                .opacity(gradientOpacity)
                .animation(.easeInOut(duration: 0.45), value: gradientOpacity)
        )
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                gradientAngle = 360
            }
        }
    }

    private var gradientOpacity: Double {
        if isGenerating { return 0.9 }
        if inputFocused { return 0.55 }
        return 0.25
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
        status = "Thinking…"
        isGenerating = true
        defer { isGenerating = false }

        let assistantMessage = chat.startTurn(userPrompt: input)

        do {
            let augmented = augmentedPrompt(for: input)
            let provider = makeProvider()
            var partialContent = ""
            for try await accumulated in provider.stream(prompt: augmented) {
                partialContent = accumulated
                status = ""
                if let assistantMessage {
                    chat.updateAssistant(assistantMessage, content: partialContent)
                }
            }
            if partialContent.isEmpty, let assistantMessage {
                chat.updateAssistant(assistantMessage, content: "_(empty response)_")
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
            if let assistantMessage {
                chat.updateAssistant(assistantMessage, content: "Error: \(error.localizedDescription)")
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedContent)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(message.role == .user
                          ? Color.secondary.opacity(0.18)
                          : Color.secondary.opacity(0.08))
            )
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private var formattedContent: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(message.content)
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

private struct MetricRing: View {
    let label: String
    let progress: Double
    let centerText: String
    let deltaText: String?
    let deltaSign: DeltaSign
    let tint: Color
    var compact: Bool = true

    @State private var displayProgress: Double = 0

    private var clamped: Double { max(0, min(progress, 1)) }
    private var diameter: CGFloat { compact ? 52 : 92 }
    private var stroke: CGFloat { compact ? 5 : 8 }
    private var centerFontSize: CGFloat { compact ? 11 : 20 }
    private var labelFont: Font { compact ? .caption2 : .footnote }

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: max(0.001, displayProgress))
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.9)) {
                            displayProgress = clamped
                        }
                    }
                    .onChange(of: clamped) { _, newValue in
                        withAnimation(.easeOut(duration: 0.4)) {
                            displayProgress = newValue
                        }
                    }
                Text(centerText)
                    .font(.system(size: centerFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            .frame(width: diameter, height: diameter)

            Text(label)
                .font(labelFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, compact ? 5 : 4)

            if let deltaText {
                HStack(spacing: 2) {
                    Image(systemName: symbolName)
                        .font(.system(size: 7))
                    Text(deltaText)
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(deltaColor)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
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
