import AppKit
import Combine
import Foundation

class SpacesViewModel: ObservableObject {
    @Published var spaces: [AnySpace] = []
    private var provider: AnySpacesProvider?
    private var fallbackTimer: Timer?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var observedSpaceIds = Set<String>()
    private var observedWindowIds = Set<Int>()
    private var requestedSpaceId: String?
    private var loadGeneration: Int = 0
    private var isLoadInFlight = false
    private var reloadPending = false
    private let fallbackRefreshInterval: TimeInterval = 2

    init() {
        #if DEBUG
        assert(Self.acceptsFocus("2", requested: "2"))
        assert(!Self.acceptsFocus("1", requested: "2"))
        assert(!Self.acceptsFocus(nil, requested: "2"))
        assert(Self.acceptsFocus("1", requested: nil))
        #endif
        let runningApps = NSWorkspace.shared.runningApplications.compactMap {
            $0.localizedName?.lowercased()
        }
        if runningApps.contains("yabai") {
            let yabaiProvider = YabaiSpacesProvider()
            provider = AnySpacesProvider(yabaiProvider)
            startSignalMonitoring()
            DispatchQueue.global(qos: .utility).async {
                yabaiProvider.installFocusSignals()
            }
        } else if runningApps.contains("aerospace") {
            provider = AnySpacesProvider(AerospaceSpacesProvider())
            startFallbackMonitoring()
        } else {
            provider = nil
        }

        // Initial load
        loadSpaces()

        // Observe sleep/wake events to pause/resume monitoring
        observeSleepWake()
    }

    deinit {
        stopMonitoring()
        removeSleepWakeObservers()
    }

    private func observeSleepWake() {
        let sleepObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pauseMonitoring()
        }

        let wakeObserver = NotificationCenter.default.addObserver(
            forName: SleepWakeManager.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeMonitoring()
        }

