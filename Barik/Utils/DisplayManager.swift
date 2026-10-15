import AppKit
import SwiftUI

/// Manages display detection and provides information about the current screen
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var isBuiltinDisplay: Bool = false
    @Published private(set) var isBuiltinDisplayOnly: Bool = false
    @Published private(set) var usesCompactMusic = false

    /// Logical points match the actual room available to menu bar widgets.
    static func compactMusicMode(isBuiltin: Bool, width: CGFloat) -> Bool {
        isBuiltin || width < 1600
    }

    @Published private(set) var hasNotch: Bool = false
    /// Horizontal notch bounds in the menu bar panel's local coordinate space.
    @Published private(set) var notchAvoidanceRange: ClosedRange<CGFloat>?
    /// Native privacy indicator center, measured from the menu bar's top-left.
    @Published private(set) var privacyIndicatorCenter: CGPoint?

    private init() {
        // NSScreen is normally ready here; update immediately to avoid one
        // frame of content under the notch, then retry after launch settles.
        updateDisplayInfo()
        DispatchQueue.main.async {
            self.updateDisplayInfo()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange() {
        DispatchQueue.main.async {
            self.updateDisplayInfo()
        }
    }

    func updateDisplayInfo() {
        let mainDisplayID = CGMainDisplayID()
        let screen = NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == mainDisplayID
        } ?? NSScreen.main

        // A reconnect can briefly expose no NSScreen. Keep the last layout
        // until AppDelegate's settling refresh finds the final display.
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        let resolvedDisplayID = screenNumber.uint32Value
        let newIsBuiltin = CGDisplayIsBuiltin(resolvedDisplayID) != 0
        let newCompactMusic = Self.compactMusicMode(isBuiltin: newIsBuiltin, width: screen.frame.width)

        // Check for notch via safe area insets (macOS 12.0+)
        var newHasNotch = false
        var newNotchAvoidanceRange: ClosedRange<CGFloat>?

        if #available(macOS 12.0, *) {
            let safeArea = screen.safeAreaInsets
            // safeAreaInsets.top > 0 indicates a notch
            newHasNotch = safeArea.top > 0

            if newHasNotch,
               let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                let lowerBound = leftArea.maxX - screen.frame.minX
                let upperBound = rightArea.minX - screen.frame.minX
                if lowerBound < upperBound {
                    newNotchAvoidanceRange = lowerBound...upperBound
                }
            }
        }

        // Update published properties
        if isBuiltinDisplay != newIsBuiltin { isBuiltinDisplay = newIsBuiltin }
        let builtinOnly = newIsBuiltin && NSScreen.screens.count == 1
        if isBuiltinDisplayOnly != builtinOnly { isBuiltinDisplayOnly = builtinOnly }
        if usesCompactMusic != newCompactMusic { usesCompactMusic = newCompactMusic }
        if hasNotch != newHasNotch { hasNotch = newHasNotch }
        if notchAvoidanceRange != newNotchAvoidanceRange { notchAvoidanceRange = newNotchAvoidanceRange }
        let indicator = nativePrivacyIndicatorCenter(on: resolvedDisplayID)
        if privacyIndicatorCenter != indicator { privacyIndicatorCenter = indicator }
    }

    private func nativePrivacyIndicatorCenter(on displayID: CGDirectDisplayID) -> CGPoint? {
        let displayBounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowName as String] as? String == "StatusIndicator",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  frame.midY - displayBounds.minY < 40
            else { continue }
            return CGPoint(x: frame.midX - displayBounds.minX,
                           y: frame.midY - displayBounds.minY)
        }
        return nil
    }
}
