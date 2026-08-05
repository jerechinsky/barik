import Foundation
import SwiftUI

struct HeadsetBatteryWidget: View {
    @EnvironmentObject private var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = HeadsetBatteryManager.shared
    @State private var widgetFrame: CGRect = .zero

    private var lowBatteryThreshold: Int {
        Int(max(1, min(
            100,
            configProvider.config["low-battery-threshold"]?.doubleValue ?? 20
        )))
    }

    private var warningColor: Color {
        Color(
            hex: configProvider.config["warning-color"]?.stringValue ?? "#D94B4B"
        ) ?? .red
    }

    var body: some View {
        if manager.isConnected {
            let batteryIsLow = (manager.batteryLevel ?? 100) <= lowBatteryThreshold

            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 0) {
                GridRow {
                    Text("H")
                    Text(manager.batteryLevel.map(String.init) ?? "--")
                }
                .foregroundStyle(batteryIsLow ? warningColor : Color.foregroundOutside)

                GridRow {
                    Text("C")
                    Text(manager.isTwoPointFourConnected ? "2G" : "—")
                }
                .foregroundStyle(Color.foregroundOutside)
                .opacity(0.7)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { widgetFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, frame in
                            widgetFrame = frame
                        }
                }
            )
            .background(.black.opacity(0.001))
            .onTapGesture {
                MenuBarPopup.show(
                    rect: widgetFrame, id: "headset-controls", colorScheme: colorScheme
                ) {
                    HeadsetControlsPopup()
                }
            }
            .help(
                manager.isTwoPointFourConnected
                    ? "\(manager.modelName) battery · 2.4 GHz connected"
                    : "Last known battery · 2.4 GHz unavailable"
            )
        }
    }
}

private struct HeadsetControlsPopup: View {
    @ObservedObject private var manager = HeadsetBatteryManager.shared
    @State private var sidetone = 0.0
    @State private var microphone = 15.0