        sleepWakeObservers.append(contentsOf: [sleepObserver, wakeObserver])
    }

    private func removeSleepWakeObservers() {
        sleepWakeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sleepWakeObservers.removeAll()
    }

    private func pauseMonitoring() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func resumeMonitoring() {
        // Restart the appropriate monitoring based on provider
        if provider is AnySpacesProvider {
            let runningApps = NSWorkspace.shared.runningApplications.compactMap {
                $0.localizedName?.lowercased()
            }
            if runningApps.contains("yabai") {
                // Resume fallback timer for yabai (Darwin notifications stay active)
                fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
                    self?.loadSpaces()
                }
                fallbackTimer?.tolerance = 0.25
            } else if runningApps.contains("aerospace") {
                startFallbackMonitoring()
            }
        }
        // Refresh spaces immediately on wake
        loadSpaces()
    }

    /// Start event-driven monitoring using yabai signals (via Darwin notifications)
    private func startSignalMonitoring() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, name, _, _ in
                guard let observer = observer else { return }
                let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    viewModel.loadSpaces()
                }
            },
            "com.barik.window_changed" as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                viewModel.refreshFocusedSpace()
            },
            "com.barik.space_changed" as CFString,
            nil,
            .deliverImmediately
        )

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            self?.loadSpaces()
        }
        fallbackTimer?.tolerance = 0.25
    }

    private func observeFocusChanges(in spaces: [AnySpace]) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        for space in spaces where observedSpaceIds.insert(space.id).inserted {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                    let spaceId = (name.rawValue as String).split(separator: ".").last.map(String.init)
                    guard let spaceId else { return }
                    DispatchQueue.main.async {
                        viewModel.requestFocusedSpace(spaceId)
                    }
                },
                "com.barik.space_requested.\(space.id)" as CFString,
                nil,
                .deliverImmediately
            )

            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                    let spaceId = (name.rawValue as String).split(separator: ".").last.map(String.init)
                    guard let spaceId else { return }
                    DispatchQueue.main.async {
                        viewModel.confirmFocusedSpace(spaceId)
                    }
                },
                "com.barik.space_changed.\(space.id)" as CFString,
                nil,
                .deliverImmediately
            )
        }

        for window in spaces.flatMap(\.windows) where observedWindowIds.insert(window.id).inserted {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                    let windowId = (name.rawValue as String).split(separator: ".").last.flatMap { Int($0) }
                    guard let windowId else { return }
                    DispatchQueue.main.async {
                        viewModel.loadGeneration &+= 1
                        var spaces = viewModel.spaces
                        for spaceIndex in spaces.indices {
                            for windowIndex in spaces[spaceIndex].windows.indices {
                                spaces[spaceIndex].windows[windowIndex].isFocused =
                                    spaces[spaceIndex].windows[windowIndex].id == windowId
                            }
                        }
                        viewModel.spaces = spaces
                    }
                },
                "com.barik.window_focused.\(window.id)" as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func refreshFocusedSpace() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let spaceId = self.provider?.getFocusedSpaceId() else { return }
            DispatchQueue.main.async {
                self.confirmFocusedSpace(spaceId)
            }
        }
    }

    private static func acceptsFocus(_ confirmed: String?, requested: String?) -> Bool {
        requested == nil || requested == confirmed
    }

    private func requestFocusedSpace(_ spaceId: String) {
        if requestedSpaceId == nil,
           spaces.contains(where: { $0.id == spaceId && $0.isFocused }) {
            return
        }
        requestedSpaceId = spaceId
        updateFocusedSpace(spaceId, reload: false)
    }

    private func confirmFocusedSpace(_ spaceId: String) {
        guard Self.acceptsFocus(spaceId, requested: requestedSpaceId) else { return }
        requestedSpaceId = nil
        updateFocusedSpace(spaceId)
    }

    private func updateFocusedSpace(_ spaceId: String, reload: Bool = true) {
        loadGeneration &+= 1
        spaces = spaces.map { space in
            AnySpace(
                id: space.id,
                isFocused: space.id == spaceId,
                windows: space.windows,
                displayIndex: space.displayIndex
            )
        }
        if reload {
            loadSpaces()
        }
    }

    /// Start fallback polling for non-yabai setups
    private func startFallbackMonitoring() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            self?.loadSpaces()
        }
        fallbackTimer?.tolerance = 0.25
    }

    private func stopMonitoring() {
        // Remove Darwin notification observers
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)

        // Stop fallback timer
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func loadSpaces() {
        guard !isLoadInFlight else {
            reloadPending = true
            return
        }

        isLoadInFlight = true
        loadGeneration &+= 1
        let gen = loadGeneration
        DispatchQueue.global(qos: .utility).async {
            let loadedSpaces = self.provider?.getSpacesWithWindows()
            let sortedSpaces = loadedSpaces?.sorted {
                let lDisplay = $0.displayIndex ?? 0
                let rDisplay = $1.displayIndex ?? 0
                if lDisplay != rDisplay { return lDisplay < rDisplay }
                if let lhs = Int($0.id), let rhs = Int($1.id) {
                    return lhs < rhs
                }
                return $0.id < $1.id
            }
            DispatchQueue.main.async {
                self.isLoadInFlight = false
                let shouldReload = self.reloadPending
                self.reloadPending = false
                defer {
                    if shouldReload {
                        self.loadSpaces()
                    }
                }

                guard gen == self.loadGeneration else { return }
                guard let sortedSpaces else {
                    self.spaces = []
                    return
                }
                let focusedSpaceId = sortedSpaces.first(where: \.isFocused)?.id
                guard Self.acceptsFocus(focusedSpaceId, requested: self.requestedSpaceId) else { return }
                self.observeFocusChanges(in: sortedSpaces)
                self.spaces = sortedSpaces
            }
        }
    }

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        requestFocusedSpace(space.id)
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusSpace(
                spaceId: space.id, needWindowFocus: needWindowFocus)
        }
    }

    func switchToWindow(_ window: AnyWindow) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusWindow(windowId: String(window.id))
        }
    }
}

class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {}
    func icon(for appName: String) -> NSImage? {
        if let cached = cache.object(forKey: appName as NSString) {
            return cached
        }
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName == appName
        }),
            let bundleURL = app.bundleURL
        {
            let icon = workspace.icon(forFile: bundleURL.path)
            cache.setObject(icon, forKey: appName as NSString)
            return icon
        }
        return nil
    }
}
