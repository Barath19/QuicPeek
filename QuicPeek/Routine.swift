import Foundation
import SwiftData

enum RoutineCadence: String, CaseIterable, Identifiable {
    case daily, weekly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

enum RoutinePreset: String, CaseIterable, Identifiable {
    case morningBrief, postmortem, topMovers, custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .morningBrief: return "Morning Brief"
        case .postmortem:   return "Postmortem"
        case .topMovers:    return "Top Movers"
        case .custom:       return "Custom prompt"
        }
    }

    var defaultPrompt: String {
        switch self {
        case .morningBrief:
            return "Give me a morning brief for my brand: visibility, share of voice, and sentiment for this week vs last week. 3–5 bullets max."
        case .postmortem:
            return "Write a short postmortem of the last 7 days — what moved, what didn't, and the single most actionable next step."
        case .topMovers:
            return "What are the biggest changes this week? Top 3 movers across brands or topics, with the direction and magnitude."
        case .custom:
            return ""
        }
    }
}

@Model
final class Routine {
    @Attribute(.unique) var id: UUID
    var name: String
    var cadenceRaw: String
    /// Hour of day, 0…23.
    var hour: Int
    /// Minute of hour, 0…59.
    var minute: Int
    /// 1=Sunday … 7=Saturday. Only used when cadence is weekly.
    var weekday: Int
    var presetRaw: String
    var customPrompt: String
    var projectID: String
    var isEnabled: Bool
    var lastRunAt: Date?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RoutineRun.routine)
    var runs: [RoutineRun] = []

    var cadence: RoutineCadence {
        get { RoutineCadence(rawValue: cadenceRaw) ?? .daily }
        set { cadenceRaw = newValue.rawValue }
    }

    var preset: RoutinePreset {
        get { RoutinePreset(rawValue: presetRaw) ?? .morningBrief }
        set { presetRaw = newValue.rawValue }
    }

    var promptText: String {
        preset == .custom ? customPrompt : preset.defaultPrompt
    }

    init(
        name: String,
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int = 2,
        preset: RoutinePreset,
        customPrompt: String = "",
        projectID: String,
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.cadenceRaw = cadence.rawValue
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.presetRaw = preset.rawValue
        self.customPrompt = customPrompt
        self.projectID = projectID
        self.isEnabled = isEnabled
        self.createdAt = .now
    }

    /// Next time this routine should fire after `date`. Uses Calendar.next so DST and
    /// month/year rollovers are handled correctly.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if cadence == .weekly { components.weekday = weekday }
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    /// User-facing schedule string, e.g. "Daily at 9:00 AM" or "Weekly on Mondays at 9:00 AM".
    func scheduleDescription(calendar: Calendar = .current) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = calendar.date(from: comps) ?? Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let time = timeFmt.string(from: date)
        switch cadence {
        case .daily:
            return "Daily at \(time)"
        case .weekly:
            let weekdayName = calendar.weekdaySymbols[max(0, min(6, weekday - 1))]
            return "\(weekdayName)s at \(time)"
        }
    }
}

@Model
final class RoutineRun {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var content: String
    var errorText: String?
    var routine: Routine?

    init(startedAt: Date = .now, content: String = "", errorText: String? = nil) {
        self.id = UUID()
        self.startedAt = startedAt
        self.content = content
        self.errorText = errorText
    }

    var didSucceed: Bool { errorText == nil && !content.isEmpty }
}
