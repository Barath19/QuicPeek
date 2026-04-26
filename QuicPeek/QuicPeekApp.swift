import SwiftUI
import SwiftData

@main
struct QuicPeekApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: ChatThread.self, ChatMessage.self,
                Routine.self, RoutineRun.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        RoutineScheduler.shared.configure(container: container)
        RoutineScheduler.shared.providerFactory = { routine in
            Self.makeProvider(for: routine)
        }
        RoutineScheduler.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .modelContainer(container)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }

    /// Builds the LLM provider used to run a routine headlessly. Mirrors the provider
    /// selection logic in `PopoverView.makeProvider()` but reads `@AppStorage` values
    /// directly off `UserDefaults` so it can run outside any view.
    @MainActor
    private static func makeProvider(for routine: Routine) -> LLMProvider {
        let defaults = UserDefaults.standard
        let providerKindRaw = defaults.string(forKey: "llm.provider") ?? LLMProviderKind.apple.rawValue
        let providerKind = LLMProviderKind(rawValue: providerKindRaw) ?? .apple
        let modelRaw = defaults.string(forKey: "anthropic.model") ?? AnthropicModel.sonnet46.rawValue
        let anthropicModel = AnthropicModel(rawValue: modelRaw) ?? .sonnet46

        let instructions = makeInstructions()

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
}
