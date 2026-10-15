import AppKit
import Darwin
import Foundation

class YabaiSpacesProvider: SpacesProvider, SwitchableSpacesProvider, MovableWindowsProvider {
    typealias SpaceType = YabaiSpace
    let executablePath = ConfigManager.shared.config.yabai.path
    private let commandRunner: (([String]) -> Data?)?
    private static let signalLock = NSLock()
    private var nextSignalCheck = Date.distantPast

    init(commandRunner: (([String]) -> Data?)? = nil) {
        self.commandRunner = commandRunner
        #if DEBUG
        assert(Self.isDisplayableWindow(role: "AXWindow", subrole: "AXStandardWindow", isFloating: true))
        assert(Self.isDisplayableWindow(role: "AXWindow", subrole: "AXDialog", isFloating: false))
        assert(!Self.isDisplayableWindow(role: "AXWindow", subrole: "AXDialog", isFloating: true))
        assert(!Self.isDisplayableWindow(role: "AXHelpTag", subrole: "", isFloating: true))
        #endif
    }

    private static func isDisplayableWindow(role: String, subrole: String, isFloating: Bool) -> Bool {
        role == "AXWindow" && (!isFloating || subrole == "AXStandardWindow")
    }

    private func runYabaiCommand(arguments: [String]) -> Data? {
        if let commandRunner { return commandRunner(arguments) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let completion = DispatchSemaphore(value: 0)
        let dataLock = NSLock()
        var output = Data()
        let readHandle = pipe.fileHandleForReading

        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            dataLock.lock()
            output.append(chunk)
            dataLock.unlock()
        }
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            print("Yabai error: \(error)")
            return nil
        }

