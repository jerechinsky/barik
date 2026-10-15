import SwiftUI

struct CodexLimitsWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = CodexLimitsManager.shared
    @State private var widgetFrame: CGRect = .zero

    private var config: ConfigData { configProvider.config }
    private var style: CodexLimitsStyle {
        CodexLimitsStyle(rawValue: config["style"]?.stringValue?.lowercased() ?? "bar")
            ?? .bar
    }
    private var compactPieDiameter: CGFloat {
        CGFloat(max(12, min(24, config["pie-diameter"]?.doubleValue ?? 21)))
    }
    private var numberedPieDiameter: CGFloat {
        CGFloat(max(18, min(40, config["diameter"]?.doubleValue ?? 21)))
    }
    private var todayColor: Color {
        Color(hex: config["today-color"]?.stringValue ?? "#35E875") ?? .green
    }
    private var barWidth: CGFloat {
        CGFloat(max(32, min(100, config["bar-width"]?.doubleValue ?? 64)))
    }
    private var barHeight: CGFloat {
        CGFloat(max(5, min(12, config["bar-height"]?.doubleValue ?? 8)))
    }
    private var elementSpacing: CGFloat {
        CGFloat(max(0, config["spacing"]?.doubleValue ?? 7))
    }
    private var showsPercentage: Bool {
        config["show-percentage"]?.boolValue ?? true
    }

    private var weeklyWindow: CodexLimitWindow? {
        manager.snapshot?.weekly
    }

    private var nextReset: Date? {
        weeklyWindow?.resetsAt.flatMap { $0 > Date() ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: style == .pie ? 5 : elementSpacing) {
            if let nextReset {
                ResetCountdown(resetsAt: nextReset)
            }

            switch style {
            case .bar:
                HStack(spacing: 5) {
                    CodexSegmentedBar(
                        window: weeklyWindow,
                        width: barWidth,
                        height: barHeight
                    )

                    if showsPercentage {
                        quotaLabels
                    }
                }
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex weekly limit")
                .accessibilityValue(accessibilityValue)

            case .pie:
                HStack(spacing: 5) {
                    CodexLimitPie(
                        window: weeklyWindow,
                        availableTodayPercent: weeklyWindow?
                            .availableToSpendToday()?.exactPercent,
                        diameter: compactPieDiameter,
                        todayColor: todayColor
                    )

                    if showsPercentage {
                        quotaLabels
                    }
                }
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex weekly limit")
                .accessibilityValue(accessibilityValue)

            case .pieNumber:
                CodexNumberedPie(
                    window: weeklyWindow,
                    diameter: numberedPieDiameter,
                    showsPercentage: showsPercentage
                )
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex weekly limit")
                .accessibilityValue(accessibilityValue)
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

    @ViewBuilder
    private var quotaLabels: some View {
        if let weeklyWindow,
           let budget = weeklyWindow.availableToSpendToday() {
            CodexQuotaLabels(
                budget: budget,
                remaining: weeklyWindow.remainingPercent
            )
        } else {
            Text(weeklyWindow.map { "\($0.remainingPercent)%" } ?? "–%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.foregroundOutside)
                .opacity(weeklyWindow == nil ? 0.4 : 0.88)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private var helpText: String {
        guard let weeklyWindow else { return fallbackHelp }

        var text = "Codex weekly: \(weeklyWindow.remainingPercent)% left"
        if let budget = weeklyWindow.availableToSpendToday() {
            text += " · \(budget.compactPercentText) available \(periodText(for: budget)); keep \(budget.targetRemainingPercent)%"
        }
        return text
    }

    private var accessibilityValue: String {
        guard let weeklyWindow else { return fallbackHelp }

        var value = "\(weeklyWindow.remainingPercent) percent remaining"
        if let budget = weeklyWindow.availableToSpendToday() {
            value += ", \(budget.spokenPercentText) available \(periodText(for: budget))"
        }
        return value
    }

    private func periodText(for budget: CodexDailyBudget) -> String {
        if budget.endsAtReset {
            return "before reset"
        }
        return Calendar.current.component(.hour, from: Date()) >= 17
            ? "tonight"
            : "today"
    }

    private var fallbackHelp: String {
        if manager.isRefreshing {
            return "Refreshing Codex usage…"
        }
        return manager.errorMessage ?? "Codex usage unavailable"
    }
}

private enum CodexLimitsStyle: String {
    case bar
    case pie
    case pieNumber = "pie-number"
}

private struct CodexQuotaLabels: View {
    let budget: CodexDailyBudget
    let remaining: Int

    var body: some View {
        CodexQuotaLabelLayout {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(unsignedPercentText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .overlay(alignment: .leading) {
                        if budget.conservativePercent < 0 {
                            Text("-")
                                .font(.system(size: 9.5, weight: .semibold))
                                .fixedSize()
                                .frame(width: 0, alignment: .trailing)
                        }
                    }

                Text(compactPeriodText)
                    .font(.system(size: 8, weight: .light))
                    .opacity(0.55)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(remaining)%")
                    .font(.system(size: 11, weight: .semibold))
                Text("left")
                    .font(.system(size: 8, weight: .light))
                    .opacity(0.55)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(Color.foregroundOutside)
        .monospacedDigit()
        .lineLimit(1)
        .contentTransition(.numericText())
    }

    private var compactPeriodText: String {
        budget.endsAtReset ? "reset" : "today"
    }

    private var unsignedPercentText: String {
        let text = budget.compactPercentText
        return text.hasPrefix("-") ? String(text.dropFirst()) : text
    }
}

/// Keep the daily percentage at its original size and fit the period label
/// into the lower row's width. The minus hangs outside the percentage.
private struct CodexQuotaLabelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let bottom = subviews[1].sizeThatFits(.unspecified)
        let top = subviews[0].sizeThatFits(ProposedViewSize(width: bottom.width, height: nil))
        return CGSize(width: bottom.width, height: top.height + bottom.height - 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let bottom = subviews[1].sizeThatFits(.unspecified)
        subviews[0].place(
            at: CGPoint(x: bounds.maxX, y: bounds.minY),
            anchor: .topTrailing,
            proposal: ProposedViewSize(width: bottom.width, height: nil)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.maxY),
            anchor: .bottomTrailing,
            proposal: ProposedViewSize(bottom)
        )
    }
}

private struct ResetCountdown: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: resetsAt.timeIntervalSinceNow > 60 ? 60 : 1)) { context in
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
            return "\((seconds + 86_399) / 86_400)d"
        case 3_600...:
            return "1d"
        case 60...:
            return "\(max(1, seconds / 60))m"
        default:
            return "\(seconds)s"
        }
    }

    private func helpText(relativeTo now: Date) -> String {
        return "Codex resets \(resetsAt.formatted(.dateTime.weekday(.wide).day().month().hour().minute())) \(TimeZone.current.abbreviation(for: resetsAt) ?? "")"
    }
}

struct CodexSegmentedBar: View {
    let window: CodexLimitWindow?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width)
            let remainingFraction = window?.remainingFraction ?? 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.foregroundOutside.opacity(0.14))

                if window != nil, remainingFraction > 0 {
                    Rectangle()
                        .fill(Color.foregroundOutside.opacity(0.58))
                        .frame(width: availableWidth * remainingFraction)
                }

                dayDividers(availableWidth: availableWidth)
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.foregroundOutside.opacity(0.18), lineWidth: 0.5)
            }
            .animation(.easeInOut(duration: 0.35), value: remainingFraction)
        }
        .frame(width: width, height: height)
    }

    private func dayDividers(availableWidth: CGFloat) -> some View {
        ForEach(1..<7, id: \.self) { day in
            Rectangle()
                .fill(Color.foregroundOutsideInvert.opacity(0.72))
                .frame(width: 0.75)
                .offset(x: availableWidth * CGFloat(day) / 7 - 0.375)
        }
    }

}