    private let inactivityOptions = [0, 1, 5, 10, 15, 30, 45, 60, 75, 90]
    private let ledOptions = ["Off", "Low", "Medium", "High"]
    private let equalizerOptions = ["Flat", "Bass", "Focus", "Smiley"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "headset")
                    .font(.system(size: 18))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.modelName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(
                        "\(manager.batteryLevel ?? 0)% battery · "
                            + (manager.isTwoPointFourConnected
                                ? "2.4 GHz connected"
                                : "2.4 GHz unavailable")
                    )
                    .font(.system(size: 11))
                    .opacity(0.5)
                }
                Spacer()
                if manager.isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider().opacity(0.25)

            if manager.controlsAvailable {
                VStack(spacing: 12) {
                    sliderRow(
                        title: "Sidetone", value: $sidetone, range: 0...10
                    ) {
                        manager.setSidetone(Int(sidetone))
                    }
                    sliderRow(
                        title: "Microphone", value: $microphone, range: 0...15
                    ) {
                        manager.setMicrophoneLevel(Int(microphone))
                    }

                    settingRow("Auto-off") {
                        Picker("", selection: Binding(
                            get: { manager.inactivityMinutes },
                            set: { manager.setInactivityMinutes($0) }
                        )) {
                            ForEach(inactivityOptions, id: \.self) { minutes in
                                Text(minutes == 0 ? "Never" : "\(minutes) min")
                                    .tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 95)
                    }

                    settingRow("Volume limiter") {
                        Toggle("", isOn: Binding(
                            get: { manager.volumeLimiterEnabled },
                            set: { manager.setVolumeLimiter($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    settingRow("Mute LED") {
                        Picker("", selection: Binding(
                            get: { manager.muteLEDBrightness },
                            set: { manager.setMuteLEDBrightness($0) }
                        )) {
                            ForEach(ledOptions.indices, id: \.self) { level in
                                Text(ledOptions[level]).tag(level)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 95)
                    }

                    settingRow("Equalizer") {
                        Picker("", selection: Binding(
                            get: { manager.equalizerPreset },
                            set: { manager.setEqualizerPreset($0) }
                        )) {
                            ForEach(equalizerOptions.indices, id: \.self) { preset in
                                Text(equalizerOptions[preset]).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 95)
                    }
                }
                .padding(18)
                .disabled(manager.isSaving)
            } else {
                Text(manager.controlsError ?? "Loading headset controls…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(18)
            }
        }
        .frame(width: 330)
        .onAppear {
            syncSliders()
            manager.refreshConfiguration()
        }
        .onChange(of: manager.sidetoneLevel) { _, _ in syncSliders() }
        .onChange(of: manager.microphoneLevel) { _, _ in syncSliders() }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        save: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { save() }
            }
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 22, alignment: .trailing)
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private func syncSliders() {
        sidetone = Double(manager.sidetoneLevel)
        microphone = Double(manager.microphoneLevel)
    }
}

private final class HeadsetBatteryManager: ObservableObject {
    static let shared = HeadsetBatteryManager()

    @Published private(set) var batteryLevel: Int? =
        UserDefaults.standard.object(forKey: "steelseries-last-battery") as? Int
    @Published private(set) var isConnected = false
    @Published private(set) var isTwoPointFourConnected = false
    @Published private(set) var modelName = "SteelSeries Arctis Nova 5"
    @Published private(set) var controlsAvailable = false
    @Published private(set) var controlsError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var sidetoneLevel =
        UserDefaults.standard.object(forKey: "steelseries-sidetone") as? Int ?? 0
    @Published private(set) var microphoneLevel =
        UserDefaults.standard.object(forKey: "steelseries-microphone") as? Int ?? 15
    @Published private(set) var inactivityMinutes =
        UserDefaults.standard.object(forKey: "steelseries-inactivity") as? Int ?? 10
    @Published private(set) var muteLEDBrightness =
        UserDefaults.standard.object(forKey: "steelseries-mute-led") as? Int ?? 2
    @Published private(set) var volumeLimiterEnabled =
        UserDefaults.standard.object(forKey: "steelseries-volume-limiter") as? Bool
        ?? false
    @Published private(set) var equalizerPreset =
        UserDefaults.standard.object(forKey: "steelseries-equalizer-preset") as? Int
        ?? 0

    private static let executableURL = URL(
        fileURLWithPath: "/opt/homebrew/bin/headsetcontrol"
    )
    // ponytail: Nova status reads are flaky; tune these only if live probes change.
    private static let batteryProbeAttempts = 10
    private static let batteryProbeTimeoutMilliseconds = 250
    private static let failedRefreshesBeforeDisconnect = 2
    private static let commandQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var isRefreshing = false
    private var consecutiveFailedRefreshes = 0
    private var timer: Timer?

    private init() {
        #if DEBUG
        let sample = Self.snapshot(from: Data(
            #"{"device_count":1,"devices":[{"device":"SteelSeries Arctis Nova (5/5X)","product":"SteelSeries Arctis Nova 5","battery":{"status":"BATTERY_AVAILABLE","level":58}}]}"#.utf8
        ))
        assert(sample?.isDetected == true)
        assert(sample?.batteryLevel == 58)
        assert(Self.snapshot(from: Data(
            #"{"device_count":1,"devices":[{"device":"SteelSeries Arctis Nova (5/5X)","product":"SteelSeries Arctis Nova 5","battery":{"status":"BATTERY_UNAVAILABLE","level":-1}}]}"#.utf8
        ))?.batteryLevel == nil)
        assert(!Self.shouldClearConnection(afterFailedRefreshes: 1))
        assert(Self.shouldClearConnection(afterFailedRefreshes: 2))
        #endif

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in self?.refresh()
        }
        timer?.tolerance = 2
    }

    deinit {
        timer?.invalidate()
    }

    func refreshConfiguration() {
        refresh()
    }

    func setSidetone(_ value: Int) {
        sidetoneLevel = max(0, min(10, value))
        let rawValue = (sidetoneLevel * 128 + 5) / 10
        save(
            ["--sidetone", String(rawValue)],
            key: "steelseries-sidetone",
            value: sidetoneLevel
        )
    }

    func setMicrophoneLevel(_ value: Int) {
        microphoneLevel = max(0, min(15, value))
        let rawValue = (microphoneLevel * 128 + 7) / 15
        save(
            ["--microphone-volume", String(rawValue)],
            key: "steelseries-microphone",
            value: microphoneLevel
        )
    }

    func setInactivityMinutes(_ value: Int) {
        inactivityMinutes = max(0, min(90, value))
        save(
            ["--inactive-time", String(inactivityMinutes)],
            key: "steelseries-inactivity",
            value: inactivityMinutes
        )
    }

    func setMuteLEDBrightness(_ value: Int) {
        muteLEDBrightness = max(0, min(3, value))
        save(
            ["--microphone-mute-led-brightness", String(muteLEDBrightness)],
            key: "steelseries-mute-led",
            value: muteLEDBrightness
        )
    }

    func setVolumeLimiter(_ enabled: Bool) {
        volumeLimiterEnabled = enabled
        save(
            ["--volume-limiter", enabled ? "1" : "0"],
            key: "steelseries-volume-limiter",
            value: enabled
        )
    }

    func setEqualizerPreset(_ value: Int) {
        equalizerPreset = max(0, min(3, value))
        save(
            ["--equalizer-preset", String(equalizerPreset)],
            key: "steelseries-equalizer-preset",
            value: equalizerPreset
        )
    }

    private func refresh() {
        guard !isRefreshing, !isSaving else { return }
        isRefreshing = true
        probeBattery(attemptsRemaining: Self.batteryProbeAttempts)
    }

    private func probeBattery(
        attemptsRemaining: Int,
        lastSnapshot: Snapshot? = nil
    ) {
        Self.execute([
            "--battery",
            "--timeout", String(Self.batteryProbeTimeoutMilliseconds),
            "--output", "json",
        ]) { [weak self] data, status in
            guard let self else { return }
            let snapshot = status == 0
                ? data.flatMap(Self.snapshot(from:))
                : nil

            if let snapshot, !snapshot.isDetected {
                self.finishDisconnectedRefresh()
                return
            }

            if let snapshot, let batteryLevel = snapshot.batteryLevel {
                self.finishConnectedRefresh(snapshot, batteryLevel: batteryLevel)
            } else if attemptsRemaining > 1 {
                self.probeBattery(
                    attemptsRemaining: attemptsRemaining - 1,
                    lastSnapshot: snapshot ?? lastSnapshot
                )
            } else {
                self.finishFailedRefresh(snapshot ?? lastSnapshot)
            }
        }
    }

    private func finishConnectedRefresh(
        _ snapshot: Snapshot,
        batteryLevel: Int
    ) {
        isRefreshing = false
        consecutiveFailedRefreshes = 0
        isConnected = true
        modelName = snapshot.modelName
        isTwoPointFourConnected = true
        controlsAvailable = true
        controlsError = nil
        self.batteryLevel = batteryLevel
        UserDefaults.standard.set(
            batteryLevel, forKey: "steelseries-last-battery"
        )
    }

    private func finishDisconnectedRefresh() {
        isRefreshing = false
        consecutiveFailedRefreshes = 0
        isConnected = false
        isTwoPointFourConnected = false
        controlsAvailable = false
        controlsError = "HeadsetControl could not find the headset receiver"
    }

    private func finishFailedRefresh(_ snapshot: Snapshot?) {
        isRefreshing = false
        consecutiveFailedRefreshes += 1
        if let snapshot {
            isConnected = true
            modelName = snapshot.modelName
        }
        guard Self.shouldClearConnection(
            afterFailedRefreshes: consecutiveFailedRefreshes
        ) else { return }

        isConnected = false
        isTwoPointFourConnected = false
        controlsAvailable = false
        controlsError = "Controls are available when 2.4 GHz is connected"
    }

    private static func shouldClearConnection(
        afterFailedRefreshes count: Int
    ) -> Bool {
        count >= failedRefreshesBeforeDisconnect
    }

    private func save(_ arguments: [String], key: String, value: Any) {
        guard isTwoPointFourConnected, !isSaving else {
            controlsError = "Controls are available when 2.4 GHz is connected"
            return
        }

        isSaving = true
        controlsError = nil
        Self.execute(arguments) { [weak self] _, status in
            guard let self else { return }
            self.isSaving = false

            guard status == 0 else {
                self.controlsError = "The headset rejected that setting"
                return
            }
            UserDefaults.standard.set(value, forKey: key)
            self.refresh()
        }
    }

    private static func execute(
        _ arguments: [String],
        completion: @escaping (Data?, Int32) -> Void
    ) {
        commandQueue.addOperation {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    completion(data, process.terminationStatus)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, -1)
                }
            }
        }
    }

    private static func snapshot(from data: Data) -> Snapshot? {
        guard let response = try? JSONDecoder().decode(
            HeadsetControlResponse.self, from: data
        ) else { return nil }

        guard response.deviceCount > 0, let device = response.devices.first else {
            return Snapshot(
                isDetected: false,
                modelName: "SteelSeries Arctis Nova 5",
                batteryLevel: nil
            )
        }

        let level = device.battery?.level
        return Snapshot(
            isDetected: true,
            modelName: device.product ?? device.device ?? "SteelSeries headset",
            batteryLevel: level.flatMap { (0...100).contains($0) ? $0 : nil }
        )
    }

    private struct Snapshot {
        let isDetected: Bool
        let modelName: String
        let batteryLevel: Int?
    }

    private struct HeadsetControlResponse: Decodable {
        let deviceCount: Int
        let devices: [Device]

        private enum CodingKeys: String, CodingKey {
            case devices
            case deviceCount = "device_count"
        }
    }

    private struct Device: Decodable {
        let device: String?
        let product: String?
        let battery: Battery?
    }

    private struct Battery: Decodable {
        let level: Int
    }
}
