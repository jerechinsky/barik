import Foundation

struct CodexActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let startedAt: Date?
    let completedAt: Date?
    let consumedTokens: Int?
    let isUnread: Bool
    let isRunning: Bool
    let lastUpdatedAt: Date
}

/// Running chats take priority; completed chats never occupy more than two dots.
struct CodexActivitySelection {
    let running: [CodexActivity]
    let completed: [CodexActivity]

    init(running: [CodexActivity], recent: [CodexActivity], maximumRunning: Int = 3) {
        self.running = Array(running.prefix(max(1, maximumRunning)))
        let runningIDs = Set(running.map(\.id))
        var seen = runningIDs
        completed = Array(recent
            .filter { !$0.isRunning && seen.insert($0.id).inserted }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .prefix(2)
            .reversed())
    }
}
