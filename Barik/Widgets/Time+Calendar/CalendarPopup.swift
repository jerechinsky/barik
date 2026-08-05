import EventKit
import SwiftUI

struct CalendarPopup: View {
    let calendarManager: CalendarManager

    @ObservedObject var configProvider: ConfigProvider
    @State private var selectedVariant: MenuBarPopupVariant = .box

    var body: some View {
        MenuBarPopupVariantView(
            selectedVariant: selectedVariant,
            onVariantSelected: { variant in
                selectedVariant = variant
                ConfigManager.shared.updateConfigValue(
                    key: "widgets.default.time.popup.view-variant",
                    newValue: variant.rawValue
                )
            },
            box: { CalendarBoxPopup() },
            vertical: { CalendarVerticalPopup(calendarManager) },
            horizontal: { CalendarHorizontalPopup(calendarManager) },
            dayView: { CalendarDayViewPopup(calendarManager: calendarManager) }
        )
        .onAppear {
            if let variantString = configProvider.config["popup"]?
                .dictionaryValue?["view-variant"]?.stringValue,
                let variant = MenuBarPopupVariant(rawValue: variantString)
            {
                selectedVariant = variant
            } else {
                selectedVariant = .box
            }
        }
        .onReceive(configProvider.$config) { newConfig in
            if let variantString = newConfig["popup"]?.dictionaryValue?[
                "view-variant"]?.stringValue,
                let variant = MenuBarPopupVariant(rawValue: variantString)
            {
                selectedVariant = variant
            }
        }
    }
}

// The agenda and event-detail interaction are adapted from
// bottlebrushes/barik-but-better (MIT), commit 23c28e8.
private struct CalendarDayViewPopup: View {
    @ObservedObject var calendarManager: CalendarManager
    @State private var selectedEvent: EKEvent?

    var body: some View {
        Group {
            if let selectedEvent {
                CalendarEventDetail(event: selectedEvent) {
                    withAnimation(.smooth(duration: 0.2)) {
                        self.selectedEvent = nil
                    }
                }
            } else {
                agenda
            }
        }
        .frame(width: 420, height: 430, alignment: .top)
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide)))
                        .font(.title2.weight(.semibold))
                    Text(Date.now.formatted(.dateTime.month(.wide).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Agenda")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    agendaSection(
                        title: "Today",
                        date: Date.now,
                        events: calendarManager.todaysEvents
                    )
                    agendaSection(
                        title: "Tomorrow",
                        date: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now,
                        events: calendarManager.tomorrowsEvents
                    )
                }
                .padding(22)
            }
        }
    }

    private func agendaSection(title: String, date: Date, events: [EKEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if events.isEmpty {
                Text("No events")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(events, id: \.eventIdentifier) { event in
                    CalendarAgendaRow(event: event) {
                        withAnimation(.smooth(duration: 0.2)) {
                            selectedEvent = event
                        }
                    }
                }
            }
        }
    }
}

private struct CalendarAgendaRow: View {
    let event: EKEvent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Capsule()
                    .fill(Color(event.calendar.cgColor))
                    .frame(width: 3, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title ?? "Untitled event")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(eventTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if event.location?.isEmpty == false {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.045))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var eventTime: String {
        if event.isAllDay { return "All day · \(event.calendar.title)" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened)) · \(event.calendar.title)"
    }
}

private struct CalendarEventDetail: View {
    let event: EKEvent
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) {
                Label("Agenda", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(event.calendar.cgColor))
                    .frame(width: 10, height: 10)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title ?? "Untitled event")
                        .font(.title2.weight(.semibold))
                    Text(event.calendar.title)
                        .font(.caption)
                        .foregroundStyle(Color(event.calendar.cgColor))
                }
            }

            detailRow(icon: "clock", text: eventTime)

            if let location = event.location, !location.isEmpty {
                detailRow(icon: "location", text: location)
            }

            if let notes = event.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Notes", systemImage: "note.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }

            Spacer()

            Button {
                let timestamp = event.startDate.timeIntervalSinceReferenceDate
                if let url = URL(string: "calshow:\(timestamp)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in Calendar", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(event.calendar.cgColor))
        }
        .padding(22)
    }

    private func detailRow(icon: String, text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private var eventTime: String {
        if event.isAllDay {
            return "All day"
        }
        return "\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

struct CalendarBoxPopup: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(currentMonthYear)
                .font(.title2)
                .padding(.bottom, 25)
            WeekdayHeaderView()
            CalendarDaysView(
                weeks: weeks,
                currentYear: currentYear,
                currentMonth: currentMonth
            )
        }
        .padding(30)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
    }
}

