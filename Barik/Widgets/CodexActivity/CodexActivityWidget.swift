import SwiftUI

struct CodexActivityWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var manager = CodexActivityManager.shared
    @ObservedObject private var displayManager = DisplayManager.shared

    private var config: ConfigData { configProvider.config }
    private var dotDiameter: CGFloat {
        CGFloat(max(4, min(12, config["dot-diameter"]?.doubleValue ?? 8)))
    }
    private var dotSpacing: CGFloat {
        CGFloat(max(2, min(8, config["dot-spacing"]?.doubleValue ?? 4)))
    }
    private var dotColor: Color {
        if let configuredColor = config["color"]?.stringValue,
           let color = Color(hex: configuredColor) {
            return color
        }
        return Color(hex: "#E59B3A") ?? .orange
    }
    private var unreadDotColor: Color {
        Color(hex: config["unread-color"]?.stringValue ?? "#3FAF72")
            ?? Color(red: 63 / 255, green: 175 / 255, blue: 114 / 255)
    }
    private var readCompletedDotColor: Color {
        if let configuredColor = config["read-completed-color"]?.stringValue,
           let color = Color(hex: configuredColor) {
            return color
        }
        return Color.foregroundOutside.opacity(0.5)
    }
    private var hitTargetHeight: CGFloat {
        max(configManager.config.experimental.foreground.resolveHeight(), 1)
    }
    private var totalCount: Int {
        visibleRunningActivities.count + visibleCompletedActivities.count
    }
    private var selection: CodexActivitySelection {
        // Wider displays can spare additional dots without squeezing music.
        let width = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }?.frame.width ?? 1512
        return CodexActivitySelection(
            running: manager.runningActivities, recent: manager.recentActivities,
            maximumRunning: max(3, 3 + Int((width - 1512) / 240)))
    }
    private var visibleRunningActivities: [CodexActivity] { selection.running }
    private var visibleCompletedActivities: [CodexActivity] { selection.completed }

    var body: some View {
        ZStack(alignment: .leading) {
            // Keep a real view mounted while the widget is visually hidden.
            // An empty Group never receives onAppear, so polling never starts.
            Color.clear
                .frame(width: 0, height: dotDiameter)

            if totalCount > 0 {
                CodexActivityDots(
                    runningActivities: visibleRunningActivities,
                    unreadActivities: visibleCompletedActivities,
                    diameter: dotDiameter,
                    spacing: dotSpacing,
                    hitTargetHeight: hitTargetHeight,
                    runningColor: dotColor,
                    unreadColor: unreadDotColor,
                    readCompletedColor: readCompletedDotColor,
                    onActivate: openCodexTask
                )
                // The tiny dots read closer to the divider than text or a ring
                // at the same layout spacing, so balance the optical gap.
                .padding(.trailing, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Codex activity")
                .accessibilityValue(helpText)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if let activity = visibleRunningActivities.first
                        ?? visibleCompletedActivities.last {
                        openCodexTask(activity)
                    }
                }
                .experimentalConfiguration(
                    horizontalPadding: 8,
                    cornerRadius: 15
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: manager.runningCount)
        .animation(.easeOut(duration: 0.18), value: visibleCompletedActivities.map(\.id))
        .onAppear {
            manager.startUpdating(config: config)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if manager.runningCount > 0 {
            parts.append(manager.runningCount == 1
                ? "1 Codex task running"
                : "\(manager.runningCount) Codex tasks running")
        }
        let completedCount = visibleCompletedActivities.count
        if completedCount > 0 {
            parts.append(completedCount == 1
                ? "1 recent completed Codex task"
                : "\(completedCount) recent completed Codex tasks")
        }
        return parts.joined(separator: ", ")
    }

    private func openCodexTask(_ activity: CodexActivity) {
        guard let url = URL(string: "codex://threads/\(activity.id)"),
              NSWorkspace.shared.open(url)
        else {
            NSSound.beep()
            return
        }

        if !activity.isRunning {
            manager.dismissCompletedThread(activity.id)
        }
    }
}

private struct CodexActivityDots: View {
    let runningActivities: [CodexActivity]
    let unreadActivities: [CodexActivity]
    let diameter: CGFloat
    let spacing: CGFloat
    let hitTargetHeight: CGFloat
    let runningColor: Color
    let unreadColor: Color
    let readCompletedColor: Color
    let onActivate: (CodexActivity) -> Void

    @State private var hoveredActivityID: String?

    private var activityCount: Int {
        runningActivities.count + unreadActivities.count
    }

    private var activities: [CodexActivity] {
        unreadActivities + runningActivities
    }

    private var centerDistance: CGFloat {
        let compactCenterDistance = diameter + spacing
        let previousExpandedCenterDistance = max(20, diameter + 12) + max(5, spacing)
        return compactCenterDistance
            + (previousExpandedCenterDistance - compactCenterDistance) * 0.3
    }

    private var clusterGeometry: CodexActivityClusterGeometry {
        CodexActivityClusterGeometry(
            count: activityCount,
            diameter: diameter,
            centerDistance: centerDistance
        )
    }

    var body: some View {
        let geometry = clusterGeometry

        ZStack(alignment: .topLeading) {
            // Recent completed work stays on the left; active work stays right.
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                let isRunning = index >= unreadActivities.count
                let completedColor = activity.isUnread
                    ? unreadColor
                    : readCompletedColor
                let placement = geometry.placements[index]
                CodexActivityDot(
                    activity: activity,
                    color: isRunning ? runningColor : completedColor,
                    state: isRunning ? .running : .completed,
                    diameter: diameter,
                    targetWidth: placement.hitboxWidth,
                    hitTargetHeight: hitTargetHeight,
                    visualOffsetX: placement.visualOffsetX,
                    isHighlighted: hoveredActivityID == activity.id,
                    onActivate: onActivate
                )
                .position(
                    x: placement.hitboxCenterX,
                    y: hitTargetHeight / 2
                )
                .animation(.easeOut(duration: 0.18), value: activity.isUnread)
            }
        }
        .frame(width: geometry.width, height: hitTargetHeight)
        .contentShape(Rectangle())
        .background(.black.opacity(0.001))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredActivityID = activityIndex(at: location).map {
                    activities[$0].id
                }
            case .ended:
                hoveredActivityID = nil
                CodexActivityTooltipManager.shared.hideAll()
            }
        }
    }

    private func activityIndex(at location: CGPoint) -> Int? {
        guard !activities.isEmpty else { return nil }
        let rawIndexFromLeft = Int(
            ((location.x - diameter / 2) / centerDistance).rounded()
        )
        return min(max(rawIndexFromLeft, 0), activityCount - 1)
    }

}