        var finished = completion.wait(timeout: .now() + 1.5) == .success
        if !finished {
            process.terminate()
            finished = completion.wait(timeout: .now() + 0.25) == .success
        }
        if !finished, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            finished = completion.wait(timeout: .now() + 0.25) == .success
        }

        guard finished else {
            readHandle.readabilityHandler = nil
            return nil
        }

        readHandle.readabilityHandler = nil
        let tail = readHandle.readDataToEndOfFile()
        dataLock.lock()
        output.append(tail)
        dataLock.unlock()

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output
    }

    func installSignals(force: Bool = true) {
        Self.signalLock.lock()
        defer { Self.signalLock.unlock() }
        guard force || Date() >= nextSignalCheck else { return }
        nextSignalCheck = Date().addingTimeInterval(10)

        struct Signal: Decodable {
            let label: String
            let event: String
            let action: String
        }
        guard let data = runYabaiCommand(arguments: ["-m", "signal", "--list"]),
              let installed = try? JSONDecoder().decode([Signal].self, from: data) else { return }

        for (label, event, action) in [
            ("barik_space_changed", "space_changed", "/usr/bin/notifyutil -z 0 -p com.barik.space_changed.$YABAI_SPACE_INDEX"),
            ("barik_space_created", "space_created", "/usr/bin/notifyutil -z 0 -p com.barik.space_changed"),
            ("barik_space_destroyed", "space_destroyed", "/usr/bin/notifyutil -z 0 -p com.barik.space_changed"),
            ("barik_window_focused", "window_focused", "/usr/bin/notifyutil -z 0 -p com.barik.window_focused.$YABAI_WINDOW_ID"),
            ("barik_window_created", "window_created", "/usr/bin/notifyutil -z 0 -p com.barik.window_changed"),
            ("barik_window_destroyed", "window_destroyed", "/usr/bin/notifyutil -z 0 -p com.barik.window_changed"),
        ] {
            if let existing = installed.first(where: { $0.label == label }) {
                guard existing.event != event || existing.action != action else { continue }
                _ = runYabaiCommand(arguments: ["-m", "signal", "--remove", label])
            }
            _ = runYabaiCommand(arguments: [
                "-m", "signal", "--add", "label=\(label)", "event=\(event)", "action=\(action)",
            ])
        }
    }

    private func fetchSpaces() -> [YabaiSpace]? {
        guard
            let data = runYabaiCommand(arguments: ["-m", "query", "--spaces"])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let spaces = try decoder.decode([YabaiSpace].self, from: data)
            return spaces
        } catch {
            print("Decode yabai spaces error: \(error)")
            return nil
        }
    }

    private func fetchWindows() -> [YabaiWindow]? {
        guard
            let data = runYabaiCommand(arguments: ["-m", "query", "--windows"])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let windows = try decoder.decode([YabaiWindow].self, from: data)
            return windows
        } catch {
            print("Decode yabai windows error: \(error)")
            return nil
        }
    }

    private func fetchFocusedWindowId() -> Int? {
        guard
            let data = runYabaiCommand(arguments: ["-m", "query", "--windows", "--window"])
        else {
            return nil
        }
        struct FocusedWindow: Decodable {
            let id: Int
        }
        do {
            return try JSONDecoder().decode(FocusedWindow.self, from: data).id
        } catch {
            return nil
        }
    }

    func getFocusedSpaceId() -> String? {
        guard let data = runYabaiCommand(arguments: ["-m", "query", "--spaces", "--space"]) else { return nil }
        struct FocusedSpace: Decodable {
            let id: Int
            enum CodingKeys: String, CodingKey { case id = "index" }
        }
        return (try? JSONDecoder().decode(FocusedSpace.self, from: data)).map { String($0.id) }
    }

    func getSpacesWithWindows() -> [YabaiSpace]? {
        // Yabai loses signals when it restarts. Repair them from the existing
        // background refresh path, with at most one signal query per 10 seconds.
        installSignals(force: false)
        // Keep the command sequence on the caller's single background worker.
        // Blocking an outer global-queue job while scheduling nested jobs onto the
        // same pool can exhaust every dispatch worker when refreshes overlap.
        guard var spaces = fetchSpaces(), var windows = fetchWindows() else {
            return nil
        }

        // Query focused window AFTER bulk queries to get the most up-to-date window state.
        // The bulk --windows query can return stale has-focus for stacked windows.
        if let focusedId = fetchFocusedWindowId() {
            for i in 0..<windows.count {
                windows[i].isFocused = (windows[i].id == focusedId)
            }
        }

        // Query the focused space AFTER both bulk queries and use it as the only source
        // of truth for the space indicator. A focused sticky/scratchpad window keeps its
        // original `space` value even while it is shown on another space, so deriving
        // space focus from that window can leave the indicator on the wrong space.
        if let focusedSpaceId = getFocusedSpaceId().flatMap(Int.init) {
            for i in 0..<spaces.count {
                spaces[i].isFocused = (spaces[i].id == focusedSpaceId)
            }
        }

        // Exclude apps that don't show in the Dock (accessory/background apps like Hammerspoon, Raycast, etc.)
        // Some apps ship helper processes with the same localized name as their regular app.
        // If a regular app with that name exists, keep its yabai windows visible.
        let runningApps = NSWorkspace.shared.runningApplications
        let regularApps = Set(
            runningApps
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
        )
        let accessoryApps = Set(
            runningApps
                .filter { $0.activationPolicy != .regular }
                .compactMap { $0.localizedName }
        ).subtracting(regularApps)

        let filteredWindows = windows.filter { window in
            // Basic filters
            guard window.appName != "Spotify",
                  window.opacity > 0 && !window.isHidden && !window.isSticky,
                  Self.isDisplayableWindow(
                    role: window.role,
                    subrole: window.subrole,
                    isFloating: window.isFloating
                  ) else { return false }
            // Exclude accessory/background apps entirely
            if accessoryApps.contains(window.appName ?? "") { return false }

            return true
        }
        var spaceDict = Dictionary(
            uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        for window in filteredWindows {
            if var space = spaceDict[window.spaceId] {
                space.windows.append(window)
                spaceDict[window.spaceId] = space
            }
        }
        var resultSpaces = Array(spaceDict.values)
        for i in 0..<resultSpaces.count {
            // Sort by screen x-position (left to right), stable id tiebreaker
            resultSpaces[i].windows.sort {
                let x0 = $0.frame?.x ?? CGFloat.greatestFiniteMagnitude
                let x1 = $1.frame?.x ?? CGFloat.greatestFiniteMagnitude
                if x0 != x1 { return x0 < x1 }
                return $0.id < $1.id
            }
        }
        return resultSpaces
    }

    func focusSpace(spaceId: String, needWindowFocus: Bool) {
        _ = runYabaiCommand(arguments: ["-m", "space", "--focus", spaceId])
        if !needWindowFocus { return }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.1
        ) {
            if let spaces = self.getSpacesWithWindows() {
                if let space = spaces.first(where: { $0.id == Int(spaceId) }) {
                    let hasFocused = space.windows.contains { $0.isFocused }
                    if !hasFocused, let firstWindow = space.windows.first {
                        _ = self.runYabaiCommand(arguments: [
                            "-m", "window", "--focus", String(firstWindow.id),
                        ])
                    }
                }
            }
        }
    }

    func focusWindow(windowId: String) {
        _ = runYabaiCommand(arguments: ["-m", "window", "--focus", windowId])
    }

    func moveWindow(windowId: Int, toSpace: String) -> Bool {
        runYabaiCommand(arguments: ["-m", "window", String(windowId), "--space", toSpace]) != nil
    }

    func arrangeWindow(_ id: Int, relativeTo target: Int, direction: String?, detachFirst: Bool) -> Bool {
        if let direction {
            guard ["west", "east", "north", "south"].contains(direction) else { return false }
            if detachFirst {
                // Yabai rejects warping between members of the same stack.
                // Unmanage/remanage the source first, then place it explicitly.
                guard runYabaiCommand(arguments: ["-m", "window", String(id), "--toggle", "float"]) != nil else { return false }
                guard runYabaiCommand(arguments: ["-m", "window", String(id), "--toggle", "float"]) != nil else { return false }
            }
            // --insert toggles an existing identical direction off. Passing
            // through stack first guarantees that the requested side is set.
            guard runYabaiCommand(arguments: ["-m", "window", String(target), "--insert", "stack"]) != nil,
                  runYabaiCommand(arguments: ["-m", "window", String(target), "--insert", direction]) != nil else { return false }
            return runYabaiCommand(arguments: ["-m", "window", String(id), "--warp", String(target)]) != nil
        }
        return runYabaiCommand(arguments: ["-m", "window", String(target), "--stack", String(id)]) != nil
    }

    func swapWindows(_ first: Int, _ second: Int) -> Bool {
        runYabaiCommand(arguments: ["-m", "window", String(first), "--swap", String(second)]) != nil
    }

    func closeWindow(windowId: String) {
        _ = runYabaiCommand(arguments: ["-m", "window", "--close", windowId])
    }
}
