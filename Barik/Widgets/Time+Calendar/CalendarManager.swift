import Combine
import EventKit
import Foundation

class CalendarManager: ObservableObject {
    let configProvider: ConfigProvider
    var config: ConfigData? {
        configProvider.config["calendar"]?.dictionaryValue
    }
    var allowList: [String] {
        Array(
            (config?["allow-list"]?.arrayValue?.map { $0.stringValue ?? "" }
                .drop(while: { $0 == "" })) ?? [])
    }
    var denyList: [String] {
        Array(
            (config?["deny-list"]?.arrayValue?.map { $0.stringValue ?? "" }
                .drop(while: { $0 == "" })) ?? [])
    }

    @Published var nextEvent: EKEvent?
    @Published var nextMeeting: EKEvent?
    @Published var todaysEvents: [EKEvent] = []
    @Published var tomorrowsEvents: [EKEvent] = []
    private let eventStore = EKEventStore()
    private var debounceTimer: Timer?
    private var boundaryTimer: Timer?
    private var calendarChangeObserver: NSObjectProtocol?
    private var sleepWakeObservers: [NSObjectProtocol] = []

    init(configProvider: ConfigProvider) {
        self.configProvider = configProvider
        requestAccess()
        startMonitoring()
        observeSleepWake()
    }

    deinit {
        stopMonitoring()
        removeSleepWakeObservers()
    }

    private func observeSleepWake() {
        let sleepObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.boundaryTimer?.invalidate()
            self?.boundaryTimer = nil
        }

