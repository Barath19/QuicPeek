import Foundation
import SwiftData
import AppKit
import UserNotifications
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "Scheduler")

/// Drives recurring routines. Combines a foreground Timer (60s tick while the menu-bar
/// app is awake) with `NSBackgroundActivityScheduler` (hourly wake from App Nap), and
/// dedupes per-slot synchronously via `Routine.lastRunAt` plus an in-flight `Set` so a
/// missed slot during sleep runs once on wake — never twice.
///
/// Routines run with **no live MCP/tool access**: the scheduler pre-fetches the project's
/// brand report and recommended actions, inlines them as context, and constructs a
/// provider that has neither `mcp_servers` (Anthropic) nor local tools (Apple). This
/// closes the headless prompt-injection surface where attacker-controlled Peec data could
/// otherwise drive arbitrary tool calls or notification spoofing.
@MainActor
final class RoutineScheduler: NSObject, ObservableObject {
    static let shared = RoutineScheduler()

    private var container: ModelContainer?
    private var timer: Timer?
    private var bgActivity: NSBackgroundActivityScheduler?
    private var inFlight: Set<UUID> = []
    /// Earliest time a given routine is allowed to fire again, regardless of schedule.
    /// Hard floor against runaway scheduling if a save fails or a clock jumps.
    private var nextAllowedRun: [UUID: Date] = [:]

    @Published private(set) var notificationsAuthorized: Bool = false

    /// Builds the LLM provider used to execute a routine. The factory is given the
    /// pre-fetched project context so it can append it to the system instructions.
    var providerFactory: ((Routine, _ inlinedContext: String) -> LLMProvider)?

    func configure(container: ModelContainer) {
        self.container = container
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { [weak self] in await self?.requestNotificationAuthorizationIfNeeded() }

        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        bgActivity?.invalidate()
        let activity = NSBackgroundActivityScheduler(identifier: "com.bharath.QuicPeek.routines")
        activity.repeats = true
        activity.interval = 60 * 60
        activity.tolerance = 30 * 60
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                defer { completion(.finished) }
                self?.tick()
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
        case .denied:
            notificationsAuthorized = false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                notificationsAuthorized = granted
            } catch {
                log.error("notif auth failed — \(error.localizedDescription, privacy: .private)")
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
        guard let routines = try? context.fetch(descriptor) else { return }

        let now = Date()
        for routine in routines {
            // Skip routines already running so a slow stream can't be re-enqueued by a
            // subsequent tick.
            if inFlight.contains(routine.id) { continue }
            // Per-routine min-interval clamp guards against runaway scheduling.
            if let earliest = nextAllowedRun[routine.id], earliest > now { continue }

            let anchor = routine.lastRunAt ?? routine.createdAt
            guard let next = routine.nextFireDate(after: anchor) else { continue }
            if next > now { continue }

            // Reserve the slot synchronously, before launching any async work, so a
            // re-entrant tick(60s later) sees the new lastRunAt and skips this routine.
            routine.lastRunAt = now
            do {
                try context.save()
            } catch {
                log.error("could not reserve routine slot — \(error.localizedDescription, privacy: .private)")
                continue
            }

            inFlight.insert(routine.id)
            // Hold the persistent ID across the await boundary so we refetch a fresh
            // `Routine` after async work — SwiftData models aren't Sendable across awaits.
            let id = routine.id
            Task { [weak self] in
                await self?.run(routineID: id)
            }
        }
    }

    /// Run a routine immediately, regardless of schedule. Used by the "Run now" button.
    func runNow(_ routine: Routine) {
        guard !inFlight.contains(routine.id) else { return }
        inFlight.insert(routine.id)
        let id = routine.id
        Task { [weak self] in await self?.run(routineID: id) }
    }

