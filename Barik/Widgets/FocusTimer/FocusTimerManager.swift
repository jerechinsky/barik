import AppKit
import Combine
import Foundation

class FocusTimerManager: ObservableObject {
    static let shared = FocusTimerManager()

    @Published var taskName: String = ""
    @Published var totalDuration: TimeInterval = 0
    @Published var remainingTime: TimeInterval = 0
    @Published var isRunning: Bool = false
    @Published var isFinished: Bool = false
    @Published var isFlashing: Bool = false
    @Published var isActive: Bool = false
    @Published var isDismissing: Bool = false
    @Published var isBouncing: Bool = false
    @Published var bouncePhase: Bool = false
    @Published private(set) var isCometParking: Bool = false

    private var lastTaskName: String = ""
    private var bounceDelayWork: DispatchWorkItem?
    private var bounceTimer: AnyCancellable?
    private var lastDuration: TimeInterval = 0

    private var countdownTimer: AnyCancellable?
    private var flashTimer: AnyCancellable?
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var cmdWatchSource: DispatchSourceFileSystemObject?
    private var cometPhaseAnchor: Double = 0
    private var cometAnchorDate = Date()
    private var cometParkingTargetPhase: Double = 0
    private var cometParkingWork: DispatchWorkItem?
    private let cometParkingDuration: TimeInterval = 0.7