        let wakeObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startMonitoring()
        }

        sleepWakeObservers.append(contentsOf: [sleepObserver, wakeObserver])
    }

    private func removeSleepWakeObservers() {
        sleepWakeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sleepWakeObservers.removeAll()
    }

    private func startMonitoring() {
        if calendarChangeObserver == nil {
            calendarChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedRefresh()
            }
        }
        refreshAll()
    }

    private func refreshAll() {
        fetchTodaysEvents()
        fetchTomorrowsEvents()
        fetchNextEvent()
        fetchNextMeeting()
    }

    private func stopMonitoring() {
        debounceTimer?.invalidate()
        boundaryTimer?.invalidate()
        debounceTimer = nil
        boundaryTimer = nil
        if let calendarChangeObserver {
            NotificationCenter.default.removeObserver(calendarChangeObserver)
            self.calendarChangeObserver = nil
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
            [weak self] _ in
            self?.refreshAll()
        }
    }

    private func scheduleBoundaryRefresh() {
        boundaryTimer?.invalidate()
        let now = Date()
        let midnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 2),
            matchingPolicy: .nextTime
        )
        let candidates = [
            nextEvent?.startDate,
            nextEvent?.endDate,
            nextMeeting?.startDate,
            nextMeeting?.endDate,
            midnight,
        ].compactMap { $0 }.filter { $0 > now.addingTimeInterval(1) }

        guard let nextRefresh = candidates.min() else { return }
        let timer = Timer(fireAt: nextRefresh.addingTimeInterval(1), interval: 0, target: self,
                          selector: #selector(handleBoundaryRefresh), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    @objc private func handleBoundaryRefresh() {
        refreshAll()
    }

    private func requestAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            if granted && error == nil {
                self?.fetchTodaysEvents()
                self?.fetchTomorrowsEvents()
                self?.fetchNextEvent()
                self?.fetchNextMeeting()
            } else {
                print(
                    "Calendar access not granted: \(String(describing: error))")
            }
        }
    }

    private func filterEvents(_ events: [EKEvent]) -> [EKEvent] {
        var filtered = events
        if !allowList.isEmpty {
            filtered = filtered.filter { allowList.contains($0.calendar.title) }
        }
        if !denyList.isEmpty {
            filtered = filtered.filter { !denyList.contains($0.calendar.title) }
        }
        return filtered
    }

    private func containsMeetingURL(_ event: EKEvent) -> Bool {
        let meetingPatterns = ["zoom.us", "meet.google", "teams.microsoft", "webex", "gotomeeting"]
        let textToSearch = [event.url?.absoluteString, event.notes, event.location]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return meetingPatterns.contains { textToSearch.contains($0) }
    }

    private func isMeeting(_ event: EKEvent) -> Bool {
        let hasAttendees = (event.attendees?.count ?? 0) > 0
        let hasMeetingURL = containsMeetingURL(event)
        let hasOrganizer = event.organizer != nil && !event.organizer!.isCurrentUser

        // Consider it a meeting if:
        // - Has attendees (you invited others), OR
        // - Has a meeting URL, OR
        // - Has an organizer who isn't you (someone invited you)
        return hasAttendees || hasMeetingURL || hasOrganizer
    }

    func fetchNextEvent() {
        let calendars = eventStore.calendars(for: .event)
        let now = Date()
        let calendar = Calendar.current
        guard
            let endOfDay = calendar.date(
                bySettingHour: 23, minute: 59, second: 59, of: now)
        else {
            print("Failed to get end of day.")
            return
        }
        let predicate = eventStore.predicateForEvents(
            withStart: now, end: endOfDay, calendars: calendars)
        let events = eventStore.events(matching: predicate).sorted {
            $0.startDate < $1.startDate
        }
        let filteredEvents = filterEvents(events)
        let regularEvents = filteredEvents.filter { !$0.isAllDay }
        let next = regularEvents.first ?? filteredEvents.first
        DispatchQueue.main.async {
            self.nextEvent = next
            self.scheduleBoundaryRefresh()
        }
    }

    func fetchNextMeeting() {
        let calendars = eventStore.calendars(for: .event)
        let now = Date()
        let calendar = Calendar.current
        // Start from 30 minutes ago to catch meetings that recently started
        let startTime = calendar.date(byAdding: .minute, value: -30, to: now) ?? now
        guard
            let endOfDay = calendar.date(
                bySettingHour: 23, minute: 59, second: 59, of: now)
        else {
            print("Failed to get end of day.")
            return
        }
        let predicate = eventStore.predicateForEvents(
            withStart: startTime, end: endOfDay, calendars: calendars)
        let events = eventStore.events(matching: predicate).sorted {
            $0.startDate < $1.startDate
        }
        let filteredEvents = filterEvents(events)
        // Filter: not all-day, is a meeting, and either hasn't started or started within last 30 mins
        let meetings = filteredEvents.filter { event in
            guard !event.isAllDay && isMeeting(event) else { return false }
            // Include if: hasn't ended yet AND (hasn't started OR started recently)
            return event.endDate > now
        }
        // Get first upcoming or currently running meeting
        let next = meetings.first { $0.startDate > now } ?? meetings.first
        DispatchQueue.main.async {
            self.nextMeeting = next
            self.scheduleBoundaryRefresh()
        }
    }

    func fetchTodaysEvents() {
        let calendars = eventStore.calendars(for: .event)
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard
            let endOfDay = calendar.date(
                bySettingHour: 23, minute: 59, second: 59, of: now)
        else {
            print("Failed to get end of day.")
            return
        }
        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay, end: endOfDay, calendars: calendars)
        let events = eventStore.events(matching: predicate)
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
        let filteredEvents = filterEvents(events)
        DispatchQueue.main.async {
            self.todaysEvents = filteredEvents
        }
    }

    func fetchTomorrowsEvents() {
        let calendars = eventStore.calendars(for: .event)
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard
            let startOfTomorrow = calendar.date(
                byAdding: .day, value: 1, to: startOfToday),
            let endOfTomorrow = calendar.date(
                bySettingHour: 23, minute: 59, second: 59, of: startOfTomorrow)
        else {
            print("Failed to get tomorrow's date range.")
            return
        }
        let predicate = eventStore.predicateForEvents(
            withStart: startOfTomorrow, end: endOfTomorrow, calendars: calendars
        )
        let events = eventStore.events(matching: predicate).sorted {
            $0.startDate < $1.startDate
        }
        let filteredEvents = filterEvents(events)
        DispatchQueue.main.async {
            self.tomorrowsEvents = filteredEvents
        }
    }
}