struct CalendarVerticalPopup: View {
    let calendarManager: CalendarManager

    init(_ calendarManager: CalendarManager) {
        self.calendarManager = calendarManager
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(currentMonthYear)
                .font(.title2)
                .padding(.bottom, 25)
            WeekdayHeaderView()
            CalendarDaysView(
                weeks: weeks,
                currentYear: currentYear,
                currentMonth: currentMonth
            )
            
            Group {
                if calendarManager.todaysEvents.isEmpty && calendarManager.tomorrowsEvents.isEmpty {
                    Text(NSLocalizedString("EMPTY_EVENTS", comment: ""))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .font(.callout)
                        .padding(.top, 3)
                }
                EventListView(
                    todaysEvents: calendarManager.todaysEvents,
                    tomorrowsEvents: calendarManager.tomorrowsEvents
                )
            }
            .frame(width: 255)
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
    }
}

struct CalendarHorizontalPopup: View {
    let calendarManager: CalendarManager

    init(_ calendarManager: CalendarManager) {
        self.calendarManager = calendarManager
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(currentMonthYear)
                    .font(.title2)
                    .padding(.bottom, 25)
                    .fixedSize(horizontal: true, vertical: false)
                WeekdayHeaderView()
                CalendarDaysView(
                    weeks: weeks,
                    currentYear: currentYear,
                    currentMonth: currentMonth
                )
            }
            
            Group {
                if calendarManager.todaysEvents.isEmpty && calendarManager.tomorrowsEvents.isEmpty {
                    Text(NSLocalizedString("EMPTY_EVENTS", comment: ""))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.callout)
                }
                EventListView(
                    todaysEvents: calendarManager.todaysEvents,
                    tomorrowsEvents: calendarManager.tomorrowsEvents
                )
            }
            .frame(width: 255)
            .padding(.leading, 30)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
    }
}

private var currentMonthYear: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "LLLL yyyy"
    return formatter.string(from: Date()).capitalized
}

private var currentMonth: Int {
    Calendar.current.component(.month, from: Date())
}

private var currentYear: Int {
    Calendar.current.component(.year, from: Date())
}

private var calendarDays: [Int?] {
    let calendar = Calendar.current
    let date = Date()
    guard
        let range = calendar.range(of: .day, in: .month, for: date),
        let firstOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        )
    else {
        return []
    }
    let startOfMonthWeekday = calendar.component(.weekday, from: firstOfMonth)
    let blanks = (startOfMonthWeekday - calendar.firstWeekday + 7) % 7
    var days: [Int?] = Array(repeating: nil, count: blanks)
    days.append(contentsOf: range.map { $0 })
    return days
}

private var weeks: [[Int?]] {
    var days = calendarDays
    let remainder = days.count % 7
    if remainder != 0 {
        days.append(contentsOf: Array(repeating: nil, count: 7 - remainder))
    }
    return stride(from: 0, to: days.count, by: 7).map {
        Array(days[$0..<min($0 + 7, days.count)])
    }
}

private struct WeekdayHeaderView: View {
    var body: some View {
        let calendar = Calendar.current
        let weekdaySymbols = calendar.shortWeekdaySymbols
        let firstWeekdayIndex = calendar.firstWeekday - 1
        let reordered = Array(
            weekdaySymbols[firstWeekdayIndex...]
                + weekdaySymbols[..<firstWeekdayIndex]
        )
        let referenceDate = DateComponents(
            calendar: calendar, year: 2020, month: 12, day: 13
        ).date!
        let referenceDays = (0..<7).map { i in
            calendar.date(byAdding: .day, value: i, to: referenceDate)!
        }

        HStack {
            ForEach(reordered.indices, id: \.self) { i in
                let originalIndex = (i + firstWeekdayIndex) % 7
                let isWeekend = calendar.isDateInWeekend(
                    referenceDays[originalIndex]
                )
                let color = isWeekend ? Color.gray : Color.primary

                Text(reordered[i])
                    .frame(width: 30)
                    .foregroundColor(color)
            }
        }
        .padding(.bottom, 10)
    }
}

