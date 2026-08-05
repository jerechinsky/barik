import EventKit
import SwiftUI

private final class MinuteTicker: ObservableObject {
    @Published private(set) var currentTime = Date()

    private var timer: DispatchSourceTimer?
    private var formatters: [String: DateFormatter] = [:]

    init() {
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60)

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + max(0, nextMinute.timeIntervalSince(now)),
            repeating: 60,
            leeway: .milliseconds(500)
        )
        source.setEventHandler { [weak self] in
            self?.currentTime = Date()
        }
        source.resume()
        timer = source
    }

    deinit {
        timer?.cancel()
    }

    func formatted(
        _ date: Date,
        pattern: String,
        timeZoneIdentifier: String?
    ) -> String {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone.current
        let key = "\(Locale.current.identifier)|\(timeZone.identifier)|\(pattern)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.setLocalizedDateFormatFromTemplate(pattern)
            created.timeZone = timeZone
            formatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}

struct TimeWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    var config: ConfigData { configProvider.config }
    var calendarConfig: ConfigData? { config["calendar"]?.dictionaryValue }

    var format: String { config["format"]?.stringValue ?? "E d, J:mm" }
    var timeZone: String? { config["time-zone"]?.stringValue }
    var label: String? { config["label"]?.stringValue }

    var calendarFormat: String {
        calendarConfig?["format"]?.stringValue ?? "J:mm"
    }
    var calendarShowEvents: Bool {
        // Check widget-specific config first, then fall back to calendar.show-events
        if let widgetShowEvents = config["show-events"]?.boolValue {
            return widgetShowEvents
        }
        return calendarConfig?["show-events"]?.boolValue ?? true
    }
    var calendarMaxTitleLength: Int {
        calendarConfig?["max-title-length"]?.intValue ?? 30
    }

    @StateObject private var calendarManager: CalendarManager
    @StateObject private var minuteTicker = MinuteTicker()
    @State private var rect = CGRect()

    init(configProvider: ConfigProvider) {
        _calendarManager = StateObject(
            wrappedValue: CalendarManager(configProvider: configProvider))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 4) {
                if let label = label {
                    Text(label)
                        .opacity(0.6)
                }
                Text(formattedTime(pattern: format, from: minuteTicker.currentTime))
                    .fontWeight(.medium)
            }
            if let event = calendarManager.nextEvent, calendarShowEvents {
                Text(eventText(for: event))
                    .opacity(0.8)
                    .font(.subheadline)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.foregroundOutside)
        // .shadow(color: .foregroundShadowOutside, radius: 3)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        rect = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) {
                        oldState, newState in
                        rect = newState
                    }
            }
        )
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .monospacedDigit()
        .onTapGesture {
            MenuBarPopup.show(rect: rect, id: "calendar", colorScheme: colorScheme) {
                CalendarPopup(
                    calendarManager: self.calendarManager,
                    configProvider: configProvider)
            }
        }
    }

    // Format the current time.
    private func formattedTime(pattern: String, from time: Date) -> String {
        minuteTicker.formatted(
            time,
            pattern: pattern,
            timeZoneIdentifier: timeZone
        )
    }

    // Create text for the calendar event.
    private func eventText(for event: EKEvent) -> String {
        var title = event.title ?? ""
        if title.count > calendarMaxTitleLength {
            title = String(title.prefix(calendarMaxTitleLength)) + "..."
        }
        var text = title
        if !event.isAllDay {
            text += " ("
            text += formattedTime(
                pattern: calendarFormat, from: event.startDate)
            text += ")"
        }
        return text
    }
}

struct TimeWidget_Previews: PreviewProvider {
    static var previews: some View {
        let provider = ConfigProvider(config: ConfigData())

        ZStack {
            TimeWidget(configProvider: provider)
                .environmentObject(provider)
        }.frame(width: 500, height: 100)
    }
}
