import WidgetKit
import SwiftUI
import AppIntents

struct BrandRingsWidget: Widget {
    let kind: String = "com.bharath.QuicPeek.BrandRings"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectProjectIntent.self,
            provider: BrandRingsProvider()
        ) { entry in
            BrandRingsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Brand Rings")
        .description("Visibility, Share of Voice, and Sentiment for a Peec project.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline entry

struct BrandRingsEntry: TimelineEntry {
    let date: Date
    let snapshot: BrandSnapshot?
    let topAction: TopActionSnapshot?
    let configuration: SelectProjectIntent
}

// MARK: - Timeline provider

struct BrandRingsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BrandRingsEntry {
        BrandRingsEntry(
            date: .now,
            snapshot: Self.placeholderSnapshot,
            topAction: nil,
            configuration: SelectProjectIntent()
        )
    }

    func snapshot(for configuration: SelectProjectIntent, in context: Context) async -> BrandRingsEntry {
        BrandRingsEntry(
            date: .now,
            snapshot: resolveBrand(for: configuration),
            topAction: resolveAction(for: configuration),
            configuration: configuration
        )
    }

    func timeline(for configuration: SelectProjectIntent, in context: Context) async -> Timeline<BrandRingsEntry> {
        let entry = BrandRingsEntry(
            date: .now,
            snapshot: resolveBrand(for: configuration),
            topAction: resolveAction(for: configuration),
            configuration: configuration
        )
        // System will reload sooner if the main app calls `WidgetCenter.reloadAllTimelines`
        // after a fetch; this is just the upper bound on staleness.
        let next = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func resolveBrand(for configuration: SelectProjectIntent) -> BrandSnapshot? {
        if let id = configuration.project?.id, let s = SharedStore.brand(forProjectID: id) {
            return s
        }
        return SharedStore.readBrands().first
    }

    private func resolveAction(for configuration: SelectProjectIntent) -> TopActionSnapshot? {
        if let id = configuration.project?.id, let a = SharedStore.topAction(forProjectID: id) {
            return a
        }
        return SharedStore.readTopActions().first
    }

    private static let placeholderSnapshot = BrandSnapshot(
        projectID: "preview",
        projectName: "Acme",
        visibility: 0.42,
        visibilityDelta: 0.021,
        shareOfVoice: 0.31,
        shareOfVoiceDelta: -0.005,
        sentiment: 78,
        sentimentDelta: 4,
        fetchedAt: .now
    )
}

// MARK: - Entry view

struct BrandRingsEntryView: View {
    let entry: BrandRingsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        case .systemMedium: mediumView
        case .systemLarge:  largeView
        default:            mediumView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let s = entry.snapshot {
                HStack(spacing: 6) {
                    WidgetRingView(label: "Vis", progress: s.visibility ?? 0,
                                   center: percent(s.visibility),
                                   delta: deltaPP(s.visibilityDelta), tint: .cyan)
                    WidgetRingView(label: "SoV", progress: s.shareOfVoice ?? 0,
                                   center: percent(s.shareOfVoice),
                                   delta: deltaPP(s.shareOfVoiceDelta), tint: .pink)
                    WidgetRingView(label: "Sent", progress: (s.sentiment ?? 0) / 100,
                                   center: sentimentText(s.sentiment),
                                   delta: deltaRaw(s.sentimentDelta), tint: .green)
                }
            } else {
                emptyRings
            }
            Spacer(minLength: 0)
            staleness
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let s = entry.snapshot {
                HStack(spacing: 12) {
                    WidgetRingView(label: "Visibility", progress: s.visibility ?? 0,
                                   center: percent(s.visibility),
                                   delta: deltaPP(s.visibilityDelta), tint: .cyan)
                    WidgetRingView(label: "Share of Voice", progress: s.shareOfVoice ?? 0,
                                   center: percent(s.shareOfVoice),
                                   delta: deltaPP(s.shareOfVoiceDelta), tint: .pink)
                    WidgetRingView(label: "Sentiment", progress: (s.sentiment ?? 0) / 100,
                                   center: sentimentText(s.sentiment),
                                   delta: deltaRaw(s.sentimentDelta), tint: .green)
                }
            } else {
                emptyRings
            }
            Spacer(minLength: 0)
            staleness
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let s = entry.snapshot {
                HStack(spacing: 14) {
                    WidgetRingView(label: "Visibility", progress: s.visibility ?? 0,
                                   center: percent(s.visibility),
                                   delta: deltaPP(s.visibilityDelta), tint: .cyan, big: true)
                    WidgetRingView(label: "Share of Voice", progress: s.shareOfVoice ?? 0,
                                   center: percent(s.shareOfVoice),
                                   delta: deltaPP(s.shareOfVoiceDelta), tint: .pink, big: true)
                    WidgetRingView(label: "Sentiment", progress: (s.sentiment ?? 0) / 100,
                                   center: sentimentText(s.sentiment),
                                   delta: deltaRaw(s.sentimentDelta), tint: .green, big: true)
                }
            } else {
                emptyRings
            }
            if let a = entry.topAction {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(a.title)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let score = a.score {
                        Text(actionScore(score))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            staleness
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.pie.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.snapshot?.projectName ?? "QuicPeek")
                .font(.caption).fontWeight(.medium)
                .lineLimit(1)
            Spacer()
        }
    }

    @ViewBuilder
    private var staleness: some View {
        if let fetched = entry.snapshot?.fetchedAt {
            let age = Date().timeIntervalSince(fetched)
            let stale = age > 24 * 3600
            HStack(spacing: 3) {
                if stale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                }
                Text("\(stale ? "Stale" : "Updated") \(fetched, style: .relative) ago")
            }
            .font(.caption2)
            .foregroundStyle(stale ? Color.orange : Color.secondary.opacity(0.6))
        } else {
            Text("Open QuicPeek to fetch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Three faded rings rendered when no snapshot exists yet — keeps the widget's
    /// visual structure consistent so users see the same rings before and after the
    /// first fetch lands.
    private var emptyRings: some View {
        HStack(spacing: family == .systemSmall ? 6 : 12) {
            WidgetRingView(label: "Visibility", progress: 0, center: "—", tint: .secondary)
            WidgetRingView(label: "Share of Voice", progress: 0, center: "—", tint: .secondary)
            WidgetRingView(label: "Sentiment", progress: 0, center: "—", tint: .secondary)
        }
        .opacity(0.7)
    }

    // MARK: formatting

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func sentimentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private func deltaPP(_ value: Double?) -> String? {
        guard let value else { return nil }
        let pp = value * 100
        let sign = pp > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", pp))pp"
    }

    private func deltaRaw(_ value: Double?) -> String? {
        guard let value else { return nil }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", value))"
    }

    private func actionScore(_ value: Double) -> String {
        if value <= 1 { return "\(Int((value * 100).rounded()))" }
        return "\(Int(value.rounded()))"
    }
}
