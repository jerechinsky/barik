import AppKit

// Standalone harness: compile with the Spaces sources, without the app services.
final class ConfigManager {
    static let shared = ConfigManager()
    struct Tool { var path = "/usr/bin/false" }
    struct Config { var yabai = Tool(); var aerospace = Tool() }
    var config = Config()
}

enum SleepWakeManager {
    static let willSleepNotification = Notification.Name("test.sleep")
    static let didWakeNotification = Notification.Name("test.wake")
}

private final class MockProvider: SpacesProvider {
    private let lock = NSLock()
    private var snapshot: [AeroSpace] = []
    private var nextGate: DispatchSemaphore?
    private var calls = 0
    private var failNext = false

    func failNextQuery() { lock.withLock { failNext = true } }

    var callCount: Int { lock.withLock { calls } }

    func setSpaces(_ ids: [String], focused: String = "1") {
        lock.withLock {
            snapshot = ids.map { AeroSpace(workspace: $0, isFocused: $0 == focused) }
        }
    }

    func setWindows(_ ids: [Int]) {
        let windows = ids.map { id in
            try! JSONDecoder().decode(AeroWindow.self, from: Data(
                "{\"window-id\":\(id),\"window-title\":\"Test \(id)\",\"workspace\":\"1\"}".utf8
            ))
        }
        lock.withLock {
            snapshot = [AeroSpace(workspace: "1", isFocused: true, windows: windows)]
        }
    }

    func setWindowSpaces() {
        lock.withLock {
            snapshot = [1, 2].map { index in
                let window = try! JSONDecoder().decode(AeroWindow.self, from: Data(
                    "{\"window-id\":\(100 + index),\"window-title\":\"Test\",\"workspace\":\"\(index)\"}".utf8))
                return AeroSpace(workspace: String(index), isFocused: index == 1, windows: [window])
            }
        }
    }

    func holdNextQuery() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { nextGate = gate }
        return gate
    }

    func getSpacesWithWindows() -> [AeroSpace]? {
        let (result, gate): ([AeroSpace]?, DispatchSemaphore?) = lock.withLock {
            calls += 1
            if failNext {
                failNext = false
                return (nil, nil)
            }
            let gate = nextGate
            nextGate = nil
            return (snapshot, gate)
        }
        if let gate {
            precondition(gate.wait(timeout: .now() + 3) == .success)
        }
        return result
    }

    func getFocusedSpaceId() -> String? { "1" }
}

private final class SlowSwitchProvider: SwitchableSpacesProvider {
    private let lock = NSLock()
    private var focused = "1"
    private var targets: [String] = []
    private var active = 0
    private var maximumActive = 0
    var recordedTargets: [String] { lock.withLock { targets } }
    var maxConcurrent: Int { lock.withLock { maximumActive } }
    func getSpacesWithWindows() -> [AeroSpace]? {
        lock.withLock { (1...3).map { AeroSpace(workspace: String($0), isFocused: String($0) == focused) } }
    }
    func getFocusedSpaceId() -> String? { lock.withLock { focused } }
    func focusSpace(spaceId: String, needWindowFocus: Bool) {
        precondition(!needWindowFocus, "Drag switched windows")
        lock.withLock { active += 1; maximumActive = max(maximumActive, active); targets.append(spaceId) }
        Thread.sleep(forTimeInterval: 0.12)
        lock.withLock { focused = spaceId; active -= 1 }
    }
    func focusWindow(windowId: String) { preconditionFailure("Unexpected window activation") }
    func closeWindow(windowId: String) {}
}

