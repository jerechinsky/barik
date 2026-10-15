import AppKit
import SwiftUI

struct CodexSessionTrackerPopup: View {
    @ObservedObject private var manager = CodexActivityManager.shared
    @AppStorage("codex-session-text-scale") private var textScaleValue = 1.0
    @AppStorage("codex-session-lookback") private var lookbackValue = 0
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    private let minimumTextScale = 0.8
    private let maximumTextScale = 1.5

    private var textScale: CGFloat {
        CGFloat(textScaleValue)
    }

    private var spacingScale: CGFloat {
        min(textScale, 1.3)
    }

    private var lookback: CodexSessionLookback {
        CodexSessionLookback(rawValue: lookbackValue) ?? .hours24
    }

    private var activitiesInRange: [CodexActivity] {
        let cutoff = Date().addingTimeInterval(-lookback.interval)
        return manager.recentActivities.filter {
            $0.isRunning || $0.lastUpdatedAt >= cutoff
        }
    }

    private var filteredActivities: [CodexActivity] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activitiesInRange }

        return activitiesInRange.filter { activity in
            activity.title.localizedCaseInsensitiveContains(query)
                || activity.id.localizedCaseInsensitiveContains(query)
                || activityState(for: activity)
                    .localizedCaseInsensitiveContains(query)
                || activity.consumedTokens.map {
                    CodexSessionTrackerFormat.compactInteger($0)
                        .localizedCaseInsensitiveContains(query)
                } == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Divider().background(Color.primary.opacity(0.2))

            if filteredActivities.isEmpty {
                emptyState
            } else {
                sessionList
            }

            Divider().background(Color.primary.opacity(0.2))
            footer
        }
        .frame(width: 380 + max(0, textScale - 1) * 160)
        .animation(.easeOut(duration: 0.16), value: lookbackValue)
        .onChange(of: lookbackValue) { _, _ in
            manager.setRecentActivityLookback(lookback.interval)
        }
        .onAppear {
            textScaleValue = min(
                maximumTextScale,
                max(minimumTextScale, textScaleValue)
            )
            manager.setRecentActivityLookback(lookback.interval)
            manager.refresh()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onDisappear {
            manager.setRecentActivityLookback(
                CodexSessionLookback.hours24.interval
            )
        }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5 * textScale, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search sessions", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5 * textScale, weight: .medium))
                .focused($isSearchFocused)
                .onExitCommand {
                    if !searchQuery.isEmpty {
                        searchQuery = ""
                    }
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * textScale))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear session search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28 * spacingScale)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10 * spacingScale)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image("CodexIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18 * textScale, height: 18 * textScale)

            Text("Codex Sessions")
                .font(.system(size: 14 * textScale, weight: .semibold))

            Spacer()

            HStack(spacing: 0) {
                rangeStepButton(
                    symbol: "chevron.left",
                    destination: lookback.previous,
                    direction: "Previous"
                )

                rangeControlDivider

                Text("Last \(lookback.badgeLabel)")
                    .font(.system(size: 10 * textScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 45 * spacingScale)
                    .padding(.horizontal, 5)
                    .accessibilityLabel(
                        "Session range: \(lookback.fullDescription)"
                    )

                rangeControlDivider

                rangeStepButton(
                    symbol: "chevron.right",
                    destination: lookback.next,
                    direction: "Next"
                )
            }
            .padding(.vertical, 3 * spacingScale)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13 * spacingScale)
    }

    private var rangeControlDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 12 * spacingScale)
    }

    private func rangeStepButton(
        symbol: String,
        destination: CodexSessionLookback,
        direction: String
    ) -> some View {
        Button {
            lookbackValue = destination.rawValue
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 7 * textScale, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20 * spacingScale, height: 16 * spacingScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show sessions from the \(destination.fullDescription)")
        .accessibilityLabel(
            "\(direction) session range: \(destination.fullDescription)"
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8 * spacingScale) {
            if manager.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(textScale)
            } else {
                Image(systemName: searchQuery.isEmpty
                    ? "checkmark.circle"
                    : "magnifyingglass")
                    .font(.system(size: 28 * textScale))
                    .foregroundStyle(.secondary)
            }

            Text(manager.isRefreshing
                ? "Refreshing sessions"
                : emptyStateText)
                .font(.system(size: 12 * textScale, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(28 * spacingScale)
    }

    private var sessionList: some View {
        let activities = filteredActivities

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(
                    Array(activities.enumerated()),
                    id: \.element.id
                ) { index, activity in
                    Button {
                        open(activity)
                    } label: {
                        CodexSessionTrackerRow(
                            activity: activity,
                            textScale: textScale
                        )
                    }
                    .buttonStyle(.plain)

                    if index < activities.count - 1 {
                        Divider().padding(.leading, 36 * spacingScale)
                    }
                }
            }
        }
        .frame(maxHeight: 520)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(sessionSummary)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                textSizeButton(
                    symbol: "minus",
                    help: "Decrease text size",
                    delta: -0.1,
                    disabled: textScaleValue <= minimumTextScale
                )

                Text("\(Int((textScaleValue * 100).rounded()))%")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 31)

                textSizeButton(
                    symbol: "plus",
                    help: "Increase text size",
                    delta: 0.1,
                    disabled: textScaleValue >= maximumTextScale
                )
            }

            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh sessions")
            .accessibilityLabel("Refresh sessions")
        }
        .font(.system(size: 10.5 * textScale, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10 * spacingScale)
    }

    private var sessionSummary: String {
        let activities = filteredActivities
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "\(activities.count) of \(activitiesInRange.count) sessions"
        }
        let running = activities.filter(\.isRunning).count
        let completed = activities.count - running
        if running == 0 {
            return "\(completed) completed in the \(lookback.fullDescription)"
        }
        return "\(running) running · \(completed) completed"
    }

    private var emptyStateText: String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "No sessions match \"\(query)\""
        }
        return "No sessions in the \(lookback.fullDescription)"
    }

    private func activityState(for activity: CodexActivity) -> String {
        activity.isRunning ? "running active" : "completed finished"
    }

    private func textSizeButton(
        symbol: String,
        help: String,
        delta: Double,
        disabled: Bool
    ) -> some View {
        Button {
            let stepped = ((textScaleValue + delta) * 10).rounded() / 10
            textScaleValue = min(
                maximumTextScale,
                max(minimumTextScale, stepped)
            )
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func open(_ activity: CodexActivity) {
        guard let url = URL(string: "codex://threads/\(activity.id)") else {
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
        if NSWorkspace.shared.open(url), !activity.isRunning {
            manager.dismissCompletedThread(activity.id)
        }
    }
}

private enum CodexSessionLookback: Int, CaseIterable {
    case hours24
    case days7
    case days2
    case hours16
    case hours8

    var interval: TimeInterval {
        switch self {
        case .hours24: return 24 * 60 * 60
        case .days7: return 7 * 24 * 60 * 60
        case .days2: return 2 * 24 * 60 * 60
        case .hours16: return 16 * 60 * 60
        case .hours8: return 8 * 60 * 60
        }
    }

    var badgeLabel: String {
        switch self {
        case .hours24: return "24h"
        case .days7: return "7d"
        case .days2: return "2d"
        case .hours16: return "16h"
        case .hours8: return "8h"
        }
    }

    var fullDescription: String {
        switch self {
        case .hours24: return "last 24 hours"
        case .days7: return "last 7 days"
        case .days2: return "last 2 days"
        case .hours16: return "last 16 hours"
        case .hours8: return "last 8 hours"
        }
    }

    var next: Self {
        let values = Self.allCases
        let index = values.firstIndex(of: self) ?? 0
        let nextIndex = (index + 1) % values.count
        return values[nextIndex]
    }

    var previous: Self {
        let values = Self.allCases
        let index = values.firstIndex(of: self) ?? 0
        let previousIndex = (index - 1 + values.count) % values.count
        return values[previousIndex]
    }
}

private struct CodexSessionTrackerRow: View {
    let activity: CodexActivity
    let textScale: CGFloat

    private var spacingScale: CGFloat {
        min(textScale, 1.3)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10 * spacingScale) {
            Circle()
                .fill(dotColor)
                .frame(
                    width: 9 * min(textScale, 1.2),
                    height: 9 * min(textScale, 1.2)
                )
                .padding(.top, 4 * spacingScale)

            VStack(alignment: .leading, spacing: 4 * spacingScale) {
                Text(activity.title)
                    .font(.system(size: 12 * textScale, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(statusText)
                    .font(.system(size: 10.5 * textScale, weight: .medium))
                    .foregroundStyle(activity.isRunning ? runningColor : .secondary)

                Text(tokenText)
                    .font(.system(size: 9.5 * textScale, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(
                    size: 9 * min(textScale, 1.2),
                    weight: .semibold
                ))
                .foregroundStyle(.quaternary)
                .padding(.top, 5 * spacingScale)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10 * spacingScale)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this session in Codex")
    }

    private var statusText: String {
        if activity.isRunning {
            guard let startedAt = activity.startedAt else {
                return "Running now"
            }
            return "Running for \(CodexSessionTrackerFormat.duration(Date().timeIntervalSince(startedAt)))"
        }

        var parts: [String] = []
        if let completedAt = activity.completedAt {
            parts.append(
                "Finished \(CodexSessionTrackerFormat.relativeTime(since: completedAt))"
            )
        } else {
            parts.append("Finished recently")
        }

        if let startedAt = activity.startedAt,
           let completedAt = activity.completedAt {
            parts.append(
                "ran for \(CodexSessionTrackerFormat.duration(completedAt.timeIntervalSince(startedAt)))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private var tokenText: String {
        guard let tokens = activity.consumedTokens else {
            return "Tokens unavailable"
        }
        return "\(CodexSessionTrackerFormat.compactInteger(tokens)) tokens"
    }

    private var dotColor: Color {
        if activity.isRunning {
            return runningColor
        }
        return activity.isUnread ? unreadColor : Color.secondary.opacity(0.45)
    }

    private var runningColor: Color {
        Color(hex: "#E59B3A") ?? .orange
    }

    private var unreadColor: Color {
        Color(hex: "#35E875") ?? .green
    }
}

private enum CodexSessionTrackerFormat {
    static func compactInteger(_ value: Int) -> String {
        let amount = Double(max(0, value))
        if amount >= 1_000_000 {
            return compactDecimal(amount / 1_000_000) + "M"
        }
        if amount >= 1_000 {
            return compactDecimal(amount / 1_000) + "k"
        }
        return "\(value)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }

        let minutes = seconds / 60
        if minutes < 60 {
            let remainder = seconds % 60
            return remainder == 0
                ? "\(minutes)m"
                : "\(minutes)m \(remainder)s"
        }

        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0
                ? "\(hours)h"
                : "\(hours)h \(remainder)m"
        }

        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0
            ? "\(days)d"
            : "\(days)d \(remainder)h"
    }

    static func relativeTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return relative(seconds, unit: "second") }

        let minutes = seconds / 60
        if minutes < 60 { return relative(minutes, unit: "minute") }

        let hours = minutes / 60
        if hours < 24 { return relative(hours, unit: "hour") }

        return relative(hours / 24, unit: "day")
    }

    private static func relative(_ value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }

    private static func compactDecimal(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
