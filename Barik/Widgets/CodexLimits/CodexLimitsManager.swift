import Darwin
import Foundation
import SwiftUI

// Local-session loading and canonical snapshot selection are adapted from
// bottlebrushes/barik-but-better (MIT), commit 06b6bbff759eecfd0d38853746a43e666a5a779b.

struct CodexLimitWindow: Equatable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var remainingFraction: Double {
        Double(remainingPercent) / 100
    }
}

struct CodexLimitsSnapshot: Equatable {
    let fiveHour: CodexLimitWindow?
    let weekly: CodexLimitWindow?
    let plan: String
    let updatedAt: Date
}

private struct CodexSessionEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let limitID: String?
        let primary: Bucket?
        let secondary: Bucket?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary, secondary
            case planType = "plan_type"
        }
    }

    struct Bucket: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }
}

private struct LoadedCodexLimits {
    let snapshot: CodexLimitsSnapshot?
    let isAuthenticated: Bool
    let message: String?
    let watchPaths: [String]
}

private struct CodexUsageSnapshot {
    let primary: CodexSessionEvent.Bucket?
    let secondary: CodexSessionEvent.Bucket?
    let plan: String?
    let timestamp: Date
}

@MainActor
final class CodexLimitsManager: ObservableObject {
    static let shared = CodexLimitsManager()

    @Published private(set) var snapshot: CodexLimitsSnapshot?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private var refreshTimer: Timer?
    private var fileWatchSources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths = Set<String>()
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var refreshInterval: TimeInterval = 60
    private var planOverride: String?
    private var transientZeroSnapshotStartedAt: Date?

    // Codex can briefly answer 0/0 while it swaps from a newly-created local
    // session to the server-backed rate-limit state. Keep the last good value
    // through that handoff, but do not hide a persistent correction forever.
    private let transientZeroSnapshotGracePeriod: TimeInterval = 30

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func startUpdating(config: ConfigData) {
        refreshInterval = max(
            5,
            TimeInterval(config["refresh-interval-seconds"]?.intValue ?? 60)
        )
        planOverride = config["plan"]?.stringValue
        scheduleRefreshTimer()
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let planOverride = planOverride
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.loadLimits(planOverride: planOverride)
            }.value

