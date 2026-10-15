import AppKit
import Foundation
import SwiftUI
import SQLite3

@MainActor
final class CodexActivityManager: ObservableObject {
    static let shared = CodexActivityManager()

    @Published private(set) var runningActivities: [CodexActivity] = []
    @Published private(set) var unreadActivities: [CodexActivity] = []
    @Published private(set) var recentActivities: [CodexActivity] = []
    @Published private(set) var isRefreshing = false

    var runningCount: Int { runningActivities.count }
    var unreadCount: Int { unreadActivities.count }
    var keepsReadCompletedVisible: Bool { showReadCompleted }

    private var refreshTimer: Timer?
    private var refreshInterval: TimeInterval = 2
    private var staleAfter: TimeInterval = 8 * 60 * 60
    private var showReadCompleted = false
    private var recentActivityLookback: TimeInterval = 24 * 60 * 60
    private var queuedLookbackRefresh = false
    private let scanner = CodexActivityScanner()

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func startUpdating(config: ConfigData) {
        refreshInterval = max(
            5,
            TimeInterval(config["refresh-interval-seconds"]?.intValue ?? 2)
        )
        staleAfter = max(
            60,
            TimeInterval(config["stale-after-minutes"]?.intValue ?? 480) * 60
        )
        showReadCompleted = config["show-read-completed"]?.boolValue ?? false
        scheduleRefreshTimer()
        refresh()
    }

    func refresh() {
        let codexApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first
        let codexProcessID = codexApp?.processIdentifier
        guard !isRefreshing else { return }
        isRefreshing = true
        let staleAfter = staleAfter
        let showReadCompleted = showReadCompleted
        let recentActivityLookback = recentActivityLookback
        let isCodexFrontmost = codexApp?.isActive == true

        Task {
            let snapshot = await scanner.snapshot(
                staleAfter: staleAfter,
                showReadCompleted: showReadCompleted,
                recentActivityLookback: recentActivityLookback,
                codexProcessID: codexProcessID,
                isCodexFrontmost: isCodexFrontmost
            )
            if self.runningActivities != snapshot.runningActivities {
                self.runningActivities = snapshot.runningActivities
            }
            if self.unreadActivities != snapshot.unreadActivities {
                self.unreadActivities = snapshot.unreadActivities
            }
            if self.recentActivities != snapshot.recentActivities {
                self.recentActivities = snapshot.recentActivities
            }
            self.isRefreshing = false
            if self.queuedLookbackRefresh {
                self.queuedLookbackRefresh = false
                self.refresh()
            }
        }
    }

    func setRecentActivityLookback(_ interval: TimeInterval) {
        let bounded = min(7 * 24 * 60 * 60, max(8 * 60 * 60, interval))
        guard abs(bounded - recentActivityLookback) > 1 else { return }
        recentActivityLookback = bounded
        if isRefreshing {
            queuedLookbackRefresh = true
        } else {
            refresh()
        }
    }