    private func run(routineID: UUID) async {
        defer {
            inFlight.remove(routineID)
            // 5-minute floor between consecutive runs of the same routine.
            nextAllowedRun[routineID] = Date().addingTimeInterval(5 * 60)
        }

        guard let container else { return }
        let context = container.mainContext

        var routineDescriptor = FetchDescriptor<Routine>(
            predicate: #Predicate { $0.id == routineID }
        )
        routineDescriptor.fetchLimit = 1
        guard let routine = (try? context.fetch(routineDescriptor))?.first else { return }

        let routineRun = RoutineRun(startedAt: .now)
        routineRun.routine = routine
        context.insert(routineRun)
        save(context, "creating run")

        guard let providerFactory else {
            routineRun.errorText = "Provider not configured."
            routineRun.finishedAt = .now
            save(context, "no provider")
            return
        }

        // Pre-fetch project context so the provider doesn't need live tool access.
        let inlined: String
        do {
            inlined = try await prefetchContext(for: routine)
        } catch {
            routineRun.errorText = "Couldn't fetch Peec context: \(error.localizedDescription)"
            routineRun.finishedAt = .now
            save(context, "prefetch failed")
            return
        }

        let provider = providerFactory(routine, inlined)
        let prompt = routine.promptText

        var accumulated = ""
        do {
            for try await chunk in provider.stream(prompt: prompt) {
                accumulated = chunk
            }
            routineRun.content = accumulated
            routineRun.finishedAt = .now
            save(context, "ok run")
            await postNotification(for: routine, content: accumulated)
            log.info("routine ran ok — \(accumulated.count, privacy: .public) chars")
        } catch {
            routineRun.errorText = error.localizedDescription
            routineRun.finishedAt = .now
            save(context, "failed run")
            log.error("routine run failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Fetch brand report + recommended actions for the routine's project so we can inline
    /// them as context. No live tool access for the model.
    private func prefetchContext(for routine: Routine) async throws -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let start = fmt.string(from: weekAgo)
        let end = fmt.string(from: now)

        let mcp = PeecMCP.shared
        async let brand = mcp.callTool(
            name: "get_brand_report",
            arguments: ["project_id": routine.projectID, "start_date": start, "end_date": end]
        )
        async let actions = mcp.callTool(
            name: "get_actions",
            arguments: ["project_id": routine.projectID, "start_date": start, "end_date": end]
        )
        let (brandText, actionsText) = try await (brand, actions)
        return """
        Pre-fetched Peec data for project \(routine.projectID), window \(start) → \(end):

        ## Brand report
        \(brandText)

        ## Recommended actions
        \(actionsText)

        Reason from this data only. Do not request additional tools.
        """
    }

    private func save(_ context: ModelContext, _ tag: StaticString) {
        do {
            try context.save()
        } catch {
            log.error("save (\(tag, privacy: .public)) failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    private func postNotification(for routine: Routine, content: String) async {
        guard notificationsAuthorized, !content.isEmpty else { return }
        let safeBody = Self.sanitizeNotificationBody(content)
        let nc = UNMutableNotificationContent()
        // Prefix with a fixed marker the LLM can't replace, so a model that emits text
        // mimicking a system prompt can't spoof the banner.
        nc.title = "Brief · \(routine.name)"
        nc.body = safeBody
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
            log.error("notification post failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Strip newlines, control characters, URL-like substrings, and anything that could
    /// make a banner look like a different app's prompt. Caps length at 220 chars.
    static func sanitizeNotificationBody(_ raw: String) -> String {
        var s = raw
        // Collapse all whitespace runs to a single space.
        s = s.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        // Drop any URL-like substring (http/https/javascript/file/etc.).
        s = s.replacingOccurrences(
            of: "[a-zA-Z][a-zA-Z0-9+.-]{1,}://[^\\s]+",
            with: "[link]",
            options: .regularExpression
        )
        // Filter remaining control characters defensively.
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 220 {
            s = String(s.prefix(217)) + "…"
        }
        return s
    }
}

extension RoutineScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Include `.list` so a notification the user misses lives in Notification Center
        // history rather than disappearing once dismissed from the banner.
        return [.banner, .sound, .list]
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
