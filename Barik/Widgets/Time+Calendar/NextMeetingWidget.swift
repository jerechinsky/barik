import EventKit
import SwiftUI

struct NextMeetingWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    var config: ConfigData { configProvider.config }
    var calendarConfig: ConfigData? { config["calendar"]?.dictionaryValue }

    var maxTitleLength: Int {
        // Use raw TOML table (bypasses Decodable chain; integers arrive as Int64).
        let raw = ConfigManager.shared.rawWidgetConfig(for: "default.nextmeeting")
        if let len = raw["max-title-length"] as? Int64 { return Int(len) }
        if let len = raw["max-title-length"] as? Int { return len }
        // Fallback: resolved config from environment
        if let len = config["max-title-length"]?.intValue { return len }
        return 50
    }

    var onlyMeetings: Bool {
        config["only-meetings"]?.boolValue ?? true
    }

    var timeFormat: String {
        calendarConfig?["format"]?.stringValue ?? "J:mm"
    }

    @StateObject private var calendarManager: CalendarManager

    init(configProvider: ConfigProvider) {
        _calendarManager = StateObject(
            wrappedValue: CalendarManager(configProvider: configProvider))
    }

    private var filteredMeeting: EKEvent? {
        let meeting: EKEvent?
        if onlyMeetings {
            // Only show events with attendees or meeting links
            meeting = calendarManager.nextMeeting
        } else {
            // Show any upcoming event
            meeting = calendarManager.nextEvent
        }

        // Hide meeting if it started more than 5 minutes ago
        if let meeting = meeting {
            let minutesSinceStart = Date().timeIntervalSince(meeting.startDate) / 60
            if minutesSinceStart > 5 {
                return nil
            }
        }

        return meeting
    }

    var body: some View {
        if let meeting = filteredMeeting {
            HStack(spacing: 4) {
                Text(truncatedTitle(meeting.title ?? "Meeting"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .opacity(0.6)
                Text(timeUntil(meeting.startDate))
            }
            .opacity(0.8)
            .font(.subheadline)
            .foregroundStyle(.foregroundOutside)
            .shadow(color: .foregroundShadowOutside, radius: 3)
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.001))
        }
    }

    private func truncatedTitle(_ title: String) -> String {
        if title.count <= maxTitleLength {
            return title
        }
        let endIndex = title.index(title.startIndex, offsetBy: maxTitleLength)
        return String(title[..<endIndex]) + "..."
    }

    private func timeUntil(_ date: Date) -> String {
        let now = Date()
        let interval = date.timeIntervalSince(now)

        // Meeting has started - show "started Xm ago"
        if interval <= 0 {
            let minutesAgo = Int(-interval / 60)
            if minutesAgo == 0 {
                return "now"
            }
            return "started \(minutesAgo)m ago"
        }

        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        // Last minute - show "now" instead of "in 0 min"
        if minutes == 0 {
            return "now"
        }

        if hours > 0 {
            if remainingMinutes > 0 {
                return "in \(hours)h \(remainingMinutes)m"
            }
            return "in \(hours)h"
        }

        return "in \(minutes) min"
    }
}

struct NextMeetingWidget_Previews: PreviewProvider {
    static var previews: some View {
        let provider = ConfigProvider(config: ConfigData())

        ZStack {
            NextMeetingWidget(configProvider: provider)
                .environmentObject(provider)
        }.frame(width: 500, height: 100)
    }
}