    func dismissCompletedThread(_ threadID: String) {
        recentActivities = recentActivities.map { activity in
            guard activity.id == threadID, activity.isUnread else {
                return activity
            }
            return CodexActivity(
                id: activity.id,
                title: activity.title,
                startedAt: activity.startedAt,
                completedAt: activity.completedAt,
                consumedTokens: activity.consumedTokens,
                isUnread: false,
                isRunning: activity.isRunning,
                lastUpdatedAt: activity.lastUpdatedAt
            )
        }
        if showReadCompleted {
            unreadActivities = unreadActivities.map { activity in
                guard activity.id == threadID, activity.isUnread else {
                    return activity
                }
                return CodexActivity(
                    id: activity.id,
                    title: activity.title,
                    startedAt: activity.startedAt,
                    completedAt: activity.completedAt,
                    consumedTokens: activity.consumedTokens,
                    isUnread: false,
                    isRunning: activity.isRunning,
                    lastUpdatedAt: activity.lastUpdatedAt
                )
            }
        } else {
            unreadActivities.removeAll { $0.id == threadID }
        }
        Task {
            await scanner.dismissCompletedThread(threadID)
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = min(0.25, refreshInterval / 8)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

private struct CodexActivitySnapshot {
    let runningActivities: [CodexActivity]
    let unreadActivities: [CodexActivity]
    let recentActivities: [CodexActivity]
}

private actor CodexActivityScanner {
    private static let dismissedThreadIDsKey =
        "codex-activity-dismissed-thread-ids"
    // Keep lifecycle detection identical to the Raycast session manager.
    // A bounded tail avoids rereading very large active session logs.
    private static let maximumLifecycleTailBytes: UInt64 = 512 * 1_024
    private static let maximumTrackerLookback: TimeInterval =
        7 * 24 * 60 * 60

    private enum Lifecycle {
        case started
        case stopped
    }

    private struct FileState {
        var offset: UInt64
        var pendingData = Data()
        var lifecycle: Lifecycle
        var startedAt: Date?
        var completedAt: Date?
        var consumedTokens: Int?
        var fallbackTitle: String?
        var modifiedAt: Date
        let threadID: String
    }

    private struct ActivityUpdate {
        var lifecycle: Lifecycle?
        var startedAt: Date?
        var completedAt: Date?
        var consumedTokens: Int?
        var fallbackTitle: String?
    }

    private struct ThreadMetadata {
        let title: String
        let updatedAt: Date?
    }

    private struct ActivityLogState {
        var offset: UInt64
        var pendingData = Data()
    }

    private var states: [String: FileState] = [:]
    private var activityLogStates: [String: ActivityLogState] = [:]
    private var activeThreadIDs = Set<String>()
    private var activityLogProcessID: pid_t?
    private var lastUnreadThreadIDs = Set<String>()
    private var visibleThreads: [String: ThreadMetadata] = [:]
    private var visibleThreadIndexModifiedAt: Date?
    private var dismissedThreadIDs: Set<String>

    init() {
        dismissedThreadIDs = Set(
            UserDefaults.standard.stringArray(
                forKey: Self.dismissedThreadIDsKey
            ) ?? []
        )
#if DEBUG
        let sample = Self.activityChange(
            in: "thread_stream_view_activity_changed active=true "
                + "conversationId=01900000-0000-7000-8000-000000000001"
        )
        assert(
            sample?.threadID == "01900000-0000-7000-8000-000000000001"
                && sample?.isActive == true
        )
#endif
    }

    func dismissCompletedThread(_ threadID: String) {
        dismissedThreadIDs.insert(threadID)
        saveDismissedThreadIDs()
    }

    func snapshot(
        staleAfter: TimeInterval,
        showReadCompleted: Bool,
        recentActivityLookback: TimeInterval,
        codexProcessID: pid_t?,
        isCodexFrontmost: Bool
    ) -> CodexActivitySnapshot {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let sessionsURL = homeURL
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let now = Date()
        let recentCutoff = Self.recentCutoff(
            now: now,
            ordinaryLookback: staleAfter
        )
        let trackerLookback = min(
            Self.maximumTrackerLookback,
            max(24 * 60 * 60, recentActivityLookback)
        )
        let trackerCutoff = now.addingTimeInterval(-trackerLookback)
        let lookbackDays = max(
            1,
            Int(ceil(trackerLookback / (24 * 60 * 60)))
        )

        let directoryCandidates = Self.sessionDirectories(
            around: now,
            under: sessionsURL,
            lookbackDays: lookbackDays
        )
            .flatMap { directory in
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isRegularFileKey,
                    ],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
        let databaseCandidates = Self.recentRolloutURLsFromThreadDatabase(
            under: homeURL,
            updatedAfter: trackerCutoff
        )
        let candidates = Array(Set(directoryCandidates + databaseCandidates))

        var currentPaths = Set<String>()
        for url in candidates where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ]),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt >= trackerCutoff,
            let fileSize = values.fileSize else {
                continue
            }

            let path = url.path
            let size = UInt64(max(0, fileSize))
            currentPaths.insert(path)

            if var state = states[path], size >= state.offset {
                if size > state.offset || modifiedAt != state.modifiedAt {
                    Self.refreshStateFromLifecycleTail(
                        from: url,
                        fileSize: size,
                        modifiedAt: modifiedAt,
                        state: &state
                    )
                }
                states[path] = state
            } else if let state = Self.initialState(
                for: url,
                fileSize: size,
                modifiedAt: modifiedAt
            ) {
                states[path] = state
            }
        }

        states = states.filter { currentPaths.contains($0.key) }
        let trackerStates = states.values.filter {
            $0.modifiedAt >= trackerCutoff
        }
        let recentStates = trackerStates.filter {
            $0.modifiedAt >= recentCutoff
        }
        let runningThreadIDs = Set(recentStates.filter {
            $0.lifecycle == .started
        }.map(\.threadID))
        let codexUnreadThreadIDs = loadUnreadThreadIDs(under: homeURL)
        let openedThreadIDs = loadOpenedThreadIDs(
            under: homeURL,
            processID: codexProcessID,
            includeActiveThreads: isCodexFrontmost
        )
        let previousDismissedThreadIDs = dismissedThreadIDs
        dismissedThreadIDs.subtract(runningThreadIDs)
        dismissedThreadIDs.formIntersection(codexUnreadThreadIDs)
        dismissedThreadIDs.formUnion(
            openedThreadIDs.intersection(codexUnreadThreadIDs)
        )
        if dismissedThreadIDs != previousDismissedThreadIDs {
            saveDismissedThreadIDs()
        }
        var latestStateByThreadID: [String: FileState] = [:]
        for state in trackerStates {
            if let current = latestStateByThreadID[state.threadID],
               current.modifiedAt >= state.modifiedAt {
                continue
            }
            latestStateByThreadID[state.threadID] = state
        }

        let unreadThreadIDs = codexUnreadThreadIDs
            .subtracting(runningThreadIDs)
            .subtracting(dismissedThreadIDs)
        let recentCompletedThreadIDs = Set(recentStates.filter {
            $0.lifecycle == .stopped
        }.map(\.threadID))
            .intersection(Set(visibleThreads.keys))
            .subtracting(runningThreadIDs)
        let completedThreadIDs = showReadCompleted
            ? recentCompletedThreadIDs
            : unreadThreadIDs

        let runningActivities = runningThreadIDs.map { threadID in
            let state = latestStateByThreadID[threadID]
            return CodexActivity(
                id: threadID,
                title: title(
                    for: threadID,
                    fallbackTitle: state?.fallbackTitle
                ),
                startedAt: state?.startedAt,
                completedAt: nil,
                consumedTokens: state?.consumedTokens,
                isUnread: false,
                isRunning: true,
                lastUpdatedAt: state?.modifiedAt ?? now
            )
        }.sorted { left, right in
            let leftDate = latestStateByThreadID[left.id]?.modifiedAt
                ?? .distantPast
            let rightDate = latestStateByThreadID[right.id]?.modifiedAt
                ?? .distantPast
            return leftDate > rightDate
        }

        let unreadActivities = completedThreadIDs.map { threadID in
            let state = latestStateByThreadID[threadID]
            return CodexActivity(
                id: threadID,
                title: title(
                    for: threadID,
                    fallbackTitle: state?.fallbackTitle
                ),
                startedAt: state?.startedAt,
                completedAt: state?.completedAt
                    ?? visibleThreads[threadID]?.updatedAt,
                consumedTokens: state?.consumedTokens,
                isUnread: unreadThreadIDs.contains(threadID),
                isRunning: false,
                lastUpdatedAt: state?.modifiedAt ?? now
            )
        }.sorted {
            // Oldest to newest keeps a newly completed task beside the running
            // group instead of making it jump to the far left.
            ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
        }

        let recentActivities = latestStateByThreadID.values
            .filter {
                $0.lifecycle == .started
                    || visibleThreads[$0.threadID] != nil
            }
            .map { state in
                CodexActivity(
                    id: state.threadID,
                    title: title(
                        for: state.threadID,
                        fallbackTitle: state.fallbackTitle
                    ),
                    startedAt: state.startedAt,
                    completedAt: state.completedAt
                        ?? (state.lifecycle == .stopped
                            ? visibleThreads[state.threadID]?.updatedAt
                            : nil),
                    consumedTokens: state.consumedTokens,
                    isUnread: state.lifecycle == .stopped
                        && codexUnreadThreadIDs.contains(state.threadID),
                    isRunning: state.lifecycle == .started,
                    lastUpdatedAt: state.modifiedAt
                )
            }
            .sorted { left, right in
                if left.isRunning != right.isRunning {
                    return left.isRunning
                }
                return left.lastUpdatedAt > right.lastUpdatedAt
            }

        return CodexActivitySnapshot(
            runningActivities: runningActivities,
            unreadActivities: unreadActivities,
            recentActivities: recentActivities
        )
    }