private struct CodexActivityClusterGeometry {
    struct Placement {
        let hitboxCenterX: CGFloat
        let hitboxWidth: CGFloat
        let visualOffsetX: CGFloat
    }

    let width: CGFloat
    let placements: [Placement]

    init(
        count: Int,
        diameter: CGFloat,
        centerDistance: CGFloat
    ) {
        guard count > 0 else {
            width = 0
            placements = []
            return
        }

        let gaps = [CGFloat](
            repeating: centerDistance,
            count: max(0, count - 1)
        )
        let computedWidth = diameter + gaps.reduce(0, +)

        var centers = [CGFloat](repeating: diameter / 2, count: count)
        if count > 1 {
            for index in 1..<count {
                centers[index] = centers[index - 1] + gaps[index - 1]
            }
        }

        placements = centers.enumerated().map { index, center in
            let leftBoundary = index == 0
                ? 0
                : (centers[index - 1] + center) / 2
            let rightBoundary = index == count - 1
                ? computedWidth
                : (center + centers[index + 1]) / 2
            let hitboxCenter = (leftBoundary + rightBoundary) / 2
            return Placement(
                hitboxCenterX: hitboxCenter,
                hitboxWidth: rightBoundary - leftBoundary,
                visualOffsetX: center - hitboxCenter
            )
        }
        width = computedWidth
    }
}

