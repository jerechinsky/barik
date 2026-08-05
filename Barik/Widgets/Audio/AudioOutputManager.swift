import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Represents an audio output device
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transportType: AudioTransportType
    let isDefault: Bool

    var isAirPods: Bool {
        name.lowercased().contains("airpods")
    }

    var icon: String {
        // Check device name for specific products
        let lowercaseName = name.lowercased()

        if lowercaseName.contains("airpods pro") {
            return "airpodspro"
        } else if lowercaseName.contains("airpods max") {
            return "airpodsmax"
        } else if lowercaseName.contains("airpods") {
            return "airpods.gen3"
        } else if lowercaseName.contains("homepod") {
            return "homepodmini"
        } else if lowercaseName.contains("beats") {
            return "beats.headphones"
        } else if lowercaseName.contains("steelseries") || lowercaseName.contains("arctis") {
            return "headset"
        } else if lowercaseName.contains("macbook") {
            return "macbook"
        }

        // Fall back to transport type
        switch transportType {
        case .bluetooth, .bluetoothLE:
            return "headphones"
        case .builtIn:
            return "speaker.wave.2.fill"
        case .usb:
            return "cable.connector"
        case .displayPort, .hdmi:
            return "display"
        case .airPlay:
            return "airplayaudio"
        default:
            return "speaker.wave.2.fill"
        }
    }

    var microphoneLetter: String {
        let lowercaseName = name.lowercased()

        if lowercaseName.contains("airpods") {
            return "A"
        }
        if lowercaseName.contains("steelseries") || lowercaseName.contains("arctis")
            || lowercaseName.contains("headset")
        {
            return "H"
        }
        if lowercaseName.contains("camera") || lowercaseName.contains("webcam") {
            return "C"
        }
        if lowercaseName.contains("macbook") {
            return "M"
        }
        if case .builtIn = transportType {
            return "M"
        }
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    var microphoneIcon: String {
        switch microphoneLetter {
        case "A": icon
        case "H": "headset"
        case "C": "video"
        default: "mic"
        }
    }
}

enum AudioTransportType {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case airPlay
    case displayPort
    case hdmi
    case unknown

    init(from transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi
        default:
            self = .unknown
        }
    }
}