    private func title(
        for threadID: String,
        fallbackTitle: String? = nil
    ) -> String {
        let indexedTitle = visibleThreads[threadID]?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let indexedTitle, !indexedTitle.isEmpty {
            return indexedTitle
        }
        if let fallbackTitle = fallbackTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallbackTitle.isEmpty {
            return fallbackTitle
        }
        return "Untitled Codex task"
    }

    private func saveDismissedThreadIDs() {
        UserDefaults.standard.set(
            dismissedThreadIDs.sorted(),
            forKey: Self.dismissedThreadIDsKey
        )
    }

    private static func initialState(
        for url: URL,
        fileSize: UInt64,
        modifiedAt: Date
    ) -> FileState? {
        guard let headData = headData(of: url, maximumBytes: 256 * 1_024),
              let threadID = desktopRootThreadID(in: headData),
              let data = tailData(
                of: url,
                maximumBytes: maximumLifecycleTailBytes
              )
        else { return nil }

        // A busy active turn can push task_started beyond the tail window.
        // Completed turns always append a terminal lifecycle event at the end.
        let update = lastActivityUpdate(in: data)
        let lifecycle = update.lifecycle
            ?? (fileSize > maximumLifecycleTailBytes ? .started : .stopped)

        return FileState(
            offset: fileSize,
            lifecycle: lifecycle,
            startedAt: update.startedAt,
            completedAt: update.completedAt,
            consumedTokens: update.consumedTokens,
            fallbackTitle: firstUserRequestTitle(in: headData)
                ?? update.fallbackTitle,
            modifiedAt: modifiedAt,
            threadID: threadID
        )
    }