private struct CodexLimitPie: View {
    let window: CodexLimitWindow?
    let availableTodayPercent: Double?
    let diameter: CGFloat
    let todayColor: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.foregroundOutside.opacity(window == nil ? 0.12 : 0.18))

            if let window, window.remainingFraction > 0 {
                CodexPieSlice(progress: window.remainingFraction)
                    .fill(Color.foregroundOutside.opacity(0.55))
                    .animation(
                        .easeInOut(duration: 0.35),
                        value: window.remainingFraction
                    )
            }

            if let window,
               let availableTodayPercent,
               availableTodayPercent > 0 {
                let todayFraction = min(
                    window.remainingFraction,
                    availableTodayPercent / 100
                )
                CodexPieSector(
                    startProgress: window.remainingFraction - todayFraction,
                    endProgress: window.remainingFraction
                )
                .fill(todayColor.opacity(0.88))
                .animation(.easeInOut(duration: 0.35), value: todayFraction)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .stroke(Color.foregroundOutside.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
    }
}

private struct CodexNumberedPie: View {
    let window: CodexLimitWindow?
    let diameter: CGFloat
    let showsPercentage: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.foregroundOutside.opacity(window == nil ? 0.12 : 0.18))

            if let window, window.remainingFraction > 0 {
                CodexPieSlice(progress: window.remainingFraction)
                    .fill(Color.foregroundOutside.opacity(0.55))
                    .animation(
                        .easeInOut(duration: 0.35),
                        value: window.remainingFraction
                    )
            }

            if showsPercentage {
                Text(window.map { "\($0.remainingPercent)" } ?? "–")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.foregroundOutside)
                    .opacity(window == nil ? 0.4 : 1)
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .padding(.horizontal, 0.5)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct CodexPieSector: Shape {
    var startProgress: Double
    var endProgress: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startProgress, endProgress) }
        set {
            startProgress = newValue.first
            endProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let start = max(0, min(1, startProgress))
        let end = max(start, min(1, endProgress))
        guard end > start else { return Path() }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addLine(
            to: CGPoint(
                x: center.x + radius * CGFloat(sin(2 * Double.pi * start)),
                y: center.y - radius * CGFloat(cos(2 * Double.pi * start))
            )
        )
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90 + 360 * start),
            endAngle: .degrees(-90 + 360 * end),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct CodexPieSlice: Shape {
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
        HStack(spacing: 7) {
            Text("5d")
                .font(.system(size: 10, weight: .light))
                .opacity(0.72)
            CodexSegmentedBar(
                window: CodexLimitWindow(
                    usedPercent: 18,
                    windowDurationMinutes: 7 * 24 * 60,
                    resetsAt: Date().addingTimeInterval(5 * 24 * 60 * 60)
                ),
                width: 64,
                height: 8
            )
            Text("82%")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding()
        .frame(height: 38)
        .background(.gray)
    }
}
