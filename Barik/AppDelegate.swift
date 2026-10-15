import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var backgroundPanel: NSPanel?
    private var menuBarPanel: NSPanel?
    private var caffeinatePanel: NSPanel?
    private var comparisonPanel: NSPanel?
    private var comparisonDismissed = false
    private var displayRefreshWork: [DispatchWorkItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = ConfigManager.shared.initError {
            showFatalConfigError(message: error)
            return
        }

        // Initialize sleep/wake manager to pause services during sleep
        _ = SleepWakeManager.shared

        // Show "What's New" banner if the app version is outdated
        if !VersionChecker.isLatestVersion() {
            VersionChecker.updateVersionFile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(
                    name: Notification.Name("ShowWhatsNewBanner"), object: nil)
            }
        }

        MenuBarPopup.setup()
        refreshDisplayLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(hideComparison), name: Notification.Name("HideStackMarkerComparison"), object: nil)

        // Explicit local launch request; ordinary launches keep the jiggler off.
        if ProcessInfo.processInfo.arguments.contains("--mouse-jiggler") {
            CaffeinateManager.shared.toggleJiggler()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange(_:)),
            name: SleepWakeManager.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenParametersDidChange(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let components = URLComponents(
                url: url, resolvingAgainstBaseURL: false),
                components.scheme == "barik",
                components.host == "focus",
                let task = components.queryItems?.first(where: { $0.name == "task" })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !task.isEmpty,
                let durationValue = components.queryItems?
                    .first(where: { $0.name == "duration" })?.value,
                let duration = TimeInterval(durationValue),
                duration > 0,
                duration <= 24 * 60 * 60
            else { continue }

            FocusTimerManager.shared.start(
                name: String(task.prefix(200)), duration: duration)
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        refreshDisplayLayout()
    }

    private func refreshDisplayLayout() {
        // macOS may send the first event before resolution/main-display changes
        // settle. Cancel the previous batch so hot-plug bursts stay bounded.
        displayRefreshWork.forEach { $0.cancel() }
        displayRefreshWork.removeAll()
        setupPanels()
        MenuBarPopup.updateFrame()
        for delay in [0.5, 2.0, 5.0] {
            let work = DispatchWorkItem { [weak self] in
                self?.setupPanels()
                MenuBarPopup.updateFrame()
            }
            displayRefreshWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Configures and displays the background and menu bar panels.
    private func setupPanels() {
        DisplayManager.shared.updateDisplayInfo()
        let screenFrame = CGDisplayBounds(CGMainDisplayID())
        setupPanel(
            &backgroundPanel,
            frame: screenFrame,
            level: Int(CGWindowLevelForKey(.desktopWindow)),
            hostingRootView: AnyView(BackgroundView()))
        setupPanel(
            &menuBarPanel,
            frame: screenFrame,
            level: Int(CGWindowLevelForKey(.backstopMenu)),
            hostingRootView: AnyView(MenuBarView()))
        setupCaffeinatePanel(displayFrame: screenFrame)
        if ProcessInfo.processInfo.arguments.contains("--stack-marker-comparison"), !comparisonDismissed,
           let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }) {
            let height = ConfigManager.shared.config.experimental.foreground.resolveHeight() + 1
            let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height * 2 - 10, width: screen.frame.width, height: height)
            setupPanel(&comparisonPanel, frame: frame,
                       level: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                       hostingRootView: AnyView(ZStack(alignment: .top) {
                           BackgroundView()
                           MenuBarView().environment(\.stackUsesSliderMarker, true)
                       }.frame(height: height)))
            comparisonPanel?.ignoresMouseEvents = true
        }
    }

    private func setupCaffeinatePanel(displayFrame: CGRect) {
        let indicator = DisplayManager.shared.privacyIndicatorCenter
            ?? CGPoint(x: displayFrame.width - (DisplayManager.shared.isBuiltinDisplay ? 16 : 8),
                       y: DisplayManager.shared.isBuiltinDisplay ? 16 : 8)
        let spacing: CGFloat = DisplayManager.shared.isBuiltinDisplay ? 10 : 8
        let width: CGFloat = 16
        let builtin = DisplayManager.shared.isBuiltinDisplay
        let height = spacing * (builtin ? 3 : 2)
        let centerX = indicator.x
        // Notebook: straddle the inset privacy dot. External: both dots below it.
        let top = builtin ? max(0, indicator.y - height / 2) : indicator.y + spacing / 2
        let frame = CGRect(
            x: displayFrame.minX + centerX - width / 2,
            y: displayFrame.maxY - top - height,
            width: width,
            height: height
        )
        if let caffeinatePanel {
            caffeinatePanel.setFrame(frame, display: true)
            caffeinatePanel.contentView = NSHostingView(rootView:
                CaffeinateWidget(dotSpacing: spacing, reservesPrivacySlot: builtin).frame(width: width, height: height))
            return
        }
        setupPanel(
            &caffeinatePanel,
            frame: frame,
            level: Int(CGWindowLevelForKey(.statusWindow)) + 1,
            hostingRootView: AnyView(CaffeinateWidget(dotSpacing: spacing, reservesPrivacySlot: builtin)
                .frame(width: width, height: height)))
    }

    @objc private func hideComparison() {
        comparisonDismissed = true
        comparisonPanel?.orderOut(nil)
        comparisonPanel = nil
    }

    /// Sets up an NSPanel with the provided parameters.
    private func setupPanel(
        _ panel: inout NSPanel?, frame: CGRect, level: Int,
        hostingRootView: AnyView
    ) {
        if let existingPanel = panel {
            existingPanel.setFrame(frame, display: true)
            return
        }

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = NSWindow.Level(rawValue: level)
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces]
        newPanel.contentView = NSHostingView(rootView: hostingRootView)
        newPanel.orderFront(nil)
        panel = newPanel
    }
    
    private func showFatalConfigError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Configuration Error"
        alert.informativeText = "\(message)\n\nPlease double check ~/.barik-config.toml and try again."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
