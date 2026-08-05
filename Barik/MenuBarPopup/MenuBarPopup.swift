import Carbon
import SwiftUI

private var panel: NSPanel?

private func handleEscapeHotKey(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MenuBarPopup.hide()
    return noErr
}

class HidingPanel: NSPanel {
    var hideTimer: Timer?

    override var canBecomeKey: Bool {
        return true
    }
}

class MenuBarPopup {
    static var lastContentIdentifier: String? = nil
    private static var escapeHotKey: EventHotKeyRef?
    private static var escapeHandler: EventHandlerRef?

    static func show<Content: View>(
        rect: CGRect, id: String, colorScheme: ColorScheme,
        @ViewBuilder content: @escaping () -> Content
    ) {
        guard let panel = panel else { return }
        registerEscapeHotKey()

        if panel.isVisible, lastContentIdentifier == id {
            hide()
            return
        }

        let isContentChange =
            panel.isVisible
            && (lastContentIdentifier != nil && lastContentIdentifier != id)
        lastContentIdentifier = id

        if let hidingPanel = panel as? HidingPanel {
            hidingPanel.hideTimer?.invalidate()
            hidingPanel.hideTimer = nil
        }

        if panel.isVisible {
            NotificationCenter.default.post(
                name: .willChangeContent, object: nil)
            let baseDuration =
                Double(Constants.menuBarPopupAnimationDurationInMilliseconds)
                / 1000.0
            let duration = isContentChange ? baseDuration / 2 : baseDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                panel.contentView = NSHostingView(
                    rootView:
                        ZStack {
                            MenuBarPopupView(colorScheme: colorScheme) {
                                content()
                            }
                            .position(x: rect.midX)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(UUID())
                )
                panel.makeKeyAndOrderFront(nil)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .willShowWindow, object: nil)
                }
            }
        } else {
            panel.contentView = NSHostingView(
                rootView:
                    ZStack {
                        MenuBarPopupView(colorScheme: colorScheme) {
                            content()
                        }
                        .position(x: rect.midX)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .willShowWindow, object: nil)
            }
        }
    }

    static func setup() {
        guard let screenFrame = NSScreen.main?.frame else { return }

        let newPanel = HidingPanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces]
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: newPanel,
            queue: .main
        ) { _ in MenuBarPopup.hide() }

        panel = newPanel
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            handleEscapeHotKey,
            1,
            &eventType,
            nil,
            &escapeHandler
        )
    }

    static func hide() {
        guard let panel, panel.isVisible else { return }
        if let hidingPanel = panel as? HidingPanel, hidingPanel.hideTimer != nil { return }
        if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
        }

        NotificationCenter.default.post(name: .willHideWindow, object: nil)
        let duration = TimeInterval(Constants.menuBarPopupAnimationDurationInMilliseconds) / 1000.0
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            panel.orderOut(nil)
            lastContentIdentifier = nil
        }
        (panel as? HidingPanel)?.hideTimer = timer
    }

    private static func registerEscapeHotKey() {
        guard escapeHotKey == nil else { return }
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: 0x4252_4B45, id: 1),
            GetApplicationEventTarget(),
            0,
            &escapeHotKey
        )
        if status != noErr {
            escapeHotKey = nil
        }
    }

    static func updateFrame() {
        guard let screenFrame = NSScreen.main?.frame else { return }
        panel?.setFrame(screenFrame, display: true)
    }
}
