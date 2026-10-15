// ABOUTME: Keeps display and system awake using macOS assertions independent of attached monitors.
// ABOUTME: Uses an existing optional clamshell permission without ever requesting a password.
import AppKit
import Foundation

final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()
    @Published private(set) var isActive = false
    @Published private(set) var isChanging = false
    @Published private(set) var isJiggling = false
    @Published private(set) var isUserActive = false
    @Published private(set) var jigglerNeedsPermission = false
    @Published private(set) var isMonitoringUserActivity = false
    private var observedNudgeCount = 0
    private var lastObservedNudge: Date?
    private var jiggleTimer: Timer?
    private var pendingPointerReturn: DispatchWorkItem?
    private var activityTap: CFMachPort?
    private var activitySource: CFRunLoopSource?
    private var userActivityTimer: Timer?
    private var lastUserActivity: Date?
    private static let jiggleEventMarker: Int64 = 0x424152494B
    private var assertionProcess: Process?
    private var ownsSleepDisabled = false
    private static let preference = "keepAwakeAssertionsEnabled"

    private init() {
        UserDefaults.standard.register(defaults: [Self.preference: true])
        if UserDefaults.standard.bool(forKey: Self.preference) { activate() }
        writeJigglerStatus()
    }

    // Deliberately session-only: restarting Barik never starts moving the pointer.
    func toggleJiggler() {
        defer { writeJigglerStatus() }
        if isJiggling { stopJiggler(); return }
        guard !isChanging else { return }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            jigglerNeedsPermission = true
            return
        }
        jigglerNeedsPermission = false
        startActivityMonitoring()
        guard activityTap != nil else {
            jigglerNeedsPermission = true
            return
        }
        if !isActive { activate() }
        guard isActive else { stopActivityMonitoring(); return }
        isJiggling = true
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.jiggleIfIdle()
        }
        jiggleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopJiggler() {
        pendingPointerReturn?.cancel()
        pendingPointerReturn = nil
        jiggleTimer?.invalidate()
        jiggleTimer = nil
        isJiggling = false
        stopActivityMonitoring()
        isUserActive = false
        writeJigglerStatus()
    }

    private func jiggleIfIdle() {
        defer { writeJigglerStatus() }
        guard isJiggling else { return }
        guard CGPreflightPostEventAccess() else {
            stopJiggler()
            jigglerNeedsPermission = true
            return
        }
        guard assertionProcess?.isRunning == true else {
            stopJiggler()
            refreshState()
            return
        }
        // Do not interfere with typing, dragging, held keys, or a locked session.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?[kCGSessionOnConsoleKey as String] as? Bool == true,
              session?["CGSSessionScreenIsLocked"] as? Bool != true,
              !isUserActive,
              NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!) >= 30,
              let position = CGEvent(source: nil)?.location else { return }
        // Keep the nudge on the current display, including at screen edges.
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(position, 1, &display, &count) == .success,
              count > 0 else { return }
        let bounds = CGDisplayBounds(display)
        let offset = position.x + 1 < bounds.maxX ? 1.0 : -1.0
        let nudged = CGPoint(x: position.x + offset, y: position.y)
        guard let source = CGEventSource(stateID: .privateState),
              let out = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                mouseCursorPosition: nudged, mouseButton: .left),
              let back = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: position, mouseButton: .left) else { return }
        out.setIntegerValueField(.eventSourceUserData, value: Self.jiggleEventMarker)
        back.setIntegerValueField(.eventSourceUserData, value: Self.jiggleEventMarker)
        out.post(tap: .cghidEventTap)
        // Separate the events so apps can observe real movement. Never pull the
        // pointer back if the user has moved it or started pressing anything.
        let restore = DispatchWorkItem { [weak self] in
            guard let self, self.isJiggling, !self.isUserActive,
                  CGPreflightPostEventAccess(),
                  NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
                  CGEvent(source: nil)?.location == nudged else { return }
            self.observedNudgeCount += 1
            self.lastObservedNudge = Date()
            self.writeJigglerStatus()
            back.post(tap: .cghidEventTap)
            self.pendingPointerReturn = nil
        }
        pendingPointerReturn = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: restore)
    }

    private func startActivityMonitoring() {
        guard activityTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<CaffeinateManager>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.activityTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Source state IDs describe the event state table, not a unique sender.
            // Explicitly mark our events and also exclude our process as a fallback.
            guard event.getIntegerValueField(.eventSourceUserData) != CaffeinateManager.jiggleEventMarker,
                  event.getIntegerValueField(.eventSourceUnixProcessID)
                    != Int64(ProcessInfo.processInfo.processIdentifier) else {
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { manager.noteUserActivity() }
            return Unmanaged.passUnretained(event)
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback, userInfo: opaqueSelf) else {
            jigglerNeedsPermission = true
            return
        }
        activityTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        activitySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoringUserActivity = CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    private func stopActivityMonitoring() {
        userActivityTimer?.invalidate()
        userActivityTimer = nil
        if let activitySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), activitySource, .commonModes) }
        if let activityTap { CFMachPortInvalidate(activityTap) }
        activitySource = nil
        activityTap = nil
        isMonitoringUserActivity = false
    }

    private func noteUserActivity() {
        guard isJiggling else { return }
        pendingPointerReturn?.cancel()
        pendingPointerReturn = nil
        isUserActive = true
        lastUserActivity = Date()
        userActivityTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, self.isJiggling else { return }
            self.isUserActive = false
            self.userActivityTimer = nil
        }
        userActivityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Local diagnostics let a remote owner verify the running process and movement.
    private func writeJigglerStatus() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Barik", isDirectory: true)
        var status: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": Date().timeIntervalSince1970,
            "enabled": isJiggling,
            "canPostEvents": CGPreflightPostEventAccess(),
            "needsPermission": jigglerNeedsPermission,
            "isMonitoringUserActivity": isMonitoringUserActivity,
            "isUserActive": isUserActive,
            "observedNudgeCount": observedNudgeCount
        ]
        if let lastUserActivity { status["lastUserActivity"] = lastUserActivity.timeIntervalSince1970 }
        if let lastObservedNudge {
            status["lastObservedNudge"] = lastObservedNudge.timeIntervalSince1970
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            try data.write(to: folder.appendingPathComponent("jiggler-status.json"), options: .atomic)
        } catch { print("Could not write mouse jiggler status: \(error)") }
    }

    func toggle() { isActive ? deactivate() : activate() }

    func activate() {
        guard !isChanging, !isActive else { return }
        isChanging = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dis", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            assertionProcess = process
            // This pre-existing, narrowly scoped permission is optional. No interactive sudo.
            ownsSleepDisabled = Self.setClamshellSleepDisabled(true)
            isActive = process.isRunning
            UserDefaults.standard.set(isActive, forKey: Self.preference)
        } catch {
            print("Keep Awake could not start: \(error)")
        }
        isChanging = false
    }

    func deactivate() {
        guard !isChanging else { return }
        stopJiggler()
        isChanging = true
        assertionProcess?.terminate()
        assertionProcess?.waitUntilExit()
        assertionProcess = nil
        if ownsSleepDisabled {
            if Self.setClamshellSleepDisabled(false) { ownsSleepDisabled = false }
            else { print("Keep Awake: could not release optional clamshell sleep setting") }
        }
        isActive = false
        UserDefaults.standard.set(false, forKey: Self.preference)
        isChanging = false
    }

    func refreshState() {
        isActive = assertionProcess?.isRunning == true
    }

    private static func setClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-k", "/usr/bin/pmset", "disablesleep", disabled ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }
}