/// Event-driven audio output monitor using CoreAudio
class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()

    @Published var currentDevice: AudioDevice?
    @Published var outputDevices: [AudioDevice] = []
    @Published var currentInputDevice: AudioDevice?
    @Published var inputDevices: [AudioDevice] = []
    @Published var volume: Float = 0.0
    @Published var isMuted: Bool = false

    var volumeIcon: String {
        Self.icon(for: volume, isMuted: isMuted)
    }

    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private let osdName = Notification.Name("pro.betterdisplay.BetterDisplay.osd")
    private var osdObserver: NSObjectProtocol?
    private struct VolumeListenerRegistration {
        let deviceID: AudioDeviceID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var volumeListenerBlocks: [VolumeListenerRegistration] = []
    private var pollTimer: Timer?

    private struct OSDNotification: Decodable {
        let systemIconID: Int?
        let controlTarget: String?
        let value: Double?
        let maxValue: Double?
    }

    private init() {
        #if DEBUG
        let headset = AudioDevice(
            id: 0,
            name: "SteelSeries Arctis Nova 5",
            transportType: .usb,
            isDefault: true
        )
        assert(headset.icon == "headset")
        assert(headset.microphoneLetter == "H")
        assert(Self.automaticInputLetter(for: headset) == "H")
        let airPods = AudioDevice(
            id: 0,
            name: "Alex's AirPods Pro",
            transportType: .bluetooth,
            isDefault: true
        )
        assert(airPods.microphoneLetter == "A")
        assert(Self.automaticInputLetter(for: airPods) == "A")
        let macBook = AudioDevice(
            id: 0,
            name: "MacBook Pro Speakers",
            transportType: .builtIn,
            isDefault: true
        )
        assert(macBook.icon == "macbook")
        assert(Self.automaticInputLetter(for: macBook) == "C")
        assert(Self.icon(for: 0.5, isMuted: false) == "speaker.wave.2.fill")
        assert(abs(Self.normalizedVolume(value: 42, maxValue: 100)! - 0.42) < 0.001)
        assert(
            AudioDevice(
                id: 0,
                name: "C270 HD WEBCAM",
                transportType: .usb,
                isDefault: true
            ).microphoneLetter == "C"
        )
        assert(
            AudioDevice(
                id: 0,
                name: "MacBook Pro Microphone",
                transportType: .builtIn,
                isDefault: true
            ).microphoneLetter == "M"
        )
        #endif
        osdObserver = DistributedNotificationCenter.default().addObserver(
            forName: osdName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleOSD(notification)
        }
        setupListeners()
        refreshDevices()
        refreshVolume()
        startVolumePolling()
    }

    private static func icon(for volume: Float, isMuted: Bool) -> String {
        if isMuted { return "speaker.slash.fill" }
        if volume == 0 { return "speaker.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    deinit {
        removeListeners()
        if let osdObserver {
            DistributedNotificationCenter.default().removeObserver(osdObserver)
        }
        pollTimer?.invalidate()
    }

    // MARK: - Listeners

    private func setupListeners() {
        // Listen for default output device changes
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        defaultOutputListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices(followOutput: true)
                self?.refreshVolume()
                self?.setupVolumeListeners()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultOutputListenerBlock!
        )

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        defaultInputListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            defaultInputListenerBlock!
        )

        // Set up volume listeners for current device
        setupVolumeListeners()
    }

    private func setupVolumeListeners() {
        // Remove old listeners
        removeVolumeListeners()

        let deviceID = getDefaultOutputDeviceID()
        guard deviceID != 0 else { return }

        // Listen on multiple channels (master, left, right)
        let channels: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute
        ]

        for selector in selectors {
            for channel in channels {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: channel
                )

                guard AudioObjectHasProperty(deviceID, &address) else { continue }

                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.refreshVolume()
                    }
                }

                let status = AudioObjectAddPropertyListenerBlock(
                    deviceID,
                    &address,
                    DispatchQueue.main,
                    block
                )

                if status == noErr {
                    volumeListenerBlocks.append(
                        VolumeListenerRegistration(
                            deviceID: deviceID,
                            address: address,
                            block: block
                        )
                    )
                }
            }
        }
    }

    private func removeVolumeListeners() {
        for registration in volumeListenerBlocks {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                registration.deviceID,
                &address,
                DispatchQueue.main,
                registration.block
            )
        }
        volumeListenerBlocks.removeAll()
    }

    // Fallback polling for volume changes (some devices don't notify properly)
    private func startVolumePolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshVolume()
        }
        pollTimer?.tolerance = 1
    }

    private func removeListeners() {
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let block = defaultOutputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                block
            )
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let block = defaultInputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                block
            )
        }

        removeVolumeListeners()
    }

    // MARK: - Device Discovery

    func refreshDevices(followOutput: Bool = false) {
        let defaultOutputDeviceID = getDefaultOutputDeviceID()
        let defaultInputDeviceID = getDefaultInputDeviceID()

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return }

        var outputs: [AudioDevice] = []
        var inputs: [AudioDevice] = []

        for deviceID in deviceIDs {
            if hasStreams(deviceID, scope: kAudioDevicePropertyScopeOutput),
               let device = createAudioDevice(
                   deviceID,
                   isDefault: deviceID == defaultOutputDeviceID
               ) {
                outputs.append(device)
            }
            if hasStreams(deviceID, scope: kAudioDevicePropertyScopeInput),
               let device = createAudioDevice(
                   deviceID,
                   isDefault: deviceID == defaultInputDeviceID
               ) {
                inputs.append(device)
            }
        }

        DispatchQueue.main.async {
            self.outputDevices = outputs.sorted { $0.isDefault && !$1.isDefault }
            self.currentDevice = outputs.first { $0.isDefault }
            self.inputDevices = inputs.sorted { $0.isDefault && !$1.isDefault }
            self.currentInputDevice = inputs.first { $0.isDefault }
            if followOutput {
                self.followInputToOutput()
            }
        }
    }

    private func hasStreams(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)

        return status == noErr && dataSize > 0
    }

    private func createAudioDevice(_ deviceID: AudioDeviceID, isDefault: Bool) -> AudioDevice? {
        guard let name = getDeviceName(deviceID) else { return nil }
        let transportType = getTransportType(deviceID)

        return AudioDevice(
            id: deviceID,
            name: name,
            transportType: transportType,
            isDefault: isDefault
        )
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        getDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        getDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    private func getDefaultDeviceID(
        _ selector: AudioObjectPropertySelector
    ) -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return deviceID
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )

        return status == noErr ? name as String? : nil
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> AudioTransportType {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &transportType
        )

        return status == noErr ? AudioTransportType(from: transportType) : .unknown
    }

    // MARK: - Volume Control

    func refreshVolume() {
        guard let deviceID = currentDevice?.id ?? Optional(getDefaultOutputDeviceID()) else { return }

        // Get volume
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try master channel first
        if !AudioObjectHasProperty(deviceID, &volumeAddress) {
            volumeAddress.mElement = 1  // Try channel 1
        }

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)

        if AudioObjectHasProperty(deviceID, &volumeAddress) {
            AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &dataSize, &volume)
        }

        // Get mute state
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var muted: UInt32 = 0
        dataSize = UInt32(MemoryLayout<UInt32>.size)

        if AudioObjectHasProperty(deviceID, &muteAddress) {
            AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &dataSize, &muted)
        }

        DispatchQueue.main.async {
            self.volume = volume
            self.isMuted = muted != 0
        }
    }

    private func handleOSD(_ notification: Notification) {
        guard let object = notification.object as? String,
              let osd = try? JSONDecoder().decode(
                  OSDNotification.self,
                  from: Data(object.utf8)
              ),
              osd.systemIconID == 3
                  || osd.systemIconID == 4
                  || osd.controlTarget?.lowercased().contains("volume") == true
        else { return }

        if osd.systemIconID == 4 {
            isMuted = true
        } else if let value = osd.value,
                  let maxValue = osd.maxValue,
                  let volume = Self.normalizedVolume(value: value, maxValue: maxValue) {
            self.volume = volume
            isMuted = false
        }
    }

    private static func normalizedVolume(value: Double, maxValue: Double) -> Float? {
        guard value.isFinite, maxValue.isFinite, maxValue > 0 else { return nil }
        return Float(min(max(value / maxValue, 0), 1))
    }

    func setVolume(_ newVolume: Float) {
        guard let deviceID = currentDevice?.id else { return }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &volumeAddress) {
            volumeAddress.mElement = 1
        }

        var volume = newVolume
        let dataSize = UInt32(MemoryLayout<Float32>.size)

        AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, dataSize, &volume)

        DispatchQueue.main.async {
            self.volume = newVolume
        }
    }

    func setMuted(_ muted: Bool) {
        guard let deviceID = currentDevice?.id else { return }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &muteAddress) else { return }

        var muteValue: UInt32 = muted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)

        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, dataSize, &muteValue)

        DispatchQueue.main.async {
            self.isMuted = muted
        }
    }

    // MARK: - Device Switching

    func setDefaultOutputDevice(_ device: AudioDevice) {
        setDefaultDevice(device, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func setDefaultInputDevice(_ device: AudioDevice) {
        setDefaultDevice(device, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func toggleHeadsetCameraInput() {
        selectInput(microphoneLetter: currentInputDevice?.microphoneLetter == "H" ? "C" : "H")
    }

    private func followInputToOutput() {
        guard let currentDevice else { return }
        selectInput(microphoneLetter: Self.automaticInputLetter(for: currentDevice))
    }

    private static func automaticInputLetter(for output: AudioDevice) -> String {
        ["H", "A"].contains(output.microphoneLetter) ? output.microphoneLetter : "C"
    }

    private func selectInput(microphoneLetter: String) {
        guard currentInputDevice?.microphoneLetter != microphoneLetter,
              let device = inputDevices.first(where: { $0.microphoneLetter == microphoneLetter })
        else { return }
        setDefaultInputDevice(device)
    }

    private func setDefaultDevice(
        _ device: AudioDevice,
        selector: AudioObjectPropertySelector
    ) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = device.id
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &deviceID
        )
    }
}