@main
private enum SpacesRefreshTests {
    static let notificationPrefix = "com.barik.tests.\(UUID().uuidString)"
    static func wait(_ message: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), message)
    }

    static func notify(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name.replacingOccurrences(of: "com.barik", with: notificationPrefix) as CFString), nil, nil, true
        )
    }

    static func main() {
        // Exercise the real signal installer, including recovery after yabai
        // loses its registrations. Leave unrelated signals untouched.
        let foreign = ["label": "other_app", "event": "space_changed", "action": "true"]
        var signals = [foreign]
        var mutations = 0
        let yabai = YabaiSpacesProvider(commandRunner: { arguments in
            switch arguments[2] {
            case "--list":
                return try! JSONSerialization.data(withJSONObject: signals)
            case "--add":
                mutations += 1
                signals.append(Dictionary(uniqueKeysWithValues: arguments.dropFirst(3).map {
                    let parts = $0.split(separator: "=", maxSplits: 1).map(String.init)
                    return (parts[0], parts[1])
                }))
            case "--remove":
                mutations += 1
                signals.removeAll { $0["label"] == arguments[3] }
            default: preconditionFailure("Unexpected command: \(arguments)")
            }
            return Data()
        })
        yabai.installSignals()
        precondition(signals.count == 7 && signals.contains(foreign))
        let firstMutations = mutations
        yabai.installSignals()
        precondition(mutations == firstMutations, "Reinstalled healthy signals")
        signals = [foreign]
        yabai.installSignals()
        precondition(signals.count == 7 && signals.contains(foreign), "Signals not restored")
        func notifySpaceEvent(_ event: String) {
            let action = signals.first { $0["event"] == event }!["action"]!
            precondition(action == "/usr/bin/notifyutil -z 0 -p com.barik.space_changed")
            notify(String(action.split(separator: " ").last!))
        }

        var dragCommands: [[String]] = []
        let dragProvider = YabaiSpacesProvider(commandRunner: { args in dragCommands.append(args); return Data() })
        precondition(dragProvider.moveWindow(windowId: 101, toSpace: "2"))
        precondition(dragProvider.arrangeWindow(101, relativeTo: 102, direction: nil, detachFirst: false))
        precondition(dragProvider.arrangeWindow(101, relativeTo: 102, direction: "south", detachFirst: true))
        precondition(dragProvider.swapWindows(101, 102))
        precondition(dragCommands == [
            ["-m", "window", "101", "--space", "2"],
            ["-m", "window", "102", "--stack", "101"],
            ["-m", "window", "101", "--toggle", "float"],
            ["-m", "window", "101", "--toggle", "float"],
            ["-m", "window", "102", "--insert", "stack"],
            ["-m", "window", "102", "--insert", "south"],
            ["-m", "window", "101", "--warp", "102"],
            ["-m", "window", "101", "--swap", "102"]
        ], "Incorrect window drop commands")

        let provider = MockProvider()
        provider.setWindows([101, 102])
        let model = SpacesViewModel(provider: AnySpacesProvider(provider), notificationPrefix: notificationPrefix)
        func ids() -> [Int] { model.spaces.flatMap(\.windows).map(\.id) }
        wait("Initial windows missing") { ids() == [101, 102] }

        provider.setWindowSpaces()
        notify("com.barik.window_changed")
        wait("Two-Space fixture missing") { model.spaces.count == 2 }
        notify("com.barik.window_focused.101")
        wait("First focus missing") { model.spaces[0].windows[0].isFocused }
        notify("com.barik.space_requested.2")
        notify("com.barik.window_focused.102")
        wait("Second focus missing") { model.spaces[1].windows[0].isFocused }
        notify("com.barik.space_requested.1")
        wait("Remembered app did not follow Space immediately") { model.spaces[0].windows[0].isFocused }
        notify("com.barik.window_focused.102")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(model.spaces[0].windows[0].isFocused, "Late previous-Space focus rewound the indicator")
        provider.setWindows([101, 102])
        notify("com.barik.space_changed.1")
        notify("com.barik.window_changed")
        wait("Single-Space fixture not restored") { model.spaces.count == 1 && ids() == [101, 102] }

        // Under CPU pressure, a timed-out query must not erase the entire bar.
        let beforeFailure = provider.callCount
        provider.failNextQuery()
        notify("com.barik.window_changed")
        wait("Failed query did not run") { provider.callCount > beforeFailure }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(ids() == [101, 102], "Transient query failure erased the Spaces widget")

        // Closing an unfocused window does not produce a focus event.
        provider.setWindows([101])
        notify("com.barik.window_changed")
        wait("Closed window survived structural notification") { ids() == [101] }

        provider.setWindows([101, 102])
        notify("com.barik.window_changed")
        wait("New window missing") { ids() == [101, 102] }

        // A focus signal arriving during the close refresh used to discard
        // the snapshot and leave the closed icon until the 10-second timer.
        provider.setWindows([102])
        let gate = provider.holdNextQuery()
        let previousCalls = provider.callCount
        notify("com.barik.window_changed")
        wait("Close refresh did not start") { provider.callCount > previousCalls }
        notify("com.barik.window_focused.102")
        wait("Focus notification missing") {
            model.spaces.flatMap(\.windows).first(where: { $0.id == 102 })?.isFocused == true
        }
        gate.signal()
        wait("Focus invalidation lost the close refresh") { ids() == [102] }

        provider.setWindows([])
        notify("com.barik.window_changed")
        wait("Last closed window survived") { ids().isEmpty }

        provider.setSpaces(["1", "2", "3"])
        notifySpaceEvent("space_created")
        wait("Created spaces missing") { model.spaces.map(\.id) == ["1", "2", "3"] }

        // Destroy an inactive Space without a focus signal, while an older
        // snapshot is in flight and an optimistic request uses the old index.
        let layoutGate = provider.holdNextQuery()
        let callsBeforeLayout = provider.callCount
        notify("com.barik.window_changed")
        wait("Layout query did not start") { provider.callCount > callsBeforeLayout }
        model.switchToSpace(model.spaces.last!)
        provider.setSpaces(["1", "2"])
        notifySpaceEvent("space_destroyed")
        // Allow delivery to invalidate the old snapshot before releasing it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layoutGate.signal()
        wait("Destroyed Space or obsolete focus request survived") {
            model.spaces.map(\.id) == ["1", "2"] && model.spaces.first?.isFocused == true
        }

        provider.setSpaces(["1"], focused: "1")
        notifySpaceEvent("space_destroyed")
        wait("Repeated destruction not reflected") { model.spaces.map(\.id) == ["1"] }

        provider.setSpaces(["1", "2", "3"])
        notifySpaceEvent("space_created")
        wait("Burst fixture missing") { model.spaces.count == 3 }
        let burstCalls = provider.callCount
        for index in 0..<24 {
            let target = String(index % 3 + 1)
            provider.setSpaces(["1", "2", "3"], focused: target)
            notify("com.barik.space_requested.\(target)")
            notify("com.barik.space_changed.\(target)")
            wait("Focus waited for a bulk refresh") {
                model.spaces.first(where: \.isFocused)?.id == target
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            precondition(provider.callCount == burstCalls, "Bulk query during key-repeat burst")
        }
        wait("Burst did not reconcile") { provider.callCount == burstCalls + 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(model.spaces.first(where: \.isFocused)?.id == "3")

        // A relative shortcut predicted 2 but actually reached 3. Previously
        // the request permanently rejected both confirmations and snapshots.
        notify("com.barik.space_requested.2")
        wait("Prediction missing") { model.spaces.first(where: \.isFocused)?.id == "2" }
        notify("com.barik.space_changed.3")
        wait("Mismatched shortcut prediction pinned focus") {
            model.spaces.first(where: \.isFocused)?.id == "3"
        }

        // Recovery is also required when the focus command fails entirely.
        notify("com.barik.space_requested.1")
        wait("Failed request not received") { model.spaces.first(where: \.isFocused)?.id == "1" }
        wait("Missing confirmation pinned focus") {
            model.spaces.first(where: \.isFocused)?.id == "3"
        }

        let staleFocusGate = provider.holdNextQuery()
        let beforeStaleFocus = provider.callCount
        notify("com.barik.window_changed")
        wait("Stale focus query did not start") { provider.callCount > beforeStaleFocus }
        provider.setSpaces(["1", "2", "3"], focused: "2")
        notify("com.barik.space_changed.2")
        wait("In-flight query blocked immediate focus") {
            model.spaces.first(where: \.isFocused)?.id == "2"
        }
        staleFocusGate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(model.spaces.first(where: \.isFocused)?.id == "2", "Stale query rolled focus back")
        wait("Invalidated query did not reconcile") { provider.callCount == beforeStaleFocus + 2 }

        // Exercise the external posting command too: notifyutil defaults to a
        // 100 ms sleep, which the in-process notification tests cannot catch.
        var helperLatencies: [Double] = []
        for index in 0..<12 {
            let target = index.isMultiple(of: 2) ? "1" : "2"
            provider.setSpaces(["1", "2", "3"], focused: target)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
            helper.arguments = ["-z", "0", "-p", "\(notificationPrefix).space_changed.\(target)"]
            let start = ProcessInfo.processInfo.systemUptime
            try! helper.run()
            wait("External focus notification missing") {
                !helper.isRunning && model.spaces.first(where: \.isFocused)?.id == target
            }
            precondition(helper.terminationStatus == 0)
            helperLatencies.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        print("External helper to model update: max \(helperLatencies.max()!) ms over 12 switches")
        // Saturate a slow provider with pointer targets. Only the first and
        // final requests should run, and stale confirmations must not rewind UI.
        let slow = SlowSwitchProvider()
        let dragPrefix = "com.barik.dragtests.\(UUID().uuidString)"
        let dragModel = SpacesViewModel(provider: AnySpacesProvider(slow), notificationPrefix: dragPrefix)
        wait("Drag fixture missing") { dragModel.spaces.count == 3 }
        dragModel.switchToSpace(dragModel.spaces[1], needWindowFocus: false)
        wait("First drag command missing") { slow.recordedTargets == ["2"] }
        for index in 0..<100 {
            dragModel.switchToSpace(dragModel.spaces[index % 3], needWindowFocus: false)
        }
        dragModel.switchToSpace(dragModel.spaces[2], needWindowFocus: false)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("\(dragPrefix).space_changed.2" as CFString), nil, nil, true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(dragModel.spaces.first(where: \.isFocused)?.id == "3", "Stale confirmation rewound drag")
        wait("Latest drag command missing") { slow.recordedTargets.count == 2 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(slow.recordedTargets == ["2", "3"], "Obsolete drag targets executed")
        precondition(slow.maxConcurrent == 1, "Space commands overlapped")
        precondition(dragModel.spaces.first(where: \.isFocused)?.id == "3", "Final drag target lost")
        print("PASS: 102 drag requests coalesced to 2 serial commands, stale confirmation rejected")

        print("PASS: lifecycle and layout races, signal recovery, 24-switch burst without bulk queries, mismatched and missing confirmations")
    }
}