    private static func refreshStateFromLifecycleTail(
        from url: URL,
        fileSize: UInt64,
        modifiedAt: Date,
        state: inout FileState
    ) {
        guard let data = tailData(
            of: url,
            maximumBytes: maximumLifecycleTailBytes
        ) else { return }

        let update = lastActivityUpdate(in: data)
        let lifecycle = update.lifecycle
            ?? (fileSize > maximumLifecycleTailBytes ? .started : nil)
        if let lifecycle {
            state.lifecycle = lifecycle
            switch lifecycle {
            case .started:
                state.startedAt = update.startedAt ?? state.startedAt
                state.completedAt = nil
            case .stopped:
                state.startedAt = update.startedAt ?? state.startedAt
                state.completedAt = update.completedAt ?? state.completedAt
            }
        }
        if let consumedTokens = update.consumedTokens {
            state.consumedTokens = consumedTokens
        }
        if state.fallbackTitle == nil,
           let fallbackTitle = update.fallbackTitle {
            state.fallbackTitle = fallbackTitle
        }
        state.offset = fileSize
        state.pendingData.removeAll(keepingCapacity: false)
        state.modifiedAt = modifiedAt
    }

    private static func sessionDirectories(
        around date: Date,
        under sessionsURL: URL,
        lookbackDays: Int = 1
    ) -> [URL] {
        let calendar = Calendar.current
        return (0...max(0, lookbackDays))
            .compactMap {
                calendar.date(byAdding: .day, value: -$0, to: date)
            }
            .map { candidate in
                let parts = calendar.dateComponents(
                    [.year, .month, .day],
                    from: candidate
                )
                return sessionsURL
                    .appendingPathComponent(
                        String(format: "%04d", parts.year ?? 0),
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        String(format: "%02d", parts.month ?? 0),
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        String(format: "%02d", parts.day ?? 0),
                        isDirectory: true
                    )
            }
    }

