import AppIntents
import WidgetKit

/// `AppEntity` representing one Peec project as offered by the widget configuration UI.
/// The widget reads available projects from the App Group container — the main app keeps
/// the list fresh whenever it fetches `list_projects`.
struct ProjectAppEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Peec Project"
    static var defaultQuery = ProjectQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProjectQuery: EntityQuery {
    func entities(for identifiers: [ProjectAppEntity.ID]) async throws -> [ProjectAppEntity] {
        let known = Dictionary(
            uniqueKeysWithValues: SharedStore.readProjects().map { ($0.id, $0) }
        )
        return identifiers.compactMap { id in
            known[id].map { ProjectAppEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [ProjectAppEntity] {
        SharedStore.readProjects().map { ProjectAppEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> ProjectAppEntity? {
        SharedStore.readProjects().first.map { ProjectAppEntity(id: $0.id, name: $0.name) }
    }
}

/// Configuration intent for the Brand Rings widget. Lets the user pin the widget to a
/// specific Peec project; if no project is selected we fall back to the first available
/// snapshot in the shared store.
struct SelectProjectIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Project"
    static var description = IntentDescription("Choose which Peec project the widget displays.")

    @Parameter(title: "Project")
    var project: ProjectAppEntity?

    init() {}

    init(project: ProjectAppEntity?) {
        self.project = project
    }
}
