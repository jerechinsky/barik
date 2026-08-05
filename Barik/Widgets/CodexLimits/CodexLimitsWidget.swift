import SwiftUI

struct CodexLimitsWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = CodexLimitsManager.shared
    @State private var widgetFrame: CGRect = .zero

    private var config: ConfigData { configProvider.config }
    private var diameter: CGFloat {
        CGFloat(max(18, config["diameter"]?.doubleValue ?? 18))
    }
    private var ringSpacing: CGFloat {
        CGFloat(max(0, config["spacing"]?.doubleValue ?? 8))
    }
    private var showsPercentage: Bool {
        config["show-percentage"]?.boolValue ?? true
    }

    private var displayedLimits: [DisplayedLimit] {
        guard let snapshot = manager.snapshot else {
            return [DisplayedLimit(id: "unavailable", title: "Usage", window: nil)]
        }

        guard let weekly = snapshot.weekly else {
            return [DisplayedLimit(id: "unavailable", title: "Usage", window: nil)]
        }
        return [DisplayedLimit(id: "weekly", title: "Weekly", window: weekly)]
    }

    private var nextReset: Date? {
        guard let snapshot = manager.snapshot else { return nil }
        return snapshot.weekly?.resetsAt.flatMap { $0 > Date() ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: ringSpacing) {
            if let nextReset {
                ResetCountdown(resetsAt: nextReset)
            }

            ForEach(displayedLimits) { limit in
                LimitRing(
                    title: limit.title,
                    window: limit.window,
                    diameter: diameter,
                    showsPercentage: showsPercentage,
                    fallbackHelp: fallbackHelp
                )
            }
        }
        .contentShape(Rectangle())
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        widgetFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                        widgetFrame = newFrame
                    }
            }
        )
        .background(.black.opacity(0.001))
        .onTapGesture {
            manager.refresh()
            MenuBarPopup.show(
                rect: widgetFrame, id: "codex-limits", colorScheme: colorScheme
            ) {
                CodexLimitsPopup()
            }
        }
        .onAppear {
            manager.startUpdating(config: config)
        }
    }

    private var fallbackHelp: String {
        if manager.isRefreshing {
            return "Refreshing Codex usage…"
        }
        return manager.errorMessage ?? "Codex usage unavailable"
    }
}

private struct DisplayedLimit: Identifiable {
    let id: String
    let title: String
    let window: CodexLimitWindow?
}

private struct ResetCountdown: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(compactRemaining(until: resetsAt, from: context.date))
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(Color.foregroundOutside.opacity(0.72))
                .monospacedDigit()
                .lineLimit(1)
                .help(helpText(relativeTo: context.date))
                .accessibilityLabel("Codex limit reset")
                .accessibilityValue(helpText(relativeTo: context.date))
        }
    }

    private func compactRemaining(until date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        switch seconds {
        case 86_400...:
            return "\(max(1, seconds / 86_400))d"
        case 3_600...:
            return "\(max(1, seconds / 3_600))h"
        case 60...:
            return "\(max(1, seconds / 60))m"
        default:
            return "\(seconds)s"
        }
    }

    private func helpText(relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Next Codex limit resets \(formatter.localizedString(for: resetsAt, relativeTo: now))"
    }
}

private struct LimitRing: View {
    let title: String
    let window: CodexLimitWindow?
    let diameter: CGFloat
    let showsPercentage: Bool
    let fallbackHelp: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.foregroundOutside.opacity(window == nil ? 0.12 : 0.18))

            if let window, window.remainingFraction > 0 {
                PieSlice(progress: window.remainingFraction)
                    .fill(Color.foregroundOutside.opacity(0.55))
                    .animation(
                        .easeInOut(duration: 0.35),
                        value: window.remainingFraction
                    )
            }

            if showsPercentage {
                percentageLabel
                    .foregroundStyle(Color.foregroundOutside)
                    .opacity(window == nil ? 0.4 : 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex \(title) limit")
        .accessibilityValue(accessibilityValue)
    }

    private var percentageLabel: some View {
        Text(window.map { "\($0.remainingPercent)" } ?? "–")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .padding(.horizontal, 0.5)
            .frame(width: diameter, height: diameter)
    }

    private var helpText: String {
        guard let window else { return fallbackHelp }

        var text = "Codex \(title): \(window.remainingPercent)% left"
        if let resetsAt = window.resetsAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            text += " · resets \(formatter.localizedString(for: resetsAt, relativeTo: Date()))"
        }
        return text
    }

    private var accessibilityValue: String {
        guard let window else { return fallbackHelp }
        return "\(window.remainingPercent) percent remaining"
    }
}

private struct PieSlice: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fraction = max(0, min(1, progress))
        guard fraction > 0 else { return Path() }
        if fraction >= 0.9999 {
            return Path(ellipseIn: rect)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x, y: rect.minY))
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

struct CodexLimitsWidget_Previews: PreviewProvider {
    static var previews: some View {
        CodexLimitsWidget()
            .environmentObject(ConfigProvider(config: [:]))
            .frame(width: 80, height: 38)
            .background(.gray)
    }
}
