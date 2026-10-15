import EventKit
import SwiftUI

private final class MinuteTicker: ObservableObject {
    @Published private(set) var currentTime = Date()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var formatters: [String: DateFormatter] = [:]

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let notificationCenter = NotificationCenter.default
        let refreshNotifications: [Notification.Name] = [
            SleepWakeManager.didWakeNotification,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged,
        ]
        observers = refreshNotifications.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refresh() {
        currentTime = Date()
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
    @ObservedObject private var displayManager = DisplayManager.shared
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
        let configured = max(1, calendarConfig?["max-title-length"]?.intValue ?? 30)
        return displayManager.isBuiltinDisplay ? min(8, configured) : min(24, configured)
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
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fontWeight(.medium)
            if let event = calendarManager.nextEvent, calendarShowEvents {
                Text(eventText(for: event))
                    .opacity(0.8)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: min(displayManager.isBuiltinDisplay ? 100 : 160,
                        ceil((eventText(for: event) as NSString).size(withAttributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                        ]).width)), alignment: .trailing)
                    .help(event.title ?? "")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
            title = String(title.prefix(calendarMaxTitleLength)) + "…"
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
