import SwiftUI
import SwiftData

@main
struct QuicPeekApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: ChatThread.self, ChatMessage.self)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

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
}
