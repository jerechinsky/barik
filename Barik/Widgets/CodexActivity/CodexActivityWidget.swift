import SwiftUI

struct CodexActivityWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var manager = CodexActivityManager.shared

    private var config: ConfigData { configProvider.config }
    private var dotDiameter: CGFloat {
        CGFloat(max(4, min(12, config["dot-diameter"]?.doubleValue ?? 7)))
    }
    private var dotSpacing: CGFloat {
        CGFloat(max(2, min(8, config["dot-spacing"]?.doubleValue ?? 4)))
    }
    private var dotColor: Color {
        if let configuredColor = config["color"]?.stringValue,
           let color = Color(hex: configuredColor) {
            return color
        }
        return Color.foregroundOutside.opacity(0.5)
    }
    private var unreadDotColor: Color {
        Color(hex: config["unread-color"]?.stringValue ?? "#3FAF72")
            ?? Color(red: 63 / 255, green: 175 / 255, blue: 114 / 255)
    }
    private var totalCount: Int {
        manager.runningCount + manager.unreadCount
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Keep a real view mounted while the widget is visually hidden.
            // An empty Group never receives onAppear, so polling never starts.
            Color.clear
                .frame(width: 0, height: dotDiameter)

            if totalCount > 0 {
                CodexActivityDots(
                    runningThreadIDs: manager.runningThreadIDs,
                    unreadThreadIDs: manager.unreadThreadIDs,
                    diameter: dotDiameter,
                    spacing: dotSpacing,
                    runningColor: dotColor,
                    unreadColor: unreadDotColor
                )
                // The tiny dots read closer to the divider than text or a ring
                // at the same layout spacing, so balance the optical gap.
                .padding(.trailing, 2)
                .help(helpText)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Codex activity")
                .accessibilityValue(helpText)
                .experimentalConfiguration(
                    horizontalPadding: 8,
                    cornerRadius: 15
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: manager.runningCount)
        .animation(.easeOut(duration: 0.18), value: manager.unreadCount)
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
        if manager.unreadCount > 0 {
            parts.append(manager.unreadCount == 1
                ? "1 completed Codex task unread"
                : "\(manager.unreadCount) completed Codex tasks unread")
        }
        return parts.joined(separator: ", ")
    }
}

private struct CodexActivityDots: View {
    let runningThreadIDs: [String]
    let unreadThreadIDs: [String]
    let diameter: CGFloat
    let spacing: CGFloat
    let runningColor: Color
    let unreadColor: Color

    var body: some View {
        HStack(spacing: spacing) {
            // Active work always leads on the left; completed unread work stays right.
            ForEach(runningThreadIDs, id: \.self) { threadID in
                dot(
                    for: threadID, color: runningColor,
                    state: "running", dismissOnOpen: false
                )
            }
            ForEach(unreadThreadIDs, id: \.self) { threadID in
                dot(
                    for: threadID, color: unreadColor,
                    state: "completed", dismissOnOpen: true
                )
            }
        }
    }

    private func dot(
        for threadID: String,
        color: Color,
        state: String,
        dismissOnOpen: Bool
    ) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .frame(width: diameter, height: 30)
            .contentShape(Rectangle())
            .background(.black.opacity(0.001))
            .onTapGesture {
                open(threadID, dismissOnOpen: dismissOnOpen)
            }
            .help("Open \(state) Codex task")
            .accessibilityLabel("Open \(state) Codex task")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                open(threadID, dismissOnOpen: dismissOnOpen)
            }
    }

    private func open(_ threadID: String, dismissOnOpen: Bool) {
        guard let url = URL(string: "codex://threads/\(threadID)") else {
            return
        }
        if NSWorkspace.shared.open(url), dismissOnOpen {
            CodexActivityManager.shared.dismissCompletedThread(threadID)
        }
    }
}

struct CodexActivityWidget_Previews: PreviewProvider {
    static var previews: some View {
        CodexActivityDots(
            runningThreadIDs: ["running-1", "running-2"],
            unreadThreadIDs: ["unread-1"],
            diameter: 7,
            spacing: 4,
            runningColor: Color.primary.opacity(0.5),
            unreadColor: Color(red: 63 / 255, green: 175 / 255, blue: 114 / 255)
        )
        .frame(width: 40, height: 38)
        .background(.gray)
    }
}
