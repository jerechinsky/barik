// ABOUTME: Monitors the dedicated OnePlus 7 ADB connection and exposes safe device actions
// ABOUTME: Every command is pinned to the phone serial so other Android devices are untouched

import AppKit
import Foundation

@MainActor
final class OnePlusManager: ObservableObject {
    static let shared = OnePlusManager()

    static let serial = "12a76baa"
    static let modelName = "OnePlus 7"

    @Published private(set) var isConnected = false
    @Published private(set) var isScreenless = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastMessage = "Waiting for OnePlus 7"

    private let adb = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/oneplus-adb").path
    private let screenless = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/oneplus-screenless").path
    private let raffle = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/oneplus-raffle").path
    private let captureFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/OnePlus Captures", isDirectory: true)
    private var timer: Timer?
    private var refreshInFlight = false

    var hasRaffleScript: Bool {
        FileManager.default.isExecutableFile(atPath: raffle)
    }

    var helpText: String {
        guard isConnected else { return "OnePlus 7 is not connected over ADB" }
        let display = isScreenless ? "OLED off" : "OLED on"
        return "OnePlus 7 connected - \(display). Click to toggle. Right-click for controls."
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.35
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task.detached { [adb] in
            let connected = Self.run(adb, ["get-state"], timeout: 2).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines) == "device"
            let screenless = connected && Self.isScreenlessProcessRunning()
            await MainActor.run {
                self.isConnected = connected
                self.isScreenless = screenless
                self.refreshInFlight = false
                if connected, self.lastMessage == "Waiting for OnePlus 7" {
                    self.lastMessage = "Connected"
                }
            }
        }
    }

    func toggleScreen() {
        guard isConnected else { return }
        if isScreenless {
            turnScreenOn()
        } else {
            turnScreenOff()
        }
    }

    func turnScreenOff() {
        perform(message: "OLED turned off") { [screenless] in
            let result = Self.run(screenless, ["off"], timeout: 4)
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func turnScreenOn() {
        perform(message: "OLED turned on") { [screenless, adb] in
            let result = Self.run(screenless, ["auto"], timeout: 4)
            if result.succeeded {
                _ = Self.run(adb, ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 4)
            }
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func useAutomaticDisplayMode() {
        perform(message: "20-minute display timer enabled") { [screenless] in
            let result = Self.run(screenless, ["auto"], timeout: 4)
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func restartScreenlessService() {
        perform(message: "Screenless service restarted") { [screenless] in
            let result = Self.run(screenless, ["restart"], timeout: 8)
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func launchSkipPay() {
        perform(message: "Skip Pay opened") { [screenless, adb] in
            Self.wakeForAutomation(screenless: screenless, adb: adb)
            let result = Self.run(
                adb,
                ["shell", "monkey", "-p", "cz.mallpay", "-c", "android.intent.category.LAUNCHER", "1"],
                timeout: 8
            )
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func goHome() {
        perform(message: "Phone returned Home") { [screenless, adb] in
            Self.wakeForAutomation(screenless: screenless, adb: adb)
            let result = Self.run(adb, ["shell", "input", "keyevent", "KEYCODE_HOME"], timeout: 4)
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func runRaffle() {
        guard hasRaffleScript else {
            lastMessage = "Raffle script is not installed yet"
            NSSound.beep()
            return
        }
        perform(message: "Raffle automation started") { [screenless, adb, raffle] in
            Self.wakeForAutomation(screenless: screenless, adb: adb)
            let result = Self.run(raffle, ["run-now"], timeout: 5)
            return result.succeeded ? nil : result.errorSummary
        }
    }

    func takeScreenshot() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached { [screenless, adb, captureFolder] in
            do {
                Self.wakeForAutomation(screenless: screenless, adb: adb)
                try FileManager.default.createDirectory(
                    at: captureFolder,
                    withIntermediateDirectories: true
                )
                let result = Self.run(adb, ["exec-out", "screencap", "-p"], timeout: 10)
                guard result.succeeded, !result.data.isEmpty else {
                    throw OnePlusError.command(result.errorSummary)
                }
                let destination = captureFolder.appendingPathComponent(
                    "OnePlus-\(Self.fileTimestamp()).png"
                )
                try result.data.write(to: destination, options: .atomic)
                await MainActor.run {
                    self.isBusy = false
                    self.lastMessage = "Screenshot saved"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastMessage = "Screenshot failed: \(error.localizedDescription)"
                    NSSound.beep()
                }
            }
        }
    }

    func saveUISnapshot() {
        perform(message: "UI snapshot saved", revealCaptureFolder: true) { [screenless, adb, captureFolder] in
            do {
                Self.wakeForAutomation(screenless: screenless, adb: adb)
                try FileManager.default.createDirectory(
                    at: captureFolder,
                    withIntermediateDirectories: true
                )
                let remote = "/sdcard/barik-oneplus-ui.xml"
                let dump = Self.run(adb, ["shell", "uiautomator", "dump", remote], timeout: 10)
                guard dump.succeeded else { return dump.errorSummary }
                let destination = captureFolder.appendingPathComponent(
                    "OnePlus-UI-\(Self.fileTimestamp()).xml"
                )
                let pull = Self.run(adb, ["pull", remote, destination.path], timeout: 10)
                return pull.succeeded ? nil : pull.errorSummary
            } catch {
                return error.localizedDescription
            }
        }
    }

    func openCaptureFolder() {
        try? FileManager.default.createDirectory(
            at: captureFolder,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(captureFolder)
    }

    func copyADBCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("oneplus-adb ", forType: .string)
        lastMessage = "ADB command copied"
    }

    private func perform(
        message: String,
        revealCaptureFolder: Bool = false,
        operation: @escaping @Sendable () -> String?
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached {
            let error = operation()
            await MainActor.run {
                self.isBusy = false
                if let error, !error.isEmpty {
                    self.lastMessage = error
                    NSSound.beep()
                } else {
                    self.lastMessage = message
                    if revealCaptureFolder {
                        self.openCaptureFolder()
                    }
                }
                self.refresh()
            }
        }
    }

    nonisolated private static func isScreenlessProcessRunning() -> Bool {
        let result = run(
            "/usr/bin/pgrep",
            ["-f", "scrcpy.*--serial 12a76baa.*--turn-screen-off"],
            timeout: 2
        )
        return result.succeeded
    }

    nonisolated private static func wakeForAutomation(screenless: String, adb: String) {
        _ = run(screenless, ["auto"], timeout: 4)
        _ = run(adb, ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 4)
    }

    nonisolated private static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stderrURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
              let stderr = try? FileHandle(forWritingTo: stderrURL) else {
            return CommandResult(data: Data(), stderr: "Unable to capture command output", status: -1)
        }
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return CommandResult(data: Data(), stderr: error.localizedDescription, status: -1)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return CommandResult(data: Data(), stderr: "Command timed out", status: -2)
        }

        try? stdout.synchronize()
        try? stderr.synchronize()
        let data = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
        return CommandResult(
            data: data,
            stderr: String(data: errorData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    nonisolated private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct CommandResult: Sendable {
    let data: Data
    let stderr: String
    let status: Int32

    var succeeded: Bool { status == 0 }
    var stdout: String { String(data: data, encoding: .utf8) ?? "" }
    var errorSummary: String {
        let value = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Command failed (\(status))" : value
    }
}

private enum OnePlusError: LocalizedError {
    case command(String)

    var errorDescription: String? {
        switch self {
        case .command(let message): message
        }
    }
}
