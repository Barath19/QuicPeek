import Foundation
import SwiftData
import AppKit
import UserNotifications
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Scheduler")

/// Drives recurring routines. Combines a foreground Timer (60s tick while the menu-bar
/// app is awake) with `NSBackgroundActivityScheduler` (hourly wake from App Nap), and
/// dedupes per-slot via `Routine.lastRunAt` so a missed slot during sleep runs once on
/// wake — never twice.
@MainActor
final class RoutineScheduler: NSObject, ObservableObject {
    static let shared = RoutineScheduler()

    private var container: ModelContainer?
    private var timer: Timer?
    private var bgActivity: NSBackgroundActivityScheduler?

    @Published private(set) var notificationsAuthorized: Bool = false

    /// Builds the LLM provider used to execute a routine. Injected from the app so the
    /// scheduler doesn't need to know about provider-specific construction.
    var providerFactory: ((Routine) -> LLMProvider)?

    func configure(container: ModelContainer) {
        self.container = container
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await requestNotificationAuthorizationIfNeeded() }

        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        bgActivity?.invalidate()
        let activity = NSBackgroundActivityScheduler(identifier: "com.bharath.QuicPeek.routines")
        activity.repeats = true
        activity.interval = 60 * 60
        activity.tolerance = 30 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            Task { @MainActor in
                self.tick()
                completion(.finished)
            }
        }
        bgActivity = activity

        // Catch up on launch in case a slot passed while quit.
        tick()
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsAuthorized = true
            return
        case .denied:
            notificationsAuthorized = false
            return
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                notificationsAuthorized = granted
            } catch {
                log.error("notif auth failed — \(error.localizedDescription, privacy: .public)")
            }
        @unknown default:
            notificationsAuthorized = false
        }
    }

    private func tick() {
        guard let container else { return }
        let context = container.mainContext
        let descriptor = FetchDescriptor<Routine>(
            predicate: #Predicate { $0.isEnabled }
        )
        let routines = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for routine in routines {
            // Anchor on whichever is earlier between createdAt and lastRunAt so a fresh
            // routine doesn't immediately fire if we're past today's slot.
            let anchor = routine.lastRunAt ?? routine.createdAt
            guard let next = routine.nextFireDate(after: anchor) else { continue }
            if next <= now {
                Task { await run(routine: routine) }
            }
        }
    }

    private func run(routine: Routine) async {
        guard let container else { return }
        let context = container.mainContext

        // Reserve the slot up-front so a slow tick doesn't double-fire.
        routine.lastRunAt = .now
        let routineRun = RoutineRun(startedAt: .now)
        routineRun.routine = routine
        context.insert(routineRun)
        try? context.save()

        guard let providerFactory else {
            routineRun.errorText = "Provider not configured."
            routineRun.finishedAt = .now
            try? context.save()
            return
        }

        let provider = providerFactory(routine)
        let prompt = """
        [Selected Peec AI project_id="\(routine.projectID)". Use this project_id for any tool call.]

        \(routine.promptText)
        """

        var accumulated = ""
        do {
            for try await chunk in provider.stream(prompt: prompt) {
                accumulated = chunk
            }
            routineRun.content = accumulated
            routineRun.finishedAt = .now
            try? context.save()
            await postNotification(for: routine, content: accumulated)
            log.info("routine \(routine.name, privacy: .public) ran ok — \(accumulated.count, privacy: .public) chars")
        } catch {
            routineRun.errorText = error.localizedDescription
            routineRun.finishedAt = .now
            try? context.save()
            log.error("routine run failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Run a routine immediately, regardless of schedule. Used by the "Run now" button.
    func runNow(_ routine: Routine) {
        Task { await run(routine: routine) }
    }

    private func postNotification(for routine: Routine, content: String) async {
        guard notificationsAuthorized, !content.isEmpty else { return }
        let snippet = String(content.prefix(220))
        let nc = UNMutableNotificationContent()
        nc.title = routine.name
        nc.body = snippet
        nc.sound = .default
        nc.userInfo = ["routineID": routine.id.uuidString]
        let request = UNNotificationRequest(
            identifier: "\(routine.id.uuidString)-\(UUID().uuidString)",
            content: nc,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("notification post failed — \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension RoutineScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