    private let inputFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".barik-focus-timer")
    private let cmdFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".barik-focus-timer-cmd")

    private init() {
        assert(abs(Self.cometSpeedMultiplier(progress: 1) - 0.8) < 0.0001 &&
               abs(Self.cometSpeedMultiplier(progress: 0) - 1.5) < 0.0001)
        setupFileWatcher()
        setupCmdWatcher()
    }

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return remainingTime / totalDuration
    }

    func start(name: String, duration: TimeInterval) {
        stopCountdown()
        stopFlash()
        stopBounce()
        lastTaskName = name
        lastDuration = duration
        taskName = name
        totalDuration = duration
        remainingTime = duration
        isFinished = false
        isFlashing = false
        isActive = true
        resetCometClock()
        startCountdown()
    }

    func restart() {
        guard !taskName.isEmpty else { return }
        start(name: taskName, duration: totalDuration)
        cometAnchorDate = Date().addingTimeInterval(1)
    }

    // Used by widget click (pause/resume only) and toggle script
    func togglePauseResume() {
        if !isActive {
            guard !lastTaskName.isEmpty else { return }
            start(name: lastTaskName, duration: lastDuration)
        } else if isFinished {
            restart()
        } else if isRunning {
            pauseCountdown()
        } else {
            resumeCountdown()
        }
    }

    func complete() {
        if let url = URL(string: "raycast://extensions/raycast/raycast/confetti") {
            NSWorkspace.shared.open(url)
        }
        animateDismiss()
    }

    func cancel() {
        guard isActive, !isDismissing else { return }
        stopCountdown()
        stopFlash()
        stopBounce()
        animateDismiss()
    }

    func dismiss() {
        stopCountdown()
        stopFlash()
        stopBounce()
        isDismissing = false
        isActive = false
        isFinished = false
        isRunning = false
        taskName = ""
    }

    private func animateDismiss() {
        isDismissing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.dismiss()
        }
    }

    private func pauseCountdown() {
        stopCountdown(parkCometIfHidden: true)
    }

    private func resumeCountdown() {
        guard isActive && !isFinished else { return }
        startCountdown()
    }

    private func startCountdown() {
        stopCometParking()
        cometAnchorDate = Date()
        isRunning = true
        countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.remainingTime > 0 {
                    self.settleCometClock()
                    self.remainingTime -= 1
                } else {
                    self.finish()
                }
            }
    }

    private func stopCountdown(parkCometIfHidden: Bool = false) {
        if isCometParking {
            stopCometParking()
        } else {
            settleCometClock()
        }
        countdownTimer?.cancel()
        countdownTimer = nil
        isRunning = false
        if parkCometIfHidden && cometPhaseAnchor >= 0.94 {
            startCometParking()
        }
    }

    func cometPhase(at date: Date) -> Double {
        if isCometParking {
            let progress = min(max(date.timeIntervalSince(cometAnchorDate) / cometParkingDuration, 0), 1)
            return cometParkingTargetPhase * (1 - pow(1 - progress, 3))
        }
        let speedMultiplier = Self.cometSpeedMultiplier(progress: progress)
        let elapsed = isRunning ? max(0, date.timeIntervalSince(cometAnchorDate)) : 0
        return (cometPhaseAnchor + elapsed * speedMultiplier / 2.2)
            .truncatingRemainder(dividingBy: 1)
    }

    private static func cometSpeedMultiplier(progress: Double) -> Double {
        0.8 + 0.7 * min(max(1 - progress, 0), 1)
    }

    private func resetCometClock() {
        stopCometParking()
        cometPhaseAnchor = 0
        cometAnchorDate = Date()
    }

    private func settleCometClock() {
        let now = Date()
        cometPhaseAnchor = cometPhase(at: now)
        cometAnchorDate = now
    }

    private func startCometParking() {
        cometPhaseAnchor = 0
        cometParkingTargetPhase = Double.random(in: 0.18...0.47)
        cometAnchorDate = Date()
        isCometParking = true

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCometParking else { return }
            self.cometPhaseAnchor = self.cometParkingTargetPhase
            self.cometAnchorDate = Date()
            self.isCometParking = false
            self.cometParkingWork = nil
        }
        cometParkingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cometParkingDuration, execute: work)
    }

    private func stopCometParking() {
        guard isCometParking else { return }
        let now = Date()
        cometPhaseAnchor = cometPhase(at: now)
        cometAnchorDate = now
        isCometParking = false
        cometParkingWork?.cancel()
        cometParkingWork = nil
    }

    private func finish() {
        stopCountdown()
        isFinished = true
        isRunning = false
        startFlash()
        scheduleBounce()
        FocusTimerToast.shared.show(taskName: taskName)
    }

    private func startFlash() {
        var toggle = true
        flashTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isFlashing = toggle
                toggle.toggle()
            }
    }

    private func stopFlash() {
        flashTimer?.cancel()
        flashTimer = nil
        isFlashing = false
    }

    private func scheduleBounce() {
        bounceDelayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.startBounce()
            }
        }
        bounceDelayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func startBounce() {
        guard isFinished else { return }
        isBouncing = true
        bounceTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.bouncePhase.toggle()
            }
    }

    private func stopBounce() {
        bounceDelayWork?.cancel()
        bounceDelayWork = nil
        bounceTimer?.cancel()
        bounceTimer = nil
        isBouncing = false
        bouncePhase = false
    }

    private func setupFileWatcher() {
        if !FileManager.default.fileExists(atPath: inputFile.path) {
            FileManager.default.createFile(atPath: inputFile.path, contents: nil)
        }

        let fileDescriptor = open(inputFile.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileWatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global()
        )

        fileWatchSource?.setEventHandler { [weak self] in
            self?.readInputFile()
        }

        fileWatchSource?.setCancelHandler {
            close(fileDescriptor)
        }

        fileWatchSource?.resume()
    }

    private func setupCmdWatcher() {
        if !FileManager.default.fileExists(atPath: cmdFile.path) {
            FileManager.default.createFile(atPath: cmdFile.path, contents: nil)
        }

        let fileDescriptor = open(cmdFile.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        cmdWatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global()
        )

        cmdWatchSource?.setEventHandler { [weak self] in
            self?.readCmdFile()
        }

        cmdWatchSource?.setCancelHandler {
            close(fileDescriptor)
        }

        cmdWatchSource?.resume()
    }

    private func readCmdFile() {
        guard let cmd = try? String(contentsOf: cmdFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cmd.isEmpty else { return }

        DispatchQueue.main.async {
            switch cmd {
            case "toggle": self.togglePauseResume()
            case "pause": if self.isRunning { self.pauseCountdown() }
            case "resume": if !self.isRunning { self.resumeCountdown() }
            case "complete":
                self.complete()
            case "cancel":
                self.cancel()
            default: break
            }
        }
    }

    private func readInputFile() {
        guard let content = try? String(contentsOf: inputFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty else { return }

        // Format: "taskname|duration_in_seconds"
        let parts = content.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let seconds = TimeInterval(parts[1]),
              seconds > 0 else { return }

        let name = String(parts[0])

        DispatchQueue.main.async {
            self.start(name: name, duration: seconds)
        }
    }
}
