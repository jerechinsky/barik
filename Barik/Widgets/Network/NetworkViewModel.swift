import CoreLocation
import CoreWLAN
import Network
import SwiftUI

enum NetworkState: String {
    case connected = "Connected"
    case connectedWithoutInternet = "No Internet"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case disabled = "Disabled"
    case notSupported = "Not Supported"
}

enum WifiSignalStrength: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case unknown = "Unknown"
}

/// Unified view model for monitoring network and Wi‑Fi status.
final class NetworkStatusViewModel: NSObject, ObservableObject,
    CLLocationManagerDelegate, CWEventDelegate
{

    // Wi‑Fi comes from CoreWLAN; Ethernet and overall connectivity come from NWPathMonitor.
    @Published var wifiState: NetworkState = .disconnected
    @Published var ethernetState: NetworkState = .disconnected
    @Published private(set) var hasNetworkConnection = false

    // Wi‑Fi details obtained via CoreWLAN.
    @Published var ssid: String = "Not connected"
    @Published var rssi: Int = 0
    @Published var noise: Int = 0
    @Published var channel: String = "N/A"

    /// Computed property for signal strength.
    var wifiSignalStrength: WifiSignalStrength {
        // If Wi‑Fi is not connected or the interface is missing – return unknown.
        if ssid == "Not connected" || ssid == "No interface" {
            return .unknown
        }
        if rssi >= -50 {
            return .high
        } else if rssi >= -70 {
            return .medium
        } else {
            return .low
        }
    }

    var shouldShowWiFiIcon: Bool {
        wifiState != .notSupported && (wifiState != .disabled || !hasNetworkConnection)
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    private var timer: Timer?
    private let locationManager = CLLocationManager()
    private var wifiClient: CWWiFiClient?
    private var sleepWakeObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        startNetworkMonitoring()
        startWiFiMonitoring()
        observeSleepWake()
    }

    deinit {
        stopNetworkMonitoring()
        stopWiFiMonitoring()
        removeSleepWakeObservers()
    }

    private func observeSleepWake() {
        let sleepObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.timer?.invalidate()
            self?.timer = nil
        }

        let wakeObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startWiFiMonitoring()
        }

        sleepWakeObservers.append(contentsOf: [sleepObserver, wakeObserver])
    }

    private func removeSleepWakeObservers() {
        sleepWakeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sleepWakeObservers.removeAll()
    }

    // MARK: — NWPathMonitor for overall network status.

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.hasNetworkConnection = path.status == .satisfied

                // Ethernet
                if path.availableInterfaces.contains(where: {
                    $0.type == .wiredEthernet
                }) {
                    if path.usesInterfaceType(.wiredEthernet) {
                        switch path.status {
                        case .satisfied:
                            self.ethernetState = .connected
                        case .requiresConnection:
                            self.ethernetState = .connecting
                        default:
                            self.ethernetState = .disconnected
                        }
                    } else {
                        self.ethernetState = .disconnected
                    }
                } else {
                    self.ethernetState = .notSupported
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func stopNetworkMonitoring() {
        monitor.cancel()
    }

    // MARK: — Updating Wi‑Fi information via CoreWLAN.

    private func startWiFiMonitoring() {
        stopWiFiMonitoring()
        let client = CWWiFiClient.shared()
        wifiClient = client
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .powerDidChange)
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
        } catch {
            print("NetworkStatusViewModel: Wi-Fi event monitoring failed: \(error)")
        }

        updateWiFiInfo()

        // RSSI does not have a change notification, so sample only that value
        // occasionally while connected instead of re-reading everything every 5s.
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
            [weak self] _ in
            self?.updateSignalStrength()
        }
        timer?.tolerance = 5
    }

    private func stopWiFiMonitoring() {
        timer?.invalidate()
        timer = nil
        if let wifiClient {
            try? wifiClient.stopMonitoringEvent(with: .powerDidChange)
            try? wifiClient.stopMonitoringEvent(with: .ssidDidChange)
            try? wifiClient.stopMonitoringEvent(with: .linkDidChange)
            wifiClient.delegate = nil
            self.wifiClient = nil
        }
    }

    private func updateSignalStrength() {
        guard wifiState == .connected || wifiState == .connectedWithoutInternet,
              let interface = CWWiFiClient.shared().interface() else { return }
        rssi = interface.rssiValue()
        noise = interface.noiseMeasurement()
    }

    private func updateWiFiInfo() {
        let client = CWWiFiClient.shared()
        if let interface = client.interface() {
            guard interface.powerOn() else {
                wifiState = .disabled
                ssid = "No interface"
                rssi = 0
                noise = 0
                channel = "N/A"
                return
            }

            let isConnected = interface.interfaceMode() != .none
            wifiState = isConnected ? .connected : .disconnected
            self.ssid = interface.ssid()
                ?? (isConnected ? "Connected network" : "Not connected")
            self.rssi = interface.rssiValue()
            self.noise = interface.noiseMeasurement()
            if let wlanChannel = interface.wlanChannel() {
                let band: String
                switch wlanChannel.channelBand {
                case .bandUnknown:
                    band = "unknown"
                case .band2GHz:
                    band = "2GHz"
                case .band5GHz:
                    band = "5GHz"
                case .band6GHz:
                    band = "6GHz"
                @unknown default:
                    band = "unknown"
                }
                self.channel = "\(wlanChannel.channelNumber) (\(band))"
            } else {
                self.channel = "N/A"
            }
        } else {
            wifiState = .notSupported
            self.ssid = "No interface"
            self.rssi = 0
            self.noise = 0
            self.channel = "N/A"
        }
    }

    func toggleWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        do {
            try interface.setPower(!interface.powerOn())
            updateWiFiInfo()
        } catch {
            print("NetworkStatusViewModel: Could not change Wi-Fi power: \(error)")
        }
    }

    // MARK: — CWEventDelegate

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWiFiInfo()
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWiFiInfo()
        }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWiFiInfo()
        }
    }

    // MARK: — CLLocationManagerDelegate.

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        updateWiFiInfo()
    }
}
