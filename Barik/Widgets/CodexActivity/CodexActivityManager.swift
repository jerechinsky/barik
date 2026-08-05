import Foundation
import SwiftUI

@MainActor
final class CodexActivityManager: ObservableObject {
    static let shared = CodexActivityManager()

    @Published private(set) var runningThreadIDs: [String] = []
    @Published private(set) var unreadThreadIDs: [String] = []
    @Published private(set) var isRefreshing = false

    var runningCount: Int { runningThreadIDs.count }
    var unreadCount: Int { unreadThreadIDs.count }

    private var refreshTimer: Timer?
    private var refreshInterval: TimeInterval = 2
    private var staleAfter: TimeInterval = 30 * 60
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
            1,
            TimeInterval(config["refresh-interval-seconds"]?.intValue ?? 2)
        )
        staleAfter = max(
            60,
            TimeInterval(config["stale-after-minutes"]?.intValue ?? 30) * 60
        )
        scheduleRefreshTimer()
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let staleAfter = staleAfter
        let codexApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first
        let codexProcessID = codexApp?.processIdentifier
        let isCodexFrontmost = codexApp?.isActive == true

        Task {
            let snapshot = await scanner.snapshot(
                staleAfter: staleAfter,
                codexProcessID: codexProcessID,
                isCodexFrontmost: isCodexFrontmost
            )
            self.runningThreadIDs = snapshot.runningThreadIDs
            self.unreadThreadIDs = snapshot.unreadThreadIDs
            self.isRefreshing = false
        }
    }

    func dismissCompletedThread(_ threadID: String) {
        unreadThreadIDs.removeAll { $0 == threadID }
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
    let runningThreadIDs: [String]
    let unreadThreadIDs: [String]
}

private actor CodexActivityScanner {
    private static let dismissedThreadIDsKey =
        "codex-activity-dismissed-thread-ids"

    private enum Lifecycle {
        case started
        case stopped
    }

    private struct FileState {
        var offset: UInt64
        var pendingData = Data()
        var lifecycle: Lifecycle
        var modifiedAt: Date
        let threadID: String
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
    private var visibleThreadIDs = Set<String>()
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
        codexProcessID: pid_t?,
        isCodexFrontmost: Bool
    ) -> CodexActivitySnapshot {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let sessionsURL = homeURL
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let now = Date()
        let recentCutoff = now.addingTimeInterval(-staleAfter)

        let candidates = Self.sessionDirectories(around: now, under: sessionsURL)
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

        var currentPaths = Set<String>()
        for url in candidates where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ]),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt >= recentCutoff,
            let fileSize = values.fileSize else {
                continue
            }

            let path = url.path
            let size = UInt64(max(0, fileSize))
            currentPaths.insert(path)

            if var state = states[path], size >= state.offset {
                if size > state.offset {
                    Self.ingestAppendedData(from: url, into: &state)
                }
                state.modifiedAt = modifiedAt
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
        let runningThreadIDs = Set(states.values.filter {
            $0.lifecycle == .started && $0.modifiedAt >= recentCutoff
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
        let unreadThreadIDs = codexUnreadThreadIDs
            .subtracting(runningThreadIDs)
            .subtracting(dismissedThreadIDs)

        return CodexActivitySnapshot(
            runningThreadIDs: runningThreadIDs.sorted(),
            unreadThreadIDs: unreadThreadIDs.sorted()
        )
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
        guard let threadID = desktopRootThreadID(in: url),
              let data = tailData(of: url, maximumBytes: 4 * 1_024 * 1_024)
        else { return nil }

        // A busy active turn can push task_started beyond the tail window.
        // Completed turns always append a terminal lifecycle event at the end.
        let lifecycle = lastLifecycle(in: data)
            ?? (fileSize > 4 * 1_024 * 1_024 ? .started : .stopped)

        return FileState(
            offset: fileSize,
            lifecycle: lifecycle,
            modifiedAt: modifiedAt,
            threadID: threadID
        )
    }

    private static func ingestAppendedData(
        from url: URL,
        into state: inout FileState
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
        let remainderStart = data.index(after: newline)
        state.pendingData = Data(data[remainderStart...])
        if let lifecycle = lastLifecycle(in: completeLines) {
            state.lifecycle = lifecycle
        }
    }

    private static func sessionDirectories(
        around date: Date,
        under sessionsURL: URL
    ) -> [URL] {
        let calendar = Calendar.current
        return [date, calendar.date(byAdding: .day, value: -1, to: date)]
            .compactMap { $0 }
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

    private static func desktopRootThreadID(in url: URL) -> String? {
        guard let event = firstJSONEvent(in: url),
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
        lastUnreadThreadIDs = localUnread.intersection(visibleThreadIDs)
        return lastUnreadThreadIDs
    }

    private func refreshVisibleThreadIDs(under homeURL: URL) {
        let indexURL = homeURL.appendingPathComponent(".codex/session_index.jsonl")
        let modifiedAt = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        if modifiedAt == visibleThreadIndexModifiedAt, !visibleThreadIDs.isEmpty {
            return
        }

        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var IDs = Set<String>()
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  let threadID = entry["id"] as? String else {
                continue
            }
            IDs.insert(threadID)
        }

        visibleThreadIDs = IDs
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

    private static func lastLifecycle(in data: Data) -> Lifecycle? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var latest: Lifecycle?

        for line in text.split(separator: "\n") {
            guard line.contains("\"type\":\"event_msg\""),
                  line.contains("task_") || line.contains("turn_aborted"),
                  let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }

            switch type {
            case "task_started":
                latest = .started
            case "task_complete", "turn_aborted":
                latest = .stopped
            default:
                continue
            }
        }
        return latest
    }

    private static func firstJSONEvent(
        in url: URL
    ) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 64 * 1_024)
        let lineData = data.prefix { $0 != 0x0A }
        guard !lineData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(lineData))
                as? [String: Any] else {
            return nil
        }
        return object
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