            self.updateWatchedPaths(result.watchPaths)
            self.isAuthenticated = result.isAuthenticated
            self.errorMessage = result.message
            if let candidate = result.snapshot {
                self.acceptStableSnapshot(candidate)
            } else if !result.isAuthenticated {
                self.transientZeroSnapshotStartedAt = nil
                self.snapshot = nil
            }
            self.isRefreshing = false
        }
    }

    private func acceptStableSnapshot(_ candidate: CodexLimitsSnapshot) {
        let now = Date()

        if Self.looksLikeTransientZeroSnapshot(
            candidate,
            replacing: snapshot,
            at: now
        ) {
            let startedAt = transientZeroSnapshotStartedAt ?? now
            transientZeroSnapshotStartedAt = startedAt
            if now.timeIntervalSince(startedAt)
                < transientZeroSnapshotGracePeriod {
                return
            }
        }

        transientZeroSnapshotStartedAt = nil
        snapshot = candidate
    }

    nonisolated private static func looksLikeTransientZeroSnapshot(
        _ candidate: CodexLimitsSnapshot,
        replacing previous: CodexLimitsSnapshot?,
        at now: Date
    ) -> Bool {
        guard let previous else { return false }

        let candidateWindows = [candidate.fiveHour, candidate.weekly]
            .compactMap { $0 }
        let previousWindows = [previous.fiveHour, previous.weekly]
            .compactMap { $0 }

        guard !candidateWindows.isEmpty,
              candidateWindows.allSatisfy({ $0.usedPercent == 0 }),
              previousWindows.contains(where: { $0.usedPercent > 0 }) else {
            return false
        }

        // A real reset is safe to show as soon as the old window has expired.
        // The bogus handoff snapshot instead arrives while the old schedule is
        // still active and advertises a different (or incomplete) schedule.
        let previousUsageStillActive = previousWindows.contains {
            $0.usedPercent > 0 && ($0.resetsAt ?? .distantPast) > now
        }
        guard previousUsageStillActive else { return false }

        return candidate.fiveHour?.resetsAt != previous.fiveHour?.resetsAt
            || candidate.weekly?.resetsAt != previous.weekly?.resetsAt
            || candidateWindows.count != previousWindows.count
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = min(10, refreshInterval / 5)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func scheduleDebouncedRefresh() {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func updateWatchedPaths(_ paths: [String]) {
        let uniquePaths = Set(paths)
        guard uniquePaths != watchedPaths else { return }

        fileWatchSources.forEach { $0.cancel() }
        fileWatchSources.removeAll()
        watchedPaths = uniquePaths

        for path in uniquePaths {
            let fileDescriptor = open(path, O_EVTONLY)
            guard fileDescriptor != -1 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.scheduleDebouncedRefresh()
                }
            }
            source.setCancelHandler {
                close(fileDescriptor)
            }
            source.resume()
            fileWatchSources.append(source)
        }
    }

    nonisolated private static func loadLimits(
        planOverride: String?
    ) -> LoadedCodexLimits {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let authURL = codexHome.appendingPathComponent("auth.json")
        let sessionsURL = codexHome.appendingPathComponent(
            "sessions", isDirectory: true)
        let authenticated = FileManager.default.fileExists(atPath: authURL.path)
        let paths = watchPaths(
            codexHome: codexHome,
            authURL: authURL,
            sessionsURL: sessionsURL
        )

        // Prefer Codex's live local app-server API. Session JSONL files are a
        // fallback and may remain unchanged for hours between CLI-backed turns.
        if let liveSnapshot = liveUsageSnapshot() {
            let windows = classifiedWindows(
                primary: liveSnapshot.primary,
                secondary: liveSnapshot.secondary
            )
            let plan = formattedPlan(
                normalizedPlan(planOverride)
                    ?? normalizedPlan(liveSnapshot.plan)
                    ?? "ChatGPT"
            )
            return LoadedCodexLimits(
                snapshot: CodexLimitsSnapshot(
                    fiveHour: normalizedWindow(windows.fiveHour),
                    weekly: normalizedWindow(windows.weekly),
                    plan: plan,
                    updatedAt: liveSnapshot.timestamp
                ),
                isAuthenticated: true,
                message: nil,
                watchPaths: paths
            )
        }

        guard let sessionSnapshot = latestUsageSnapshot(in: sessionsURL) else {
            let message = authenticated
                ? "Run a Codex task once to create a usage snapshot"
                : "Sign in to Codex, then run one task"
            return LoadedCodexLimits(
                snapshot: nil,
                isAuthenticated: authenticated,
                message: message,
                watchPaths: paths
            )
        }

        let plan = formattedPlan(
            normalizedPlan(planOverride)
                ?? normalizedPlan(sessionSnapshot.plan)
                ?? "ChatGPT"
        )
        let windows = classifiedWindows(
            primary: sessionSnapshot.primary,
            secondary: sessionSnapshot.secondary
        )
        let snapshot = CodexLimitsSnapshot(
            fiveHour: normalizedWindow(windows.fiveHour),
            weekly: normalizedWindow(windows.weekly),
            plan: plan,
            updatedAt: sessionSnapshot.timestamp
        )

        return LoadedCodexLimits(
            snapshot: snapshot,
            isAuthenticated: authenticated,
            message: nil,
            watchPaths: paths
        )
    }

    /// Fetches the same live snapshot used by Codex Desktop through its local
    /// JSON-RPC app server. A short-lived process keeps Barik independent of a
    /// separately managed daemon while the session-file fallback covers errors.
    nonisolated private static func liveUsageSnapshot() -> CodexUsageSnapshot? {
        let executablePaths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let executablePath = executablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let completion = DispatchSemaphore(value: 0)
        let processCompletion = DispatchSemaphore(value: 0)
        let stateQueue = DispatchQueue(label: "com.barik.codex-live-usage")
        var buffer = Data()
        var snapshot: CodexUsageSnapshot?
        var sentRateLimitRequest = false

        func send(_ json: String) {
            guard let data = "\(json)\n".data(using: .utf8) else { return }
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                completion.signal()
                return
            }

            stateQueue.sync {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line),
                          let message = object as? [String: Any],
                          let id = message["id"] as? NSNumber else { continue }

                    if id.intValue == 1, !sentRateLimitRequest {
                        sentRateLimitRequest = true
                        send(#"{"method":"initialized"}"#)
                        send(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
                    } else if id.intValue == 2,
                              let result = message["result"] as? [String: Any] {
                        snapshot = decodeLiveSnapshot(from: result)
                        completion.signal()
                    }
                }
            }
        }
        process.terminationHandler = { _ in
            completion.signal()
            processCompletion.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        send(
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"barik","title":"Barik","version":"1.0"},"capabilities":{"experimentalApi":true}}}"#
        )

        _ = completion.wait(timeout: .now() + 4)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            if processCompletion.wait(timeout: .now() + 0.5) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processCompletion.wait(timeout: .now() + 0.5)
            }
        }
        return stateQueue.sync { snapshot }
    }

    nonisolated private static func decodeLiveSnapshot(
        from result: [String: Any]
    ) -> CodexUsageSnapshot? {
        let byLimitID = result["rateLimitsByLimitId"] as? [String: Any]
        let rateLimits = byLimitID?["codex"] as? [String: Any]
            ?? result["rateLimits"] as? [String: Any]
        guard let rateLimits else { return nil }

        func bucket(_ key: String) -> CodexSessionEvent.Bucket? {
            guard let value = rateLimits[key] as? [String: Any],
                  let usedPercent = value["usedPercent"] as? NSNumber else {
                return nil
            }
            return CodexSessionEvent.Bucket(
                usedPercent: usedPercent.doubleValue,
                windowMinutes: (value["windowDurationMins"] as? NSNumber)?.intValue ?? 0,
                resetsAt: (value["resetsAt"] as? NSNumber)?.doubleValue ?? 0
            )
        }

        let primary = bucket("primary")
        let secondary = bucket("secondary")
        guard primary != nil || secondary != nil else { return nil }
        return CodexUsageSnapshot(
            primary: primary,
            secondary: secondary,
            plan: rateLimits["planType"] as? String,
            timestamp: Date()
        )
    }

    nonisolated private static func latestUsageSnapshot(
        in sessionsURL: URL
    ) -> CodexUsageSnapshot? {
        var canonicalCandidates: [CodexUsageSnapshot] = []
        var fallbackCandidates: [CodexUsageSnapshot] = []

        for fileURL in recentSessionFiles(in: sessionsURL) {
            guard let content = try? String(
                contentsOf: fileURL,
                encoding: .utf8
            ) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard line.contains(#""type":"token_count""#),
                      line.contains(#""rate_limits":"#),
                      let event = decodeEvent(from: line),
                      event.type == "event_msg",
                      event.payload.type == "token_count",
                      let rateLimits = event.payload.rateLimits,
                      let timestamp = parseTimestamp(event.timestamp),
                      rateLimits.primary != nil || rateLimits.secondary != nil
                else { continue }

                let candidate = CodexUsageSnapshot(
                    primary: rateLimits.primary,
                    secondary: rateLimits.secondary,
                    plan: rateLimits.planType,
                    timestamp: timestamp
                )

                if rateLimits.limitID == "codex" {
                    canonicalCandidates.append(candidate)
                } else {
                    fallbackCandidates.append(candidate)
                }
                break
            }
        }

        return reliableNewestSnapshot(from: canonicalCandidates)
            ?? reliableNewestSnapshot(from: fallbackCandidates)
    }

    /// New Codex sessions can briefly emit a synthetic 0/0 snapshot with a new
    /// reset schedule before the server-backed limits arrive. Accepting it makes
    /// the widget flash 100/100 even though the Codex UI still has usage. If an
    /// older, non-zero snapshot says its reset window is still active, retain it
    /// until a real follow-up snapshot lands.
    nonisolated private static func reliableNewestSnapshot(
        from candidates: [CodexUsageSnapshot]
    ) -> CodexUsageSnapshot? {
        let sorted = candidates.sorted { $0.timestamp > $1.timestamp }

        for (index, candidate) in sorted.enumerated() {
            let candidateIsZero = (candidate.primary?.usedPercent ?? 0) == 0
                && (candidate.secondary?.usedPercent ?? 0) == 0
            guard candidateIsZero else { return candidate }

            let recentOlder = sorted.dropFirst(index + 1).first { older in
                let age = candidate.timestamp.timeIntervalSince(older.timestamp)
                let hadUsage = (older.primary?.usedPercent ?? 0) > 0
                    || (older.secondary?.usedPercent ?? 0) > 0
                return age >= 0 && age <= 15 * 60 && hadUsage
            }
            guard let recentOlder else { return candidate }

            let olderResetStillActive = [
                recentOlder.primary?.resetsAt,
                recentOlder.secondary?.resetsAt,
            ].compactMap { $0 }.contains {
                $0 > candidate.timestamp.timeIntervalSince1970
            }
            let resetScheduleChanged =
                candidate.primary?.resetsAt != recentOlder.primary?.resetsAt
                || candidate.secondary?.resetsAt != recentOlder.secondary?.resetsAt

            if olderResetStillActive && resetScheduleChanged {
                continue
            }
            return candidate
        }

        return sorted.first
    }

    nonisolated private static func recentSessionFiles(
        in sessionsURL: URL
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
                return lhsDate == rhsDate
                    ? lhs.path > rhs.path
                    : lhsDate > rhsDate
            }
            .prefix(100)
            .map { $0 }
    }

    nonisolated private static func watchPaths(
        codexHome: URL,
        authURL: URL,
        sessionsURL: URL
    ) -> [String] {
        let fileManager = FileManager.default
        var paths = Set<String>()

        for url in [codexHome, authURL, sessionsURL]
        where fileManager.fileExists(atPath: url.path) {
            paths.insert(url.path)
        }

        for fileURL in recentSessionFiles(in: sessionsURL).prefix(8) {
            paths.insert(fileURL.path)
            var directoryURL = fileURL.deletingLastPathComponent()
            while directoryURL.path.hasPrefix(sessionsURL.path) {
                paths.insert(directoryURL.path)
                if directoryURL.path == sessionsURL.path { break }
                directoryURL.deleteLastPathComponent()
            }
        }

        return Array(paths)
    }

    nonisolated private static func normalizedWindow(
        _ bucket: CodexSessionEvent.Bucket?
    ) -> CodexLimitWindow? {
        guard let bucket else { return nil }

        let usedPercent = max(0, min(100, Int(bucket.usedPercent.rounded())))
        let resetDate = Date(timeIntervalSince1970: bucket.resetsAt)
        return CodexLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: bucket.windowMinutes,
            resetsAt: resetDate > Date() ? resetDate : nil
        )
    }

    /// `primary` and `secondary` describe server priority, not a stable time
    /// window. In particular, a weekly-only account returns its 10,080-minute
    /// bucket as `primary`, so classify buckets by their actual duration.
    nonisolated private static func classifiedWindows(
        primary: CodexSessionEvent.Bucket?,
        secondary: CodexSessionEvent.Bucket?
    ) -> (
        fiveHour: CodexSessionEvent.Bucket?,
        weekly: CodexSessionEvent.Bucket?
    ) {
        let buckets = [primary, secondary].compactMap { $0 }
        return (
            fiveHour: buckets.first { $0.windowMinutes == 5 * 60 },
            weekly: buckets.first { $0.windowMinutes == 7 * 24 * 60 }
        )
    }

    nonisolated private static func decodeEvent(
        from line: Substring
    ) -> CodexSessionEvent? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CodexSessionEvent.self, from: data)
    }

    nonisolated private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    nonisolated private static func normalizedPlan(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ["unknown", "null", "nil", "none"].contains(trimmed.lowercased())
            ? nil
            : trimmed
    }

    nonisolated private static func formattedPlan(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