    private static func recentRolloutURLsFromThreadDatabase(
        under homeURL: URL,
        updatedAfter: Date
    ) -> [URL] {
        let databaseURL = homeURL
            .appendingPathComponent(".codex/state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil {
                sqlite3_close(database)
            }
            return []
        }
        defer { sqlite3_close(database) }

        let query = """
            SELECT rollout_path
            FROM threads
            WHERE COALESCE(updated_at_ms, updated_at * 1000) >= ?
              AND rollout_path IS NOT NULL
              AND rollout_path != ''
            ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
            LIMIT 512
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let cutoffMilliseconds = Int64(
            updatedAfter.timeIntervalSince1970 * 1_000
        )
        sqlite3_bind_int64(statement, 1, cutoffMilliseconds)

        var urls: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathCString = sqlite3_column_text(statement, 0) else {
                continue
            }
            urls.append(URL(fileURLWithPath: String(cString: pathCString)))
        }
        return urls
    }

    private static func recentCutoff(
        now: Date,
        ordinaryLookback: TimeInterval,
        calendar: Calendar = .current
    ) -> Date {
        let ordinaryCutoff = now.addingTimeInterval(-ordinaryLookback)
        guard calendar.component(.hour, from: now) < 10,
              let startOfToday = calendar.dateInterval(of: .day, for: now)?.start,
              let previousDay = calendar.date(
                byAdding: .day,
                value: -1,
                to: startOfToday
              ),
              let previousEvening = calendar.date(
                bySettingHour: 17,
                minute: 0,
                second: 0,
                of: previousDay
              ) else {
            return ordinaryCutoff
        }

        return min(ordinaryCutoff, previousEvening)
    }

    private static func desktopRootThreadID(in data: Data) -> String? {
        guard let event = firstJSONEvent(in: data),
              event["type"] as? String == "session_meta",
              let payload = event["payload"] as? [String: Any],
              let source = payload["source"] as? String,
              let threadID = payload["id"] as? String else {
            return nil
        }

        // Sub-agents use an object-valued source and are deliberately excluded:
        // the number represents user-visible Codex Desktop tasks, not workers.
        let originator = payload["originator"] as? String
        return originator == "Codex Desktop" || source == "vscode"
            ? threadID
            : nil
    }

    private func loadUnreadThreadIDs(under homeURL: URL) -> Set<String> {
        refreshVisibleThreadIDs(under: homeURL)

        let stateURL = homeURL
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let atomState = root["electron-persisted-atom-state"]
                as? [String: Any] else {
            return lastUnreadThreadIDs
        }

        let unreadByHost = atomState["unread-thread-ids-by-host-v1"]
            as? [String: Any]
        let localUnread = Set(unreadByHost?["local"] as? [String] ?? [])

        // Codex can leave internal sub-agent IDs in the unread atom. The
        // session index contains only user-visible tasks, so intersecting the
        // two avoids permanent dots for chats the user cannot open or read.
        lastUnreadThreadIDs = localUnread.intersection(Set(visibleThreads.keys))
        return lastUnreadThreadIDs
    }

    private func refreshVisibleThreadIDs(under homeURL: URL) {
        let indexURL = homeURL.appendingPathComponent(".codex/session_index.jsonl")
        let modifiedAt = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        if modifiedAt == visibleThreadIndexModifiedAt, !visibleThreads.isEmpty {
            return
        }

        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var threads: [String: ThreadMetadata] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  let threadID = entry["id"] as? String else {
                continue
            }
            let title = entry["thread_name"] as? String
                ?? "Untitled Codex task"
            let updatedAt = (entry["updated_at"] as? String)
                .flatMap(Self.iso8601Date)
            threads[threadID] = ThreadMetadata(
                title: title,
                updatedAt: updatedAt
            )
        }

        visibleThreads = threads
        visibleThreadIndexModifiedAt = modifiedAt
    }

    private func loadOpenedThreadIDs(
        under homeURL: URL,
        processID: pid_t?,
        includeActiveThreads: Bool
    ) -> Set<String> {
        guard let processID else {
            activityLogStates.removeAll()
            activeThreadIDs.removeAll()
            activityLogProcessID = nil
            return []
        }

        let isInitialScan = activityLogProcessID != processID
        if isInitialScan {
            activityLogStates.removeAll()
            activeThreadIDs.removeAll()
            activityLogProcessID = processID
        }

        let logsURL = homeURL.appendingPathComponent(
            "Library/Logs/com.openai.codex",
            isDirectory: true
        )
        let fileManager = FileManager.default
        let directories = Self.sessionDirectories(
            around: Date(),
            under: logsURL
        )
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
        ]
        var candidates: [URL] = []
        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )) ?? []
            candidates.append(contentsOf: files.filter {
                $0.pathExtension == "log"
                    && $0.lastPathComponent.contains("-\(processID)-t0-")
            })
        }
        candidates.sort { $0.path < $1.path }

        var openedThreadIDs = Set<String>()
        var currentPaths = Set<String>()
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
            values.isRegularFile == true,
            let fileSize = values.fileSize else {
                continue
            }

            let path = url.path
            let size = UInt64(max(0, fileSize))
            currentPaths.insert(path)
            var state = activityLogStates[path] ?? ActivityLogState(offset: 0)
            if size < state.offset {
                state = ActivityLogState(offset: 0)
            }
            Self.ingestActivityLog(
                from: url,
                into: &state,
                activeThreadIDs: &activeThreadIDs,
                openedThreadIDs: &openedThreadIDs,
                recordOpenEvents: !isInitialScan
            )
            activityLogStates[path] = state
        }
        activityLogStates = activityLogStates.filter {
            currentPaths.contains($0.key)
        }

        return includeActiveThreads
            ? openedThreadIDs.union(activeThreadIDs)
            : openedThreadIDs
    }

    private static func ingestActivityLog(
        from url: URL,
        into state: inout ActivityLogState,
        activeThreadIDs: inout Set<String>,
        openedThreadIDs: inout Set<String>,
        recordOpenEvents: Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: state.offset)
        let appended = handle.readDataToEndOfFile()
        state.offset += UInt64(appended.count)

        var data = state.pendingData
        data.append(appended)
        guard let newline = data.lastIndex(of: 0x0A) else {
            state.pendingData = data
            return
        }

        let completeLines = Data(data[...newline])
        state.pendingData = Data(data[data.index(after: newline)...])
        guard let text = String(data: completeLines, encoding: .utf8) else {
            return
        }

        for line in text.split(separator: "\n") {
            guard let change = activityChange(in: line) else { continue }
            if change.isActive {
                activeThreadIDs.insert(change.threadID)
                if recordOpenEvents {
                    openedThreadIDs.insert(change.threadID)
                }
            } else {
                activeThreadIDs.remove(change.threadID)
            }
        }
    }

    private static func activityChange(
        in line: some StringProtocol
    ) -> (threadID: String, isActive: Bool)? {
        guard line.contains("thread_stream_view_activity_changed"),
              let activeToken = line.split(separator: " ").first(where: {
                  $0.hasPrefix("active=")
              }),
              let threadToken = line.split(separator: " ").first(where: {
                  $0.hasPrefix("conversationId=")
              }) else {
            return nil
        }

        let threadID = threadToken.dropFirst("conversationId=".count)
        guard !threadID.isEmpty else { return nil }
        return (
            String(threadID),
            activeToken == "active=true"
        )
    }

    private static func lastActivityUpdate(in data: Data) -> ActivityUpdate {
        guard let text = String(data: data, encoding: .utf8) else {
            return ActivityUpdate()
        }
        var update = ActivityUpdate()

        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else {
                continue
            }

            let type = payload["type"] as? String
            switch type {
            case "task_started":
                update.lifecycle = .started
                update.startedAt = eventDate(payload["started_at"])
                    ?? eventDate(event["timestamp"])
                update.completedAt = nil
            case "task_complete", "task_cancelled", "turn_aborted":
                update.lifecycle = .stopped
                update.completedAt = eventDate(payload["completed_at"])
                    ?? eventDate(event["timestamp"])
            default:
                break
            }

            if type == "token_count",
               let consumedTokens = consumedTokenCount(from: payload) {
                update.consumedTokens = consumedTokens
            }
            if update.fallbackTitle == nil {
                update.fallbackTitle = userRequestTitle(from: event)
            }
        }
        return update
    }

    private static func firstUserRequestTitle(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  let title = userRequestTitle(from: event) else {
                continue
            }
            return title
        }
        return nil
    }

    private static func userRequestTitle(
        from event: [String: Any]
    ) -> String? {
        guard event["type"] as? String == "response_item",
              let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }

        for item in content where item["type"] as? String == "input_text" {
            guard var text = item["text"] as? String else { continue }
            if let marker = text.range(of: "## My request:") {
                text = String(text[marker.upperBound...])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ignoredPrefixes = [
                "# AGENTS.md instructions",
                "# Files mentioned by the user:",
                "<app-context>",
                "<environment_context>",
                "<permissions instructions>",
                "<skills_instructions>",
            ]
            guard !trimmed.isEmpty,
                  !ignoredPrefixes.contains(where: {
                      trimmed.hasPrefix($0)
                  }) else {
                continue
            }

            let normalized = trimmed
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !normalized.isEmpty else { continue }
            let maximumLength = 110
            if normalized.count <= maximumLength {
                return normalized
            }
            return String(normalized.prefix(maximumLength)) + "…"
        }
        return nil
    }

    private static func consumedTokenCount(from dictionary: [String: Any]) -> Int? {
        if let usage = dictionary["total_token_usage"] as? [String: Any],
           let value = netTokenCount(from: usage) {
            return value
        }
        if let usage = dictionary["usage"] as? [String: Any],
           let value = netTokenCount(from: usage) {
            return value
        }
        if let info = dictionary["info"] as? [String: Any],
           let value = consumedTokenCount(from: info) {
            return value
        }
        return netTokenCount(from: dictionary)
    }

    private static func netTokenCount(from dictionary: [String: Any]) -> Int? {
        guard let total = (dictionary["total_tokens"] as? NSNumber)?.doubleValue
        else { return nil }
        let cached = (dictionary["cached_input_tokens"] as? NSNumber)?.doubleValue
            ?? 0
        return Int(max(0, total - cached).rounded())
    }

    private static func eventDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let timestamp = number.doubleValue
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000
                ? timestamp / 1_000
                : timestamp)
        }
        guard let string = value as? String else { return nil }
        if let timestamp = Double(string) {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000
                ? timestamp / 1_000
                : timestamp)
        }
        return iso8601Date(string)
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func firstJSONEvent(
        in data: Data
    ) -> [String: Any]? {
        let lineData = data.prefix { $0 != 0x0A }
        guard !lineData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(lineData))
                as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func headData(
        of url: URL,
        maximumBytes: Int
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { handle.closeFile() }
        return handle.readData(ofLength: maximumBytes)
    }

    private static func tailData(
        of url: URL,
        maximumBytes: UInt64
    ) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { handle.closeFile() }

        let size = UInt64(max(0, fileSize))
        let offset = size > maximumBytes ? size - maximumBytes : 0
        handle.seek(toFileOffset: offset)
        var data = handle.readDataToEndOfFile()

        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...newline)
        }
        return data
    }
}
