import Foundation

@main
private enum CodexActivitySelectionTests {
    static func main() {
        func activity(_ id: Int, running: Bool) -> CodexActivity {
            CodexActivity(id: String(id), title: "Chat \(id)", startedAt: nil,
                completedAt: running ? nil : Date(timeIntervalSince1970: Double(id)),
                consumedTokens: nil, isUnread: false, isRunning: running,
                lastUpdatedAt: Date(timeIntervalSince1970: Double(id)))
        }
        let recent = (10...15).map { activity($0, running: false) }
        for count in 0...10 {
            let running = (0..<count).map { activity($0, running: true) }
            let result = CodexActivitySelection(running: running, recent: recent + running)
            precondition(result.running.count == min(3, count))
            precondition(result.completed.count == 2)
            precondition(result.completed.map(\.id) == Array(recent.suffix(2)).map(\.id))
        }
        let sparse = CodexActivitySelection(running: [], recent: [recent[0], recent[0]])
        precondition(sparse.completed.count == 1)
        let overlap = CodexActivitySelection(running: [activity(15, running: true)], recent: recent)
        precondition(overlap.completed.map(\.id) == ["13", "14"])
        precondition(CodexActivitySelection(running: [], recent: []).completed.isEmpty)
        let wide = CodexActivitySelection(running: (0..<8).map { activity($0, running: true) }, recent: recent, maximumRunning: 6)
        precondition(wide.running.count == 6 && wide.completed.count == 2)
        print("PASS: running cap, two completed dots, wider display capacity, no duplicates")
    }
}
