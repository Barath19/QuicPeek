import Foundation
import OSLog

#if canImport(WidgetKit)
import WidgetKit
#endif

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "SharedStore")

/// Codable snapshot of a brand's metrics, persisted to the shared App Group container so
/// the desktop widget can render rings without making any network call itself.
public struct BrandSnapshot: Codable, Equatable, Hashable {
    public let projectID: String
    public let projectName: String
    public let visibility: Double?
    public let visibilityDelta: Double?
    public let shareOfVoice: Double?
    public let shareOfVoiceDelta: Double?
    public let sentiment: Double?
    public let sentimentDelta: Double?
    public let fetchedAt: Date
}

public struct TopActionSnapshot: Codable, Equatable, Hashable {
    public let projectID: String
    public let title: String
    public let score: Double?
    public let fetchedAt: Date
}

public struct ProjectListEntry: Codable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
}

/// Read/write surface for the App Group container shared between the main app and the
/// widget extension. The app writes after each fetch; the widget reads from its timeline
/// provider and never touches the network.
public enum SharedStore {
    public static let appGroup = "group.com.bharath.QuicPeek"

    private enum Keys {
        static let brands = "shared.brand_snapshots.v1"
        static let actions = "shared.top_actions.v1"
        static let projects = "shared.projects.v1"
        static let lastUpdated = "shared.last_updated.v1"
    }

    private static var defaults: UserDefaults? {
        guard let d = UserDefaults(suiteName: appGroup) else {
            log.error("App Group \(appGroup, privacy: .public) is not configured — shared store unavailable")
            return nil
        }
        return d
    }

    // MARK: Brand snapshots

    public static func writeBrands(_ snapshots: [BrandSnapshot]) {
        write(snapshots, key: Keys.brands)
        touchUpdatedAt()
        reloadWidgets()
    }

    public static func readBrands() -> [BrandSnapshot] {
        read([BrandSnapshot].self, key: Keys.brands) ?? []
    }

    public static func brand(forProjectID id: String) -> BrandSnapshot? {
        readBrands().first { $0.projectID == id }
    }

    // MARK: Top actions

    public static func writeTopActions(_ snapshots: [TopActionSnapshot]) {
        write(snapshots, key: Keys.actions)
        touchUpdatedAt()
        reloadWidgets()
    }

    public static func readTopActions() -> [TopActionSnapshot] {
        read([TopActionSnapshot].self, key: Keys.actions) ?? []
    }

    public static func topAction(forProjectID id: String) -> TopActionSnapshot? {
        readTopActions().first { $0.projectID == id }
    }

    // MARK: Projects (used by the widget's configuration intent)

    public static func writeProjects(_ projects: [ProjectListEntry]) {
        write(projects, key: Keys.projects)
        touchUpdatedAt()
        reloadWidgets()
    }

    public static func readProjects() -> [ProjectListEntry] {
        read([ProjectListEntry].self, key: Keys.projects) ?? []
    }

    public static func lastUpdated() -> Date? {
        defaults?.object(forKey: Keys.lastUpdated) as? Date
    }

    // MARK: Internals

    private static func write<T: Encodable>(_ value: T, key: String) {
        guard let defaults else { return }
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            log.error("encode failed for \(key, privacy: .public) — \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            log.error("decode failed for \(key, privacy: .public) — \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private static func touchUpdatedAt() {
        defaults?.set(Date(), forKey: Keys.lastUpdated)
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