private struct CalendarDaysView: View {
    let weeks: [[Int?]]
    let currentYear: Int
    let currentMonth: Int

    var body: some View {
        let calendar = Calendar.current
        VStack(spacing: 10) {
            ForEach(weeks.indices, id: \.self) { weekIndex in
                HStack(spacing: 8) {
                    ForEach(weeks[weekIndex].indices, id: \.self) { dayIndex in
                        if let day = weeks[weekIndex][dayIndex] {
                            let date = calendar.date(
                                from: DateComponents(
                                    year: currentYear,
                                    month: currentMonth,
                                    day: day
                                )
                            )!
                            let isWeekend = calendar.isDateInWeekend(date)
                            let color =
                                isToday(day: day)
                                ? Color(nsColor: .textBackgroundColor)
                                : (isWeekend ? Color.gray : Color.primary)

                            ZStack {
                                if isToday(day: day) {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 30, height: 30)
                                }
                                Text("\(day)")
                                    .foregroundColor(color)
                                    .frame(width: 30, height: 30)
                            }
                        } else {
                            Color.clear.frame(width: 30, height: 30)
                        }
                    }
                }
            }
        }.compositingGroup()
    }

    func isToday(day: Int) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: Date())
        if let dateFromDay = calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: day
            )
        ) {
            return calendar.isDateInToday(dateFromDay)
        }
        return false
    }
}

private struct EventListView: View {
    let todaysEvents: [EKEvent]
    let tomorrowsEvents: [EKEvent]

    var body: some View {
        if !todaysEvents.isEmpty || !tomorrowsEvents.isEmpty {
            VStack(spacing: 10) {
                eventSection(
                    title: NSLocalizedString("TODAY", comment: "").uppercased(),
                    events: todaysEvents)
                eventSection(
                    title: NSLocalizedString("TOMORROW", comment: "")
                        .uppercased(), events: tomorrowsEvents)
            }
        }
    }

    @ViewBuilder
    func eventSection(title: String, events: [EKEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                ForEach(events, id: \.eventIdentifier) { event in
                    EventRow(event: event)
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        let eventTime = getEventTime(event)
        HStack(spacing: 4) {
            Rectangle()
                .fill(Color(event.calendar.cgColor))
                .frame(width: 3, height: 30)
                .clipShape(Capsule())
            VStack(alignment: .leading) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(eventTime)
                    .font(.caption)
                    .fontWeight(.regular)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(5)
        .padding(.trailing, 5)
        .foregroundStyle(Color(event.calendar.cgColor))
        .background(Color(event.calendar.cgColor).opacity(0.2))
        .cornerRadius(6)
        .frame(maxWidth: .infinity)
    }

    func getEventTime(_ event: EKEvent) -> String {
        var text = ""
        if !event.isAllDay {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("j:mm")
            text += formatter.string(from: event.startDate).replacing(":00", with: "")
            text += " — "
            text += formatter.string(from: event.endDate).replacing(":00", with: "")
        } else {
            return NSLocalizedString("ALL_DAY", comment: "")
        }
        return text
    }
}

struct CalendarPopup_Previews: PreviewProvider {
    var configProvider: ConfigProvider = ConfigProvider(config: ConfigData())
    var calendarManager: CalendarManager

    init() {
        self.calendarManager = CalendarManager(configProvider: configProvider)
    }

    static var previews: some View {
        let configProvider = ConfigProvider(config: ConfigData())
        let calendarManager = CalendarManager(configProvider: configProvider)

        CalendarBoxPopup()
            .background(Color.black)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Box")
        CalendarVerticalPopup(calendarManager)
            .background(Color.black)
            .frame(height: 600)
            .previewDisplayName("Vertical")
        CalendarHorizontalPopup(calendarManager)
            .background(Color.black)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Horizontal")
    }
}
