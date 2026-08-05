import ApplicationServices
import SwiftUI

struct FocusedWindowWidget: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var spacesViewModel: SpacesViewModel
    let maxWidth: CGFloat
    @StateObject private var manager = FocusedWindowManager()

    var body: some View {
        let title = displayTitle

        if !title.isEmpty {
            HStack(spacing: 6) {
                Group {
                    if let icon = manager.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .shadow(color: .iconShadow, radius: 2)
                    } else {
                        Image(systemName: "app.fill").resizable()
                    }
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: 21, height: 21)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(
                        color: colorScheme == .light ? .clear : .foregroundShadowOutside,
                        radius: 3)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: maxWidth)
            .foregroundStyle(Color.foregroundOutside)
            .experimentalConfiguration(horizontalPadding: 8, cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(manager.appName), \(title)")
        }
    }

    private var displayTitle: String {
        for space in spacesViewModel.spaces {
            guard let window = space.windows.first(where: { $0.isFocused }),
                window.appName == manager.appName
            else { continue }

            let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if space.windows.filter({ $0.appName == window.appName }).count > 1,
                !title.isEmpty
            {
                return title
            }
        }
        return manager.title
    }
}

private final class FocusedWindowManager: ObservableObject {
    @Published private(set) var title = ""
    private(set) var appName = ""
    private(set) var appIcon: NSImage?

    private var processIdentifier: pid_t = 0
    private var refreshInFlight = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        #if DEBUG
        assert(Self.displayTitle(windowTitle: " Window ", appName: "App") == "Window")
        assert(Self.displayTitle(windowTitle: "  ", appName: "App") == "App")
        assert(Self.displayTitle(windowTitle: "Window", appName: "App", windowCount: 2) == "Window")
        assert(Self.displayTitle(windowTitle: "Window", appName: "App", windowCount: 1) == "App")
        #endif

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.1
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    private func refresh() {
        guard !refreshInFlight, let app = NSWorkspace.shared.frontmostApplication else { return }
        refreshInFlight = true
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Application"
        let icon = pid == processIdentifier ? appIcon : app.icon

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = Self.focusedWindowInfo(for: pid)
            let title = Self.displayTitle(
                windowTitle: Self.displayTitle(windowTitle: info.title, appName: name),
                appName: name,
                windowCount: info.windowCount
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.refresh()
                    return
                }
                guard self.processIdentifier != pid
                    || self.title != title
                else { return }
                self.processIdentifier = pid
                self.appName = name
                self.appIcon = icon
                self.title = title
            }
        }
    }

    private static func focusedWindowInfo(
        for processIdentifier: pid_t
    ) -> (title: String?, windowCount: Int) {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)

        var windowsValue: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsValue
        ) == .success ? (windowsValue as? [AXUIElement]) ?? [] : []

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                app, attribute as CFString, &windowValue
            ) == .success, let windowValue else { continue }

            if let title = windowTitle(windowValue as! AXUIElement) {
                return (title, windows.count)
            }
        }

        return (windows.lazy.compactMap(windowTitle).first, windows.count)
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleValue
        ) == .success,
            let title = titleValue as? String,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return title
    }

    private static func displayTitle(windowTitle: String?, appName: String?) -> String {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (appName ?? "") : title
    }

    private static func displayTitle(
        windowTitle: String, appName: String, windowCount: Int
    ) -> String {
        windowCount > 1 ? windowTitle : appName
    }
}
