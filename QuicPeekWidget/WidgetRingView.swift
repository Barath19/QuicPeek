import SwiftUI

/// Compact ring renderer used by the Brand Rings widget. Standalone so the widget target
/// doesn't need to import the main app's MetricRing (which is not part of this target).
struct WidgetRingView: View {
    let label: String
    let progress: Double
    let center: String
    var delta: String? = nil
    let tint: Color
    var big: Bool = false

    private var clamped: Double { max(0, min(progress, 1)) }
    private var diameter: CGFloat { big ? 76 : 52 }
    private var stroke: CGFloat { big ? 7 : 5 }
    private var centerFontSize: CGFloat { big ? 16 : 11 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: max(0.001, clamped))
                    .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(center)
                    .font(.system(size: centerFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            .frame(width: diameter, height: diameter)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let delta {
                Text(delta)
                    .font(.system(.caption2, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var deltaColor: Color {
        guard let delta else { return .secondary }
        if delta.hasPrefix("+") { return .green }
        if delta.hasPrefix("-") { return .red }
        return .secondary
    }
}