private struct CodexActivityDot: View {
    enum ActivityState: Equatable {
        case running
        case completed

        var label: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            }
        }
    }

    let activity: CodexActivity
    let color: Color
    let state: ActivityState
    let diameter: CGFloat
    let targetWidth: CGFloat
    let hitTargetHeight: CGFloat
    let visualOffsetX: CGFloat
    let isHighlighted: Bool
    let onActivate: (CodexActivity) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var globalFrame = CGRect.zero

    var body: some View {
        Button {
            onActivate(activity)
        } label: {
            ZStack {
                Circle()
                    .fill(color.opacity(isHighlighted ? 0.18 : 0))
                    .frame(width: diameter + 10, height: diameter + 10)
                Circle()
                    .stroke(
                        color.opacity(isHighlighted ? 0.85 : 0),
                        lineWidth: 1
                    )
                    .frame(width: diameter + 5, height: diameter + 5)
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
                    .shadow(
                        color: color.opacity(isHighlighted ? 0.7 : 0),
                        radius: isHighlighted ? 4 : 0
                    )
            }
            .offset(x: visualOffsetX)
            .frame(width: targetWidth, height: hitTargetHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(CodexActivityDotButtonStyle(isHovered: isHighlighted))
        .background(.black.opacity(0.001))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateGlobalFrame(geometry.frame(in: .global))
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in
                        updateGlobalFrame(frame)
                    }
            }
        }
        .onChange(of: isHighlighted) { _, highlighted in
            guard highlighted else { return }
            CodexActivityTooltipManager.shared.schedule(
                for: activity.id,
                rect: globalFrame,
                title: activity.title,
                status: statusText,
                details: detailsText,
                color: color,
                colorScheme: colorScheme
            )
        }
        .accessibilityLabel("Open \(activity.title) in Codex")
        .accessibilityValue(
            [statusText, detailsText].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
        .onDisappear {
            CodexActivityTooltipManager.shared.hide(for: activity.id)
        }
    }

    private func updateGlobalFrame(_ hitboxFrame: CGRect) {
        let visualFrame = CGRect(
            x: hitboxFrame.midX + visualOffsetX - diameter / 2,
            y: hitboxFrame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        globalFrame = visualFrame
    }

    private var statusText: String {
        switch state {
        case .running:
            guard let startedAt = activity.startedAt else {
                return "Running now"
            }
            return "Started \(Self.timestamp(startedAt)) • running for \(Self.duration(from: startedAt, to: .now))"
        case .completed:
            guard let completedAt = activity.completedAt else {
                return "Finished recently"
            }
            return "Finished \(Self.timestamp(completedAt)) • \(Self.relativeTime(since: completedAt))"
        }
    }

    private var detailsText: String? {
        var parts: [String] = []
        if state == .completed, let startedAt = activity.startedAt {
            parts.append("Started \(Self.timestamp(startedAt))")
            if let completedAt = activity.completedAt {
                parts.append("ran for \(Self.duration(from: startedAt, to: completedAt))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func timestamp(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
        )
    }

    private static func relativeTime(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
    }

}

@MainActor
private final class CodexActivityTooltipManager {
    static let shared = CodexActivityTooltipManager()

    private let tooltipWidth: CGFloat = 280
    private var panel: NSPanel?
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingThreadID: String?
    private var visibleThreadID: String?

    private init() {}

    func schedule(
        for threadID: String,
        rect: CGRect,
        title: String,
        status: String,
        details: String?,
        color: Color,
        colorScheme: ColorScheme
    ) {
        pendingWorkItem?.cancel()
        pendingThreadID = threadID

        if visibleThreadID != nil {
            show(
                for: threadID,
                rect: rect,
                title: title,
                status: status,
                details: details,
                color: color,
                colorScheme: colorScheme
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingThreadID == threadID else { return }
            self.show(
                for: threadID,
                rect: rect,
                title: title,
                status: status,
                details: details,
                color: color,
                colorScheme: colorScheme
            )
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func hide(for threadID: String) {
        if pendingThreadID == threadID {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            pendingThreadID = nil
        }
        guard visibleThreadID == threadID else { return }
        panel?.orderOut(nil)
        visibleThreadID = nil
    }

    func hideAll() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingThreadID = nil
        panel?.orderOut(nil)
        visibleThreadID = nil
    }

    private func show(
        for threadID: String,
        rect: CGRect,
        title: String,
        status: String,
        details: String?,
        color: Color,
        colorScheme: ColorScheme
    ) {
        let screenFrame = CGDisplayBounds(CGMainDisplayID())
        let horizontalMargin: CGFloat = 8
        let x = min(
            max(rect.midX - tooltipWidth / 2, horizontalMargin),
            screenFrame.width - tooltipWidth - horizontalMargin
        )
        let y = ConfigManager.shared.config.experimental.foreground
            .resolveHeight() + 6

        let rootView = CodexActivityTooltipCard(
            title: title,
            status: status,
            details: details,
            color: color
        )
        .preferredColorScheme(colorScheme)
        .frame(width: tooltipWidth, alignment: .leading)
        .offset(x: x, y: y)
        .frame(
            width: screenFrame.width,
            height: screenFrame.height,
            alignment: .topLeading
        )

        let tooltipPanel = panel ?? makePanel(frame: screenFrame)
        let isAlreadyVisible = tooltipPanel.isVisible && visibleThreadID != nil
        tooltipPanel.setFrame(screenFrame, display: false)
        tooltipPanel.contentView = NSHostingView(rootView: rootView)
        if isAlreadyVisible {
            tooltipPanel.alphaValue = 1
        } else {
            tooltipPanel.alphaValue = 0
            tooltipPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                tooltipPanel.animator().alphaValue = 1
            }
        }

        panel = tooltipPanel
        visibleThreadID = threadID
        pendingThreadID = nil
        pendingWorkItem = nil
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct CodexActivityTooltipCard: View {
    let title: String
    let status: String
    let details: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
            }
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let details {
                Text(details)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}

private struct CodexActivityDotButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed ? 0.72 : (isHovered ? 1.18 : 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                .easeOut(duration: configuration.isPressed ? 0.07 : 0.14),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

struct CodexActivityWidget_Previews: PreviewProvider {
    static var previews: some View {
        CodexActivityDots(
            runningActivities: [
                CodexActivity(
                    id: "running-1",
                    title: "Improve session tracker",
                    startedAt: Date().addingTimeInterval(-3 * 60 - 18),
                    completedAt: nil,
                    consumedTokens: 22_457,
                    isUnread: false,
                    isRunning: true,
                    lastUpdatedAt: Date()
                ),
                CodexActivity(
                    id: "running-2",
                    title: "Verify widget behavior",
                    startedAt: Date().addingTimeInterval(-48),
                    completedAt: nil,
                    consumedTokens: 8_921,
                    isUnread: false,
                    isRunning: true,
                    lastUpdatedAt: Date()
                ),
            ],
            unreadActivities: [
                CodexActivity(
                    id: "unread-1",
                    title: "Fix completed task indicator",
                    startedAt: Date().addingTimeInterval(-20 * 60),
                    completedAt: Date().addingTimeInterval(-12 * 60),
                    consumedTokens: 115_417,
                    isUnread: true,
                    isRunning: false,
                    lastUpdatedAt: Date().addingTimeInterval(-12 * 60)
                ),
            ],
            diameter: 8,
            spacing: 4,
            hitTargetHeight: 38,
            runningColor: Color.primary.opacity(0.5),
            unreadColor: Color(red: 63 / 255, green: 175 / 255, blue: 114 / 255),
            readCompletedColor: Color.gray.opacity(0.45),
            onActivate: { _ in }
        )
        .frame(width: 40, height: 38)
        .background(.gray)
    }
}
