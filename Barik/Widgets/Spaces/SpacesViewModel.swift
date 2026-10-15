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
    private var pendingSpaceSwitch: (id: String, needWindowFocus: Bool)?
    private var isSpaceSwitchInFlight = false
    private var spaceSwitchWork: DispatchWorkItem?
    private var rememberedWindowBySpace: [String: Int] = [:]
    private var requestedWindowId: Int?
    private var pendingWindowActivation: (id: Int, spaceId: String, switchSpace: Bool)?
    private var isWindowActivationInFlight = false
    private var windowActivationWork: DispatchWorkItem?
    private var windowFocusRequestGeneration: Int = 0
    private var loadGeneration: Int = 0
    private var isLoadInFlight = false
    private var reloadPending = false
    private var focusRefreshWork: DispatchWorkItem?
    private let notificationPrefix: String
    // Yabai signals update focus immediately. This timer is only a safety net
    // for missed signals and structural changes, so keep its process-spawning
    // queries comfortably off the hot path.
    private let fallbackRefreshInterval: TimeInterval = 10

    init(provider injectedProvider: AnySpacesProvider? = nil, notificationPrefix: String = "com.barik") {
        self.notificationPrefix = notificationPrefix
        #if DEBUG
        assert(Self.acceptsFocus("2", requested: "2"))
        assert(!Self.acceptsFocus("1", requested: "2"))
        assert(!Self.acceptsFocus(nil, requested: "2"))
        assert(Self.acceptsFocus("1", requested: nil))
        assert(Self.acceptsWindowFocus(42, requested: 42))
        assert(!Self.acceptsWindowFocus(41, requested: 42))
        assert(Self.acceptsWindowFocus(41, requested: nil))
        #endif
        if let injectedProvider {
            provider = injectedProvider
            startSignalMonitoring()
        } else if FileManager.default.isExecutableFile(
            atPath: ConfigManager.shared.config.yabai.path
        ) {
            // yabai is a background daemon and is not reliably represented in
            // NSWorkspace.runningApplications. Select it from the configured
            // executable instead so a Barik launch never permanently leaves
            // the Spaces widget without a provider.
            let yabaiProvider = YabaiSpacesProvider()
            provider = AnySpacesProvider(yabaiProvider)
            startSignalMonitoring()
            DispatchQueue.global(qos: .utility).async {
                yabaiProvider.installSignals()
            }
        } else if FileManager.default.isExecutableFile(
            atPath: ConfigManager.shared.config.aerospace.path
        ) {
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
        if provider != nil {
            // Darwin notifications remain registered across sleep. Both
            // providers only need their fallback refresh timer restored.
            startFallbackMonitoring()
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
            "\(notificationPrefix).window_changed" as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let viewModel = Unmanaged<SpacesViewModel>.fromOpaque(observer).takeUnretainedValue()
                viewModel.refreshSpaceLayout()
            },
            "\(notificationPrefix).space_changed" as CFString,
            nil,
            .deliverImmediately
        )

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            self?.loadSpaces()
        }
        fallbackTimer?.tolerance = 1
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
                        if !viewModel.isWindowActivationInFlight && viewModel.pendingWindowActivation == nil {
                            viewModel.requestedWindowId = nil
                            viewModel.windowFocusRequestGeneration &+= 1
                        }
                        viewModel.requestFocusedSpace(spaceId)
                    }
                },
                "\(notificationPrefix).space_requested.\(space.id)" as CFString,
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
                "\(notificationPrefix).space_changed.\(space.id)" as CFString,
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
                        viewModel.confirmFocusedWindow(windowId)
                    }
                },
                "\(notificationPrefix).window_focused.\(window.id)" as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func refreshSpaceLayout() {
        DispatchQueue.main.async {
            // Space IDs are yabai's positional indices. Moving or deleting a space can
            // therefore invalidate an optimistic focus request that used the
            // old index, so the completed layout mutation becomes authoritative.
            self.requestedSpaceId = nil
            self.loadSpaces()
        }
    }

    private static func acceptsFocus(_ confirmed: String?, requested: String?) -> Bool {
        requested == nil || requested == confirmed
    }

    private static func acceptsWindowFocus(_ confirmed: Int?, requested: Int?) -> Bool {
        requested == nil || requested == confirmed
    }

    private func requestFocusedSpace(_ spaceId: String) {
        if requestedSpaceId == nil,
           spaces.contains(where: { $0.id == spaceId && $0.isFocused }) {
            return
        }
        requestedSpaceId = spaceId
        updateFocusedSpace(spaceId, reload: false)
        scheduleFocusRefresh()
    }

    private func confirmFocusedSpace(_ spaceId: String) {
        // Relative shortcuts can race their predictive query against another
        // key repeat. Always reconcile after the burst, even on a mismatch.
        scheduleFocusRefresh()
        guard Self.acceptsFocus(spaceId, requested: requestedSpaceId) else { return }
        // Keep the latest intent authoritative until the command burst drains.
        guard !isSpaceSwitchInFlight, pendingSpaceSwitch == nil else { return }
        requestedSpaceId = nil
        updateFocusedSpace(spaceId, reload: false)
    }

    private func scheduleFocusRefresh() {
        focusRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.focusRefreshWork = nil
            if self.isSpaceSwitchInFlight || self.pendingSpaceSwitch != nil {
                self.scheduleFocusRefresh()
                return
            }
            // A failed shortcut or a missed confirmation must not pin focus.
            self.requestedSpaceId = nil
            self.loadSpaces()
        }
        focusRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func updateFocusedSpace(_ spaceId: String, reload: Bool = true) {
        loadGeneration &+= 1
        let updated = spaces.map { space in
            AnySpace(
                id: space.id,
                isFocused: space.id == spaceId,
                windows: space.windows,
                displayIndex: space.displayIndex
            )
        }
        if spaces != updated { spaces = updated }
        if let windowID = rememberedWindowBySpace[spaceId],
           spaces.first(where: { $0.id == spaceId })?.windows.contains(where: { $0.id == windowID }) == true {
            updateFocusedWindow(windowID)
        }
        if reload {
            loadSpaces()
        }
    }

    private func requestFocusedWindow(_ windowId: Int) {
        windowFocusRequestGeneration &+= 1
        let requestGeneration = windowFocusRequestGeneration
        requestedWindowId = windowId
        updateFocusedWindow(windowId)

        // Recover from a failed or missed window-manager signal without
        // holding the optimistic state indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self,
                  self.windowFocusRequestGeneration == requestGeneration,
                  self.requestedWindowId == windowId else { return }
            self.requestedWindowId = nil
            self.loadSpaces()
        }
    }

    private func confirmFocusedWindow(_ windowId: Int) {
        if let targetSpace = spaces.first(where: { $0.windows.contains(where: { $0.id == windowId }) }),
           let requestedSpaceId, targetSpace.id != requestedSpaceId {
            return
        }
        guard Self.acceptsWindowFocus(windowId, requested: requestedWindowId) else {
            return
        }
        guard !isWindowActivationInFlight, pendingWindowActivation == nil else { return }
        windowFocusRequestGeneration &+= 1
        requestedWindowId = nil
        updateFocusedWindow(windowId)
    }

    private func updateFocusedWindow(_ windowId: Int) {
        if let space = spaces.first(where: { $0.windows.contains(where: { $0.id == windowId }) }) {
            rememberedWindowBySpace[space.id] = windowId
        }
        loadGeneration &+= 1
        // A focus event often follows a window closing. If it invalidates a
        // structural snapshot, replace that snapshot instead of waiting for
        // the fallback timer to remove the closed window's icon.
        if isLoadInFlight {
            reloadPending = true
        }
        var updatedSpaces = spaces
        for spaceIndex in updatedSpaces.indices {
            for windowIndex in updatedSpaces[spaceIndex].windows.indices {
                updatedSpaces[spaceIndex].windows[windowIndex].isFocused =
                    updatedSpaces[spaceIndex].windows[windowIndex].id == windowId
            }
        }
        if spaces != updatedSpaces { spaces = updatedSpaces }
    }

    /// Start fallback polling for non-yabai setups
    private func startFallbackMonitoring() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            self?.loadSpaces()
        }
        fallbackTimer?.tolerance = 1
    }

    private func stopMonitoring() {
        focusRefreshWork?.cancel()
        spaceSwitchWork?.cancel()
        windowActivationWork?.cancel()
        // Remove Darwin notification observers
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)

        // Stop fallback timer
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func loadSpaces() {
        // Every refresh request invalidates the snapshot currently being
        // loaded. If one is already in flight, its completion will be ignored
        // and the pending reload below will fetch the post-mutation layout.
        loadGeneration &+= 1
        guard !isLoadInFlight else {
            reloadPending = true
            return
        }

        isLoadInFlight = true
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
                    if shouldReload && self.focusRefreshWork == nil {
                        self.loadSpaces()
                    }
                }

                guard gen == self.loadGeneration else { return }
                // A timed-out/failed query is not an empty desktop. Keep the
                // last valid snapshot while the next signal or timer retries.
                guard let sortedSpaces else { return }
                let focusedSpaceId = sortedSpaces.first(where: \.isFocused)?.id
                guard Self.acceptsFocus(focusedSpaceId, requested: self.requestedSpaceId) else { return }
                let focusedWindowId = sortedSpaces.lazy
                    .flatMap(\.windows)
                    .first(where: \.isFocused)?
                    .id
                guard Self.acceptsWindowFocus(
                    focusedWindowId,
                    requested: self.requestedWindowId
                ) else { return }
                if self.requestedWindowId == focusedWindowId {
                    self.requestedWindowId = nil
                }
                for space in sortedSpaces {
                    if let window = space.windows.first(where: \.isFocused) {
                        self.rememberedWindowBySpace[space.id] = window.id
                    }
                }
                self.observeFocusChanges(in: sortedSpaces)
                if self.spaces != sortedSpaces { self.spaces = sortedSpaces }
            }
        }
    }

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        requestFocusedSpace(space.id)
        // A single command in flight plus one replaceable target prevents an
        // event burst from queuing obsolete switches or completing out of order.
        pendingSpaceSwitch = (space.id, needWindowFocus)
        if !isSpaceSwitchInFlight && spaceSwitchWork == nil {
            performPendingSpaceSwitch()
        }
    }

    private func performPendingSpaceSwitch() {
        spaceSwitchWork = nil
        guard !isSpaceSwitchInFlight, let target = pendingSpaceSwitch else { return }
        pendingSpaceSwitch = nil
        isSpaceSwitchInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusSpace(
                spaceId: target.id, needWindowFocus: target.needWindowFocus)
            DispatchQueue.main.async {
                self.isSpaceSwitchInFlight = false
                do {
                    // Cap burst traffic at 30 switches/sec while the visual
                    // highlight continues to follow every pointer event.
                    let work = DispatchWorkItem { [weak self] in
                        self?.performPendingSpaceSwitch()
                    }
                    self.spaceSwitchWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30, execute: work)
                }
                self.scheduleFocusRefresh()
            }
        }
    }

    func switchToWindow(_ window: AnyWindow) {
        requestFocusedWindow(window.id)
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusWindow(windowId: String(window.id))
        }
    }

    func activateWindow(_ window: AnyWindow, in space: AnySpace) {
        let needsSpaceSwitch = !space.isFocused
        requestFocusedSpace(space.id)
        requestFocusedWindow(window.id)
        pendingWindowActivation = (window.id, space.id, needsSpaceSwitch)
        if !isWindowActivationInFlight && windowActivationWork == nil {
            performPendingWindowActivation()
        }
    }

    private func performPendingWindowActivation() {
        windowActivationWork = nil
        guard let target = pendingWindowActivation, !isWindowActivationInFlight else { return }
        pendingWindowActivation = nil
        isWindowActivationInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            if target.switchSpace {
                self.provider?.focusSpace(spaceId: target.spaceId, needWindowFocus: false)
            }
            self.provider?.focusWindow(windowId: String(target.id))
            DispatchQueue.main.async {
                self.isWindowActivationInFlight = false
                let work = DispatchWorkItem { [weak self] in self?.performPendingWindowActivation() }
                self.windowActivationWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30, execute: work)
            }
        }
    }

    private func finishWindowMove(_ succeeded: Bool) {
        requestedWindowId = nil
        requestedSpaceId = nil
        if !succeeded { NSSound.beep() }
        loadSpaces()
    }

    func moveWindow(_ id: Int, to spaceID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = self.provider?.moveWindow(id, toSpace: spaceID) ?? false
            DispatchQueue.main.async { self.finishWindowMove(succeeded) }
        }
    }

    func arrangeWindow(_ id: Int, fromSpace: String, target: Int, toSpace: String, direction: String?, detachFirst: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var succeeded = true
            if fromSpace != toSpace { succeeded = self.provider?.moveWindow(id, toSpace: toSpace) ?? false }
            if succeeded { succeeded = self.provider?.arrangeWindow(id, relativeTo: target, direction: direction, detachFirst: detachFirst) ?? false }
            DispatchQueue.main.async { self.finishWindowMove(succeeded) }
        }
    }

    func reorderWindow(_ id: Int, to target: Int, orderedIDs: [Int], after: Bool) {
        guard let from = orderedIDs.firstIndex(of: id), let targetIndex = orderedIDs.firstIndex(of: target) else { return }
        let to = targetIndex + (after ? 1 : 0) - (from < targetIndex ? 1 : 0)
        guard from != to else { return }
        let step = from < to ? 1 : -1
        let neighbors = stride(from: from + step, through: to, by: step).map { orderedIDs[$0] }
        DispatchQueue.global(qos: .userInitiated).async {
            var succeeded = true
            for neighbor in neighbors {
                if self.provider?.swapWindows(id, neighbor) != true { succeeded = false; break }
            }
            DispatchQueue.main.async { self.finishWindowMove(succeeded) }
        }
    }

    func closeWindow(_ window: AnyWindow) {
        let appName = window.appName
        let isLastAppWindow = appName.map { name in
            spaces.lazy.flatMap(\.windows).filter { $0.appName == name }.count == 1
        } ?? false

        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.closeWindow(windowId: String(window.id))

            if isLastAppWindow, let appName {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSWorkspace.shared.runningApplications
                        .first {
                            $0.activationPolicy == .regular
                                && $0.localizedName == appName
                        }?
                        .terminate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.loadSpaces()
            }
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
