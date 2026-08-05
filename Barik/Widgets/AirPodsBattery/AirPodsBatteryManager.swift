import Combine
import Darwin
import Foundation

class AirPodsBatteryManager: ObservableObject {
    static let shared = AirPodsBatteryManager()

    @Published var leftBattery: Int?
    @Published var rightBattery: Int?
    @Published var caseBattery: Int?
    @Published var isConnected: Bool = false

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var updateInFlight = false
    private var updatePending = false

    private init() {
        AudioOutputManager.shared.$currentDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.handleDeviceChange(device: device)
            }
            .store(in: &cancellables)

        startPolling()
    }

    private func handleDeviceChange(device: AudioDevice?) {
        let nowConnected = device?.isAirPods ?? false

        if nowConnected && !isConnected {
            isConnected = true
            updateBattery()
        } else if nowConnected && isConnected {
            // Still connected, refresh
            updateBattery()
        } else if !nowConnected {
            updatePending = false
            isConnected = false
            leftBattery = nil
            rightBattery = nil
            caseBattery = nil
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            self.updateBattery()
        }
    }

    func updateBattery() {
        guard isConnected else { return }
        guard !updateInFlight else {
            updatePending = true
            return
        }

        updateInFlight = true
        let deviceName = AudioOutputManager.shared.currentDevice?.name ?? ""

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.querySystemProfiler(deviceName: deviceName)

            DispatchQueue.main.async {
                guard let self else { return }
                self.updateInFlight = false
                let shouldRefreshAgain = self.updatePending
                self.updatePending = false

                if self.isConnected {
                    self.leftBattery = result.left
                    self.rightBattery = result.right
                    self.caseBattery = result.caseLevel
                }
                if shouldRefreshAgain {
                    self.updateBattery()
                }
            }
        }
    }

    private static func querySystemProfiler(
        deviceName: String
    ) -> (left: Int?, right: Int?, caseLevel: Int?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let completion = DispatchSemaphore(value: 0)
        let dataLock = NSLock()
        var outputData = Data()
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            dataLock.lock()
            outputData.append(chunk)
            dataLock.unlock()
        }
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return (nil, nil, nil)
        }

        var finished = completion.wait(timeout: .now() + 8) == .success
        if !finished {
            process.terminate()
            finished = completion.wait(timeout: .now() + 0.5) == .success
        }
        if !finished, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            finished = completion.wait(timeout: .now() + 0.5) == .success
        }

        guard finished else {
            readHandle.readabilityHandler = nil
            return (nil, nil, nil)
        }

        readHandle.readabilityHandler = nil
        let tail = readHandle.readDataToEndOfFile()
        dataLock.lock()
        outputData.append(tail)
        dataLock.unlock()

        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8) else {
            return (nil, nil, nil)
        }

        return parseBatteryFromProfiler(output: output, deviceName: deviceName)
    }

    private static func parseBatteryFromProfiler(
        output: String, deviceName: String
    ) -> (left: Int?, right: Int?, caseLevel: Int?) {
        let lines = output.components(separatedBy: "\n")

        // Find the section matching the connected AirPods device name
        var inTargetSection = false
        var left: Int?
        var right: Int?
        var caseLevel: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Device names end with ":"
            if trimmed.hasSuffix(":") && !trimmed.contains("Battery")
                && !trimmed.contains("Version")
            {
                let name = String(trimmed.dropLast()).trimmingCharacters(
                    in: .whitespaces)
                if name.lowercased().contains("airpods") {
                    // Check if this matches the connected device
                    let nameMatch =
                        deviceName.isEmpty
                        || name.lowercased().contains(
                            deviceName.lowercased())
                        || deviceName.lowercased().contains(
                            name.lowercased())
                    inTargetSection = nameMatch
                } else {
                    // Entered a different device section
                    if inTargetSection && (left != nil || right != nil) {
                        break
                    }
                    inTargetSection = false
                }
                continue
            }

            guard inTargetSection else { continue }

            if trimmed.hasPrefix("Left Battery Level:") {
                left = parsePercentage(from: trimmed)
            } else if trimmed.hasPrefix("Right Battery Level:") {
                right = parsePercentage(from: trimmed)
            } else if trimmed.hasPrefix("Case Battery Level:") {
                caseLevel = parsePercentage(from: trimmed)
            }
        }

        return (left, right, caseLevel)
    }

    private static func parsePercentage(from line: String) -> Int? {
        let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return Int(digits)
    }
}
