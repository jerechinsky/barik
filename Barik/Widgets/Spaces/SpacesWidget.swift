import CoreText
import SwiftUI

/// Route only gestures that begin on a bar icon before global mouse-gesture
/// utilities defer or remap button-down events. All events elsewhere pass through untouched.
private final class BarWindowRightDragRouter {
    static let shared = BarWindowRightDragRouter()
    private let views = NSHashTable<WindowIconPointerHandler.PointerView>.weakObjects()
    private weak var active: WindowIconPointerHandler.PointerView?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func register(_ view: WindowIconPointerHandler.PointerView) {
        views.add(view)
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let router = Unmanaged<BarWindowRightDragRouter>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                router.active?.cancelRightDrag()
                router.active = nil
                if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return router.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let tap else { return } // AppKit handling remains available without event-tap access.
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let point = CGPoint(x: event.location.x, y: screen.frame.maxY - event.location.y)
        if type == .rightMouseDown || type == .leftMouseDown {
            active = views.allObjects.first { view in
                guard let window = view.window, window.isVisible, !window.ignoresMouseEvents,
                      !view.isHiddenOrHasHiddenAncestor, let root = window.contentView else { return false }
                let windowPoint = window.convertPoint(fromScreen: point)
                guard view.visibleRect.contains(view.convert(windowPoint, from: nil)) else { return false }
                // SwiftUI can retain off-layout representables with overlapping
                // frames. Use AppKit's actual hit target, not registry order.
                guard let hit = root.hitTest(root.convert(windowPoint, from: nil)) else { return false }
                return hit === view || hit.isDescendant(of: view)
            }
        }
        guard let view = active, let window = view.window else { return false }
        let eventType: NSEvent.EventType
        switch type {
        case .leftMouseDown: eventType = .leftMouseDown
        case .leftMouseDragged: eventType = .leftMouseDragged
        case .leftMouseUp: eventType = .leftMouseUp
        case .rightMouseDown: eventType = .rightMouseDown
        case .rightMouseDragged: eventType = .rightMouseDragged
        default: eventType = .rightMouseUp
        }
        guard let native = NSEvent.mouseEvent(with: eventType, location: window.convertPoint(fromScreen: point),
                                              modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: max(1, Int(event.getIntegerValueField(.mouseEventClickState))), pressure: 1) else { return false }
        switch type {
        case .leftMouseDown: view.mouseDown(with: native)
        case .leftMouseDragged: view.mouseDragged(with: native)
        case .leftMouseUp:
            view.mouseUp(with: native)
            active = nil
        case .rightMouseDown: view.rightMouseDown(with: native)
        case .rightMouseDragged: view.rightMouseDragged(with: native)
        case .rightMouseUp:
            view.rightMouseUp(with: native)
            active = nil
        default: return false
        }
        return true
    }
}

private struct WindowIconPointerHandler: NSViewRepresentable {
    let title: String
    let onLeftClick: (CGFloat) -> Void
    let onMiddleClick: (CGFloat) -> Void
    let onRightClick: (CGRect) -> Void
    let onHover: (Bool, CGRect) -> Void
    var onDragEnd: (() -> Void)? = nil
    var onDrag: ((CGPoint) -> Void)? = nil
    var onRightDrop: ((CGPoint) -> Void)? = nil
    var onRightDragUpdate: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView(
            title: title,
            onLeftClick: onLeftClick,
            onMiddleClick: onMiddleClick,
            onRightClick: onRightClick,
            onHover: onHover
        )
        view.onDragEnd = onDragEnd
        view.onDrag = onDrag
        view.onRightDrop = onRightDrop
        view.onRightDragUpdate = onRightDragUpdate
        return view
    }

    func updateNSView(_ view: PointerView, context: Context) {
        view.toolTip = title
        view.onLeftClick = onLeftClick
        view.onMiddleClick = onMiddleClick
        view.onRightClick = onRightClick
        view.onHover = onHover
        view.onDragEnd = onDragEnd
        view.onDrag = onDrag
        view.onRightDrop = onRightDrop
        view.onRightDragUpdate = onRightDragUpdate
    }

    final class PointerView: NSView {
        var onLeftClick: (CGFloat) -> Void
        var onMiddleClick: (CGFloat) -> Void
        var onRightClick: (CGRect) -> Void
        var onHover: (Bool, CGRect) -> Void
        var onDragEnd: (() -> Void)?
        private var movingWithLeft = false
        var onDrag: ((CGPoint) -> Void)?
        var onRightDrop: ((CGPoint) -> Void)?
        var onRightDragUpdate: ((CGPoint) -> Void)?
        private var rightStart = CGPoint.zero
        private var rightDragging = false
        private var rightTracking = false
        private var rightEventMonitor: Any?
        private var canDrag = false
        private var lastDragCell = 0

        init(
            title: String,
            onLeftClick: @escaping (CGFloat) -> Void,
            onMiddleClick: @escaping (CGFloat) -> Void,
            onRightClick: @escaping (CGRect) -> Void,
            onHover: @escaping (Bool, CGRect) -> Void
        ) {
            self.onLeftClick = onLeftClick
            self.onMiddleClick = onMiddleClick
            self.onRightClick = onRightClick
            self.onHover = onHover
            super.init(frame: .zero)
            toolTip = title
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = rightEventMonitor { NSEvent.removeMonitor(monitor); rightEventMonitor = nil }
            guard window != nil else { return }
            BarWindowRightDragRouter.shared.register(self)
            // Intercept before SwiftUI's ancestor context menu starts its own
            // tracking loop, which otherwise consumes right-drag events.
            rightEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                switch event.type {
                case .rightMouseDown:
                    guard self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                    self.rightTracking = true
                    self.rightMouseDown(with: event)
                case .rightMouseDragged:
                    guard self.rightTracking else { return event }
                    self.rightMouseDragged(with: event)
                case .rightMouseUp:
                    guard self.rightTracking else { return event }
                    self.rightTracking = false
                    self.rightMouseUp(with: event)
                default: return event
                }
                return nil
            }
        }

        deinit {
            if let monitor = rightEventMonitor { NSEvent.removeMonitor(monitor) }
            if rightDragging { NSCursor.pop() }
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            canDrag = !event.modifierFlags.contains(.option)
            movingWithLeft = event.clickCount >= 2
            if movingWithLeft { rightMouseDown(with: event) }
            lastDragCell = 0
            if event.modifierFlags.contains(.option), let rect = screenRect {
                onRightClick(rect)
            } else {
                onLeftClick(convert(event.locationInWindow, from: nil).y)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard canDrag else { return }
            if movingWithLeft { rightMouseDragged(with: event) }
            else { onDrag?(convert(event.locationInWindow, from: nil)) }
        }
        override func mouseUp(with event: NSEvent) {
            if movingWithLeft, rightDragging { rightMouseUp(with: event) }
            else { onDragEnd?() }
            movingWithLeft = false
            canDrag = false
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick(convert(event.locationInWindow, from: nil).y) }
            else { super.otherMouseDown(with: event) }
        }
        func cancelRightDrag() {
            if rightDragging { NSCursor.pop() }
            rightDragging = false
            rightTracking = false
            onRightDrop?(CGPoint(x: -100000, y: -100000))
        }

        override func rightMouseDown(with event: NSEvent) {
            rightStart = event.locationInWindow
            rightDragging = false
        }
        override func rightMouseDragged(with event: NSEvent) {
            guard onRightDrop != nil else { return }
            if !rightDragging && hypot(event.locationInWindow.x - rightStart.x, event.locationInWindow.y - rightStart.y) > 4 {
                rightDragging = true
                NSCursor.closedHand.push()
            }
            if rightDragging { onRightDragUpdate?(convert(event.locationInWindow, from: nil)) }
        }
        override func rightMouseUp(with event: NSEvent) {
            if rightDragging {
                rightDragging = false
                NSCursor.pop()
                onRightDrop?(convert(event.locationInWindow, from: nil))
            } else if let rect = screenRect {
                onRightClick(rect)
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }
        override func mouseEntered(with event: NSEvent) { onHover(true, screenRect ?? .zero) }
        override func mouseExited(with event: NSEvent) { onHover(false, screenRect ?? .zero) }

        private var screenRect: CGRect? {
            guard let window else { return nil }
            return window.convertToScreen(convert(bounds, to: nil))
        }
    }
}

private final class WindowStackStyleSettings: ObservableObject {
    static let shared = WindowStackStyleSettings()

    @Published var fillColor: Color {
        didSet { persistFillColor() }
    }
    @Published var activeFillOpacity: Double {
        didSet { Self.defaults.set(activeFillOpacity, forKey: Keys.activeFillOpacity) }
    }
    @Published var showsFocusedStackBackfill: Bool {
        didSet {
            Self.defaults.set(
                showsFocusedStackBackfill,
                forKey: Keys.showsFocusedStackBackfill
            )
        }
    }
    @Published var rememberedFillOpacity: Double {
        didSet {
            Self.defaults.set(rememberedFillOpacity, forKey: Keys.rememberedFillOpacity)
        }
    }
    @Published var iconShadowRadius: Double {
        didSet { Self.defaults.set(iconShadowRadius, forKey: Keys.iconShadowRadius) }
    }
    @Published var iconShadowOpacity: Double {
        didSet { Self.defaults.set(iconShadowOpacity, forKey: Keys.iconShadowOpacity) }
    }
    @Published var highlightCornerRadius: Double {
        didSet {
            Self.defaults.set(
                highlightCornerRadius, forKey: Keys.highlightCornerRadius)
        }
    }
    @Published var highlightWidth: Double {
        didSet { Self.defaults.set(highlightWidth, forKey: Keys.highlightWidth) }
    }
    @Published var highlightGap: Double {
        didSet { Self.defaults.set(highlightGap, forKey: Keys.highlightGap) }
    }

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let fillRed = "barik.window-stack.fill-red"
        static let fillGreen = "barik.window-stack.fill-green"
        static let fillBlue = "barik.window-stack.fill-blue"
        static let activeFillOpacity = "barik.window-stack.active-fill-opacity"
        static let showsFocusedStackBackfill =
            "barik.window-stack.shows-focused-backfill"
        static let rememberedFillOpacity = "barik.window-stack.remembered-fill-opacity"
        static let iconShadowRadius = "barik.window-stack.icon-shadow-radius"
        static let iconShadowOpacity = "barik.window-stack.icon-shadow-opacity"
        static let highlightCornerRadius =
            "barik.window-stack.highlight-corner-radius"
        static let highlightWidth = "barik.window-stack.highlight-width"
        static let highlightGap = "barik.window-stack.highlight-gap"
    }

    private init() {
        fillColor = Self.storedFillColor()
        activeFillOpacity = Self.storedDouble(
            forKey: Keys.activeFillOpacity, defaultValue: 0.92)
        showsFocusedStackBackfill = Self.storedBool(
            forKey: Keys.showsFocusedStackBackfill,
            defaultValue: false
        )
        rememberedFillOpacity = Self.storedDouble(
            forKey: Keys.rememberedFillOpacity, defaultValue: 0)
        iconShadowRadius = Self.storedDouble(
            forKey: Keys.iconShadowRadius, defaultValue: 2.0)
        iconShadowOpacity = Self.storedDouble(
            forKey: Keys.iconShadowOpacity, defaultValue: 0.28)
        highlightCornerRadius = Self.storedDouble(
            forKey: Keys.highlightCornerRadius, defaultValue: 0)
        highlightWidth = Self.storedDouble(
            forKey: Keys.highlightWidth, defaultValue: 1)
        highlightGap = Self.storedDouble(
            forKey: Keys.highlightGap, defaultValue: 0)
    }

    var markerColor: Color {
        guard let color = NSColor(fillColor).usingColorSpace(.sRGB) else {
            return .black
        }
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }

    var fillHex: String {
        guard let color = NSColor(fillColor).usingColorSpace(.sRGB) else {
            return "#FFFFFF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    func reset() {
        fillColor = .white
        activeFillOpacity = 0.92
        showsFocusedStackBackfill = false
        rememberedFillOpacity = 0
        iconShadowRadius = 2.0
        iconShadowOpacity = 0.28
        highlightCornerRadius = 0
        highlightWidth = 1
        highlightGap = 0
    }

    private static func storedDouble(
        forKey key: String, defaultValue: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    private static func storedBool(
        forKey key: String, defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func storedFillColor() -> Color {
        guard defaults.object(forKey: Keys.fillRed) != nil else { return .white }
        return Color(
            red: defaults.double(forKey: Keys.fillRed),
            green: defaults.double(forKey: Keys.fillGreen),
            blue: defaults.double(forKey: Keys.fillBlue)
        )
    }

    private func persistFillColor() {
        guard let color = NSColor(fillColor).usingColorSpace(.sRGB) else { return }
        Self.defaults.set(color.redComponent, forKey: Keys.fillRed)
        Self.defaults.set(color.greenComponent, forKey: Keys.fillGreen)
        Self.defaults.set(color.blueComponent, forKey: Keys.fillBlue)
    }
}

private final class WindowStackStylePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WindowStackStylePanelController: NSObject, NSWindowDelegate {
    static let shared = WindowStackStylePanelController()

    private var panel: WindowStackStylePanel?

    func toggle(relativeTo anchor: CGRect) {
        if panel?.isVisible == true {
            close()
            return
        }

        let size = CGSize(width: 300, height: 540)
        let rootView = WindowStackStyleEditor()
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        let newPanel = WindowStackStylePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = NSHostingController(rootView: rootView)
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = true
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self

        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let x = min(
            max(anchor.midX - size.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let y = max(
            anchor.minY - size.height - 8,
            visibleFrame.minY + 8
        )
        newPanel.setFrameOrigin(CGPoint(x: x, y: y))

        panel = newPanel
        newPanel.orderFrontRegardless()
        newPanel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

private struct WindowStackStyleEditor: View {
    @ObservedObject private var style = WindowStackStyleSettings.shared
    @State private var fillHex = WindowStackStyleSettings.shared.fillHex

    private let colorPresets = [
        "#FFFFFF",
        "#F2F2ED",
        "#DDEBFF",
        "#D9FFF2",
        "#191B20",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selector style")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Live preview in the bar")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button("Reset") {
                        style.reset()
                        fillHex = style.fillHex
                    }
                    Button("Done") {
                        WindowStackStylePanelController.shared.close()
                    }
                }
                .buttonStyle(.borderless)
            }

            Divider().opacity(0.35)

            backfillColorEditor

            Toggle(
                "Focused stack backfill",
                isOn: $style.showsFocusedStackBackfill
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))

            sliderRow(
                "Focused fill opacity",
                value: $style.activeFillOpacity,
                range: 0...1,
                valueText: "\(Int((style.activeFillOpacity * 100).rounded()))%"
            )
            sliderRow(
                "Remembered fill",
                value: $style.rememberedFillOpacity,
                range: 0...0.5,
                valueText: "\(Int((style.rememberedFillOpacity * 100).rounded()))%"
            )
            sliderRow(
                "Icon shadow",
                value: $style.iconShadowRadius,
                range: 0...8,
                valueText: String(format: "%.1f pt", style.iconShadowRadius)
            )
            sliderRow(
                "Shadow strength",
                value: $style.iconShadowOpacity,
                range: 0...1,
                valueText: "\(Int((style.iconShadowOpacity * 100).rounded()))%"
            )
            sliderRow(
                "Corner radius",
                value: $style.highlightCornerRadius,
                range: 0...10,
                valueText: String(
                    format: "%.1f pt", style.highlightCornerRadius)
            )
            sliderRow(
                "Highlight width",
                value: $style.highlightWidth,
                range: 0.6...1,
                valueText: "\(Int((style.highlightWidth * 100).rounded()))%"
            )
            sliderRow(
                "Row gap",
                value: $style.highlightGap,
                range: 0...5,
                valueText: String(format: "%.1f pt", style.highlightGap)
            )

            Text("Option-click or right-click any window icon to reopen this editor.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var backfillColorEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Backfill color")
                .font(.system(size: 12))
            HStack(spacing: 7) {
                ForEach(colorPresets, id: \.self) { hex in
                    Button {
                        applyColor(hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(hex: hex) ?? .white)
                            .frame(width: 25, height: 22)
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: 4, style: .continuous
                                )
                                .stroke(
                                    fillHex.uppercased() == hex
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.28),
                                    lineWidth: fillHex.uppercased() == hex ? 2 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Backfill \(hex)")
                }

                TextField("#FFFFFF", text: $fillHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 76)
                    .onSubmit { applyColor(fillHex) }
                    .onChange(of: fillHex) { _, newValue in
                        let digits = newValue.trimmingCharacters(
                            in: CharacterSet.alphanumerics.inverted)
                        if digits.count == 6 {
                            applyColor(newValue, normalizeText: false)
                        }
                    }
            }
        }
    }

    private func applyColor(_ value: String, normalizeText: Bool = true) {
        guard let color = Color(hex: value) else { return }
        style.fillColor = color
        if normalizeText {
            fillHex = style.fillHex
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            Slider(value: value, in: range)
        }
    }
}

private struct StackSliderMarkerKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var stackUsesSliderMarker: Bool {
        get { self[StackSliderMarkerKey.self] }
        set { self[StackSliderMarkerKey.self] = newValue }
    }
}

private struct SpaceScrubbingKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var isSpaceScrubbing: Bool {
        get { self[SpaceScrubbingKey.self] }
        set { self[SpaceScrubbingKey.self] = newValue }
    }
}

private enum WindowDropStyle {
    // ~/.yabairc: insert_feedback_color 0xFF008844 (ARGB).
    static let color = Color(red: 0, green: 136.0 / 255, blue: 68.0 / 255)
}

private struct WindowDropTarget: Equatable {
    let spaceID: String
    let windowID: Int?
    let direction: String?
}
private struct WindowDropPreviewKey: EnvironmentKey {
    static let defaultValue: WindowDropTarget? = nil
}
private struct UniversalScrubKey: EnvironmentKey {
    static let defaultValue: ((CGPoint?) -> Void)? = nil
}
private extension EnvironmentValues {
    var universalScrub: ((CGPoint?) -> Void)? {
        get { self[UniversalScrubKey.self] }
        set { self[UniversalScrubKey.self] = newValue }
    }
}
private struct WindowDropUpdateKey: EnvironmentKey {
    static let defaultValue: ((Int, CGPoint) -> Void)? = nil
}
private extension EnvironmentValues {
    var windowDropPreview: WindowDropTarget? {
        get { self[WindowDropPreviewKey.self] }
        set { self[WindowDropPreviewKey.self] = newValue }
    }
    var windowDropUpdate: ((Int, CGPoint) -> Void)? {
        get { self[WindowDropUpdateKey.self] }
        set { self[WindowDropUpdateKey.self] = newValue }
    }
}

private struct WindowDropActionKey: EnvironmentKey {
    static let defaultValue: ((Int, CGPoint) -> Void)? = nil
}
private extension EnvironmentValues {
    var windowDropAction: ((Int, CGPoint) -> Void)? {
        get { self[WindowDropActionKey.self] }
        set { self[WindowDropActionKey.self] = newValue }
    }
}
private struct WindowDropFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SpaceScrubFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SpacesWidget: View {
    @ObservedObject var viewModel: SpacesViewModel

    @ObservedObject var configManager = ConfigManager.shared
    @ObservedObject var displayManager = DisplayManager.shared
    @State private var leadingScreenX: CGFloat = 0
    @State private var scrubFrames: [String: CGRect] = [:]
    @State private var windowDropFrames: [Int: CGRect] = [:]
    @State private var dropPreview: WindowDropTarget?
    @State private var scrubBounds: CGRect = .zero
    @State private var lastScrubbedWindowID: Int?
    @State private var lastScrubbedSpaceID: String?
    @State private var isScrubbing = false
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    private var usesScrollableStrip: Bool {
        configManager.config.experimental.foreground.isCompactFlat && displayManager.hasNotch
    }
    private var focusedSpaceID: String? { viewModel.spaces.first(where: \.isFocused)?.id }

    var body: some View {
        Group {
            if usesScrollableStrip {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        spaceContent
                    }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity)
                    .frame(height: foregroundHeight + 1)
                    .onChange(of: focusedSpaceID) { _, id in
                        // No anchor: reveal only if clipped, without recentering visible Spaces.
                        if let id {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { proxy.scrollTo(id) }
                        }
                    }
                    .onAppear {
                        if let id = focusedSpaceID { proxy.scrollTo(id) }
                    }
                    .help("Scroll horizontally to see more Spaces")
                }
            } else {
                spaceContent
            }
        }
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onAppear { leadingScreenX = frame.minX; scrubBounds = frame }
                    .onChange(of: frame) { _, frame in
                        leadingScreenX = frame.minX
                        scrubBounds = frame
                    }
            }
        }
        .onPreferenceChange(SpaceScrubFrames.self) { scrubFrames = $0 }
        .onPreferenceChange(WindowDropFrames.self) { windowDropFrames = $0 }
        .environment(\.universalScrub, { point in
            if let point { scrub(at: point) }
            else { isScrubbing = false; lastScrubbedSpaceID = nil; lastScrubbedWindowID = nil }
        })
        .environment(\.windowDropAction, dropWindow)
        .environment(\.windowDropPreview, dropPreview)
        .environment(\.windowDropUpdate, { id, point in
            let target = dropTarget(at: point)
            dropPreview = target?.windowID == id ? nil : target
        })
        .experimentalConfiguration(horizontalPadding: 5, cornerRadius: 10)
        .foregroundStyle(Color.foreground)
        .environmentObject(viewModel)
        .environment(\.isSpaceScrubbing, isScrubbing)
    }

    @ViewBuilder
    private var spaceContent: some View {
        if usesScrollableStrip {
            HStack(spacing: 0) { spaceCells }
                .frame(height: foregroundHeight + 1)
        } else {
            NotchAvoidingSpacesLayout(
                spacing: configManager.config.experimental.foreground.isCompactFlat || foregroundHeight < 30 ? 0 : 4,
                leadingScreenX: leadingScreenX,
                notchRange: displayManager.notchAvoidanceRange
            ) { spaceCells }
        }
    }

    private func scrub(at location: CGPoint) {
        isScrubbing = true
        // Hit-test actual laid-out cells, including notch gaps and scroll clipping.
        guard scrubBounds.contains(location),
              let space = viewModel.spaces.first(where: {
                  scrubFrames[$0.id]?.contains(location) == true
              }) else { return }
        if let window = space.windows.first(where: { windowDropFrames[$0.id]?.contains(location) == true }) {
            guard lastScrubbedWindowID != window.id else { return }
            lastScrubbedWindowID = window.id
            viewModel.activateWindow(window, in: space)
            lastScrubbedSpaceID = space.id
        } else if space.id != lastScrubbedSpaceID {
            lastScrubbedWindowID = nil
            lastScrubbedSpaceID = space.id
            viewModel.switchToSpace(space, needWindowFocus: false)
        }
    }

    private func dropTarget(at point: CGPoint) -> WindowDropTarget? {
        guard scrubBounds.contains(point),
              let destination = viewModel.spaces.first(where: { scrubFrames[$0.id]?.contains(point) == true }) else { return nil }
        guard let target = destination.windows.first(where: { windowDropFrames[$0.id]?.contains(point) == true }),
              let frame = windowDropFrames[target.id] else {
            return WindowDropTarget(spaceID: destination.id, windowID: nil, direction: nil)
        }
        let x = (point.x - frame.midX) / (frame.width / 2)
        let y = (point.y - frame.midY) / (frame.height / 2)
        let direction: String?
        if max(abs(x), abs(y)) < 0.5 { direction = nil }
        else if abs(x) > abs(y) { direction = x < 0 ? "west" : "east" }
        else { direction = y < 0 ? "north" : "south" }
        return WindowDropTarget(spaceID: destination.id, windowID: target.id, direction: direction)
    }

    private func dropWindow(_ windowID: Int, at point: CGPoint) {
        dropPreview = nil
        guard let source = viewModel.spaces.first(where: { $0.windows.contains(where: { $0.id == windowID }) }),
              let destination = dropTarget(at: point) else { return }
        guard let targetID = destination.windowID else {
            if source.id != destination.spaceID { viewModel.moveWindow(windowID, to: destination.spaceID) }
            return
        }
        guard targetID != windowID else { return }
        let sharedStack = WindowVisualGroup.makeGroups(from: source.windows).first(where: {
            $0.isStack && $0.windows.contains(where: { $0.id == windowID }) && $0.windows.contains(where: { $0.id == targetID })
        })
        if let group = sharedStack, destination.direction == "west" || destination.direction == "east" {
            viewModel.reorderWindow(windowID, to: targetID, orderedIDs: group.orderedWindows.map(\.id), after: destination.direction == "east")
        } else if sharedStack == nil || destination.direction != nil {
            viewModel.arrangeWindow(windowID, fromSpace: source.id, target: targetID, toSpace: destination.spaceID, direction: destination.direction, detachFirst: sharedStack != nil)
        }
    }

    private var spaceCells: some View {
        let spaces = viewModel.spaces
        return
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                HStack(spacing: 0) {
                    if index > 0,
                       let prev = spaces[index - 1].displayIndex,
                       let curr = space.displayIndex,
                       prev != curr {
                        Rectangle()
                            .fill(Color.foreground.opacity(0.4))
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 2)
                    }
                    SpaceView(
                        space: space,
                        horizontalEdgePadding: 6,
                        nextSpaceIsOccupied: index + 1 < spaces.count && !spaces[index + 1].windows.isEmpty,
                        usesBareEmptyStyle: (displayManager.isBuiltinDisplayOnly || configManager.config.experimental.foreground.isCompactFlat)
                            && space.windows.isEmpty,
                        onScrub: scrub,
                        onScrubEnd: {
                            lastScrubbedWindowID = nil
                            lastScrubbedSpaceID = nil
                            isScrubbing = false
                        }
                    )
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: SpaceScrubFrames.self,
                                value: [space.id: geometry.frame(in: .global)]
                            )
                        }
                    }
                }
                .id(space.id)
            }
    }

}

/// Keeps each space indicator whole while moving the first one that would be
/// hidden by the camera housing to the safe area on the notch's right side.
private struct NotchAvoidingSpacesLayout: Layout {
    let spacing: CGFloat
    let leadingScreenX: CGFloat
    let notchRange: ClosedRange<CGFloat>?

    private let notchClearance: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(for: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrangement(for: subviews)
        for (index, subview) in subviews.enumerated() {
            let item = arrangement.items[index]
            subview.place(
                at: CGPoint(x: bounds.minX + item.x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arrangement(
        for subviews: Subviews
    ) -> (items: [(x: CGFloat, size: CGSize)], size: CGSize) {
        var items: [(x: CGFloat, size: CGSize)] = []
        var cursor: CGFloat = 0
        var height: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if index > 0 { cursor += spacing }

            if let notchRange {
                let itemMinX = leadingScreenX + cursor
                let itemMaxX = itemMinX + size.width
                let protectedMinX = notchRange.lowerBound - notchClearance
                let protectedMaxX = notchRange.upperBound + notchClearance

                if itemMinX < protectedMaxX && itemMaxX > protectedMinX {
                    cursor = max(cursor, protectedMaxX - leadingScreenX)
                }
            }

            items.append((cursor, size))
            cursor += size.width
            height = max(height, size.height)
        }

        return (items, CGSize(width: cursor, height: height))
    }
}

/// This view shows a space with its windows.
private struct SpaceView: View {
    @Environment(\.windowDropPreview) private var dropPreview
    @EnvironmentObject var configProvider: ConfigProvider
    @EnvironmentObject var viewModel: SpacesViewModel

    var config: ConfigData { configProvider.config }
    var spaceConfig: ConfigData { config["space"]?.dictionaryValue ?? [:] }

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    var isCompact: Bool { configManager.config.experimental.foreground.isCompactFlat }

    var showKey: Bool { spaceConfig["show-key"]?.boolValue ?? true }

    var activeBorderColor: Color {
        spaceConfig["active-color"]?.stringValue.flatMap { Color(hex: $0) }
            ?? Color(red: 0x62 / 255.0, green: 0xBA / 255.0, blue: 0x46 / 255.0)
    }
    var activeBorderWidth: CGFloat {
        CGFloat(spaceConfig["active-border-width"]?.doubleValue ?? 2.0)
    }
    var inactiveBorderWidth: CGFloat {
        CGFloat(spaceConfig["inactive-border-width"]?.doubleValue ?? 1.0)
    }
    var inactiveBorderOpacity: Double {
        spaceConfig["inactive-border-opacity"]?.doubleValue ?? (0x4D / 255.0)
    }
    var activeGlowRadius: CGFloat {
        CGFloat(spaceConfig["active-glow-radius"]?.doubleValue ?? 0)
    }
    var activeGlowOpacity: Double {
        spaceConfig["active-glow-opacity"]?.doubleValue ?? 0.4
    }

    let space: AnySpace
    let horizontalEdgePadding: CGFloat
    let nextSpaceIsOccupied: Bool
    let usesBareEmptyStyle: Bool
    let onScrub: (CGPoint) -> Void
    let onScrubEnd: () -> Void

    private var spaceScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { onScrub($0.location) }
            .onEnded { _ in onScrubEnd() }
    }

    @Environment(\.colorScheme) var colorScheme
    @State var isHovered = false
    @ObservedObject private var displayManager = DisplayManager.shared
    // Use the same balanced cell padding on every display.
    private var balancedOuterInset: CGFloat {
        isCompact && foregroundHeight >= 30 ? 2 : 0
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private func spaceNumber(weight: NSFont.Weight) -> some View {
        if isCompact {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: weight)
            let label: NSAttributedString = {
                let value = NSMutableAttributedString(string: space.id, attributes: [.font: font])
                if value.length > 1 {
                    // Tighten between digits only, never after the final glyph.
                    value.addAttribute(.kern, value: -1.0, range: NSRange(location: 0, length: value.length - 1))
                }
                return value
            }()
            let line = CTLineCreateWithAttributedString(label)
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            Text(AttributedString(label))
                .fixedSize()
                .frame(width: advance, alignment: .leading)
                .offset(x: advance / 2 - ink.midX)
        } else {
            Text(space.id)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
    }

    var body: some View {
        Group {
            if usesBareEmptyStyle {
                spaceNumber(weight: space.isFocused ? .bold : .semibold)
                    .opacity(space.isFocused || isHovered ? 1 : (isCompact ? 0.60 : 0.5))
                    .frame(minWidth: isCompact ? (space.id.count > 1 ? 16 : 9) : 15)
                    .padding(.horizontal, isCompact ? 4 + balancedOuterInset : 0)
                    .frame(minHeight: isCompact ? foregroundHeight + 1 : 30)
                    .background {
                        if isCompact {
                            Rectangle().fill(space.isFocused ? activeBorderColor.opacity(0.52) : (isHovered ? Color.foreground.opacity(0.10) : Color.clear))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(spaceScrubGesture)
            } else {
                standardSpace
            }
        }
        .overlay(alignment: .trailing) {
            if isCompact {
                Rectangle()
                    .fill(Color.foreground.opacity(!space.windows.isEmpty || nextSpaceIsOccupied ? 0.42 : 0.14))
                    .frame(width: 1, height: !space.windows.isEmpty || nextSpaceIsOccupied ? 20 : 14)
                    .offset(x: 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            if isCompact && space.isFocused {
                Rectangle()
                    .fill(activeBorderColor)
                    .frame(height: 2)
            }
        }
        .overlay {
            if dropPreview?.spaceID == space.id && dropPreview?.windowID == nil {
                Rectangle().fill(WindowDropStyle.color.opacity(0.35)).allowsHitTesting(false)
            }
        }
        // The indicator must keep up with held Space-switch shortcuts.
        .animation(nil, value: space.isFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.switchToSpace(space, needWindowFocus: true)
        }
        .onHover { value in
            isHovered = value
        }
    }

    private var standardSpace: some View {
        let isFocused = space.isFocused
        return HStack(spacing: 0) {
            Spacer().frame(width: isCompact ? balancedOuterInset : horizontalEdgePadding)
            if showKey {
                spaceNumber(weight: .bold)
                    .opacity(space.windows.isEmpty && !isFocused ? 0.5 : 1)
                    // Add 2 pt of outer breathing room; keep the internal icon gap unchanged.
                    .padding(.leading, isCompact ? 5 : 0)
                    .frame(minWidth: isCompact ? 0 : 15)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: isCompact ? foregroundHeight + 1 : 30)
                    .contentShape(Rectangle())
                    .gesture(spaceScrubGesture)
                if !space.windows.isEmpty {
                    Spacer().frame(width: isCompact ? 0 : 3)
                }
            }
            HStack(spacing: 0) {
                ForEach(WindowVisualGroup.makeGroups(from: space.windows)) { group in
                    WindowGroupView(group: group, space: space)
                }
            }
            if let displayWindow = space.windows.first(where: { $0.isFocused })
                ?? (isFocused ? space.windows.first : nil) {
                FocusedWindowTitleView(window: displayWindow, space: space)
            }
            Spacer().frame(width: isCompact ? 2 + balancedOuterInset : horizontalEdgePadding)
        }
        .frame(height: configManager.config.experimental.foreground.isCompactFlat ? foregroundHeight + 1 : 30)
        .background {
            if configManager.config.experimental.foreground.isCompactFlat {
                Rectangle().fill(isFocused ? activeBorderColor.opacity(0.52) : (isHovered ? Color.foreground.opacity(0.12) : Color.white.opacity(0.10)))
            } else {
            RoundedRectangle(
                cornerRadius: foregroundHeight < 30 ? 0 : 8,
                style: .continuous
            )
            .fill(
                foregroundHeight < 30
                    ? (isFocused ? Color.noActive : Color.clear)
                    : (isFocused ? Color.active : Color.noActive)
            )
            }
        }
        .overlay(
            Group {
                if !configManager.config.experimental.foreground.isCompactFlat && foregroundHeight >= 30 {
                    if isFocused {
                        ZStack {
                            if activeGlowRadius > 0 {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(activeBorderColor.opacity(activeGlowOpacity), lineWidth: activeBorderWidth)
                                    .blur(radius: activeGlowRadius)
                            }
                            if colorScheme == .light {
                                RoundedRectangle(cornerRadius: 8 + activeBorderWidth / 2, style: .continuous)
                                    .stroke(activeBorderColor, lineWidth: activeBorderWidth)
                                    .padding(-activeBorderWidth / 2)
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(activeBorderColor, lineWidth: activeBorderWidth)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(inactiveBorderOpacity), lineWidth: inactiveBorderWidth)
                    }
                }
            }
        )
        // .shadow(color: .shadow, radius: foregroundHeight < 30 ? 0 : 2)
    }
}

/// A single tiled window, or the windows yabai reports in the same stack.
private struct WindowVisualGroup: Identifiable {
    let id: String
    let windows: [AnyWindow]

    var isStack: Bool { windows.count > 1 }

    var orderedWindows: [AnyWindow] {
        windows.sorted {
            if $0.stackIndex != $1.stackIndex {
                return $0.stackIndex < $1.stackIndex
            }
            return $0.id < $1.id
        }
    }

    static func makeGroups(from windows: [AnyWindow]) -> [WindowVisualGroup] {
        var groups: [WindowVisualGroup] = []
        var stackGroupIndices: [StackFrameKey: Int] = [:]

        for window in windows {
            guard let key = StackFrameKey(window: window) else {
                groups.append(WindowVisualGroup(
                    id: "window-\(window.id)",
                    windows: [window]
                ))
                continue
            }

            if let groupIndex = stackGroupIndices[key] {
                let existing = groups[groupIndex]
                groups[groupIndex] = WindowVisualGroup(
                    id: existing.id,
                    windows: existing.windows + [window]
                )
            } else {
                stackGroupIndices[key] = groups.count
                groups.append(WindowVisualGroup(
                    id: "stack-\(key.x)-\(key.y)-\(key.width)-\(key.height)",
                    windows: [window]
                ))
            }
        }

        return groups
    }

    private struct StackFrameKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init?(window: AnyWindow) {
            guard window.stackIndex > 0, let frame = window.frame else { return nil }
            x = Int(frame.minX.rounded())
            y = Int(frame.minY.rounded())
            width = Int(frame.width.rounded())
            height = Int(frame.height.rounded())
        }
    }
}

/// A local, segmented backplate that shows which fixed stack position is active.
private struct WindowSelectionBackplate: View {
    let itemCount: Int
    let selectedIndex: Int
    let isStack: Bool
    let isActive: Bool
    let showsSelection: Bool
    let isHovered: Bool

    @ObservedObject private var style = WindowStackStyleSettings.shared
    @ObservedObject private var configManager = ConfigManager.shared

    var body: some View {
        GeometryReader { geometry in
            let count = max(itemCount, 1)
            let segmentHeight = geometry.size.height / CGFloat(count)
            let width = geometry.size.width * style.highlightWidth
            let horizontalOffset = (geometry.size.width - width) / 2
            let gap = min(
                CGFloat(style.highlightGap),
                max(segmentHeight - 1, 0)
            )
            let selectedHeight = max(segmentHeight - gap, 1)

            if configManager.config.experimental.foreground.isCompactFlat {
                // Stacks use only their position rail; backfill obscures layered icons.
                if !isStack && (showsSelection || isHovered) {
                    ZStack(alignment: .bottom) {
                        Ellipse()
                            .fill(Color.white.opacity(showsSelection ? 0.46 : 0.12))
                            .frame(width: geometry.size.width - 5, height: 9)
                            .blur(radius: 4)
                            .offset(y: 2)
                        Capsule()
                            .fill(Color.white.opacity(showsSelection ? 0.9 : 0.25))
                            .frame(width: 12, height: 2)
                            .padding(.bottom, 1)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                    .clipped()
                }
            } else if isStack {
                ZStack(alignment: .topLeading) {
                    if isHovered
                        && (!isActive || style.showsFocusedStackBackfill) {
                        RoundedRectangle(
                            cornerRadius: CGFloat(style.highlightCornerRadius),
                            style: .continuous
                        )
                            .fill(style.fillColor.opacity(0.08))
                            .frame(width: width, height: geometry.size.height)
                            .offset(x: horizontalOffset)
                    }

                    if showsSelection {
                        RoundedRectangle(
                            cornerRadius: CGFloat(style.highlightCornerRadius),
                            style: .continuous
                        )
                            .fill(style.fillColor.opacity(selectionOpacity))
                            .frame(width: width, height: selectedHeight)
                            .offset(
                                x: horizontalOffset,
                                y: CGFloat(selectedIndex) * segmentHeight + gap / 2
                            )
                    }
                }
            } else if showsSelection || isHovered {
                // A single focused window should read as one selected icon,
                // not as a one-row stack filling the entire menu-bar cell.
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(style.fillColor.opacity(showsSelection ? 0.24 : 0.08))
                    .frame(width: 23, height: 23)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private var selectionOpacity: Double {
        if isStack && isActive && !style.showsFocusedStackBackfill {
            return 0
        }
        return isActive ? style.activeFillOpacity : style.rememberedFillOpacity
    }
}

/// Stacked windows occupy fixed adjacent cells, joined by a shared baseline.
private struct WindowGroupView: View {
    @Environment(\.universalScrub) private var universalScrub
    @Environment(\.windowDropUpdate) private var updateDrop
    @Environment(\.windowDropPreview) private var dropPreview
    @Environment(\.windowDropAction) private var dropWindow
    @Environment(\.stackUsesSliderMarker) private var sliderMarker
    @EnvironmentObject private var viewModel: SpacesViewModel
    @Environment(\.isSpaceScrubbing) private var isScrubbing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredWindowID: Int?
    @State private var rememberedWindowID: Int?

    let group: WindowVisualGroup
    let space: AnySpace

    var body: some View {
        let windows = group.orderedWindows
        let itemWidth: CGFloat = 25
        let isActive = windows.contains(where: \.isFocused)
        HStack(spacing: 0) {
            ForEach(windows) { window in
                ZStack {
                    if !isScrubbing && !(sliderMarker && group.isStack) {
                        WindowSelectionBackplate(
                            itemCount: 1,
                            selectedIndex: 0,
                            isStack: false,
                            isActive: window.isFocused,
                            showsSelection: window.isFocused,
                            isHovered: hoveredWindowID == window.id
                        )
                    }
                    WindowIconView(
                        window: window,
                        space: space,
                        isStackMember: group.isStack,
                        isGroupActive: isActive,
                        isSelected: window.isFocused
                    )
                }
                .frame(width: itemWidth, height: 30)
                .contentShape(Rectangle())
                .overlay {
                    GeometryReader { geometry in
                    WindowIconPointerHandler(
                    title: "\(window.title).\(group.isStack ? " Part of a \(windows.count)-window stack." : "") Click-drag to select across Spaces and windows. Double-click-drag to move. Middle-click to close.",
                    onLeftClick: { _ in viewModel.activateWindow(window, in: space) },
                    onMiddleClick: { _ in viewModel.closeWindow(window) },
                    onRightClick: { rect in
                        WindowStackStylePanelController.shared.toggle(relativeTo: rect)
                    },
                    onHover: { hovering, _ in
                        hoveredWindowID = hovering ? window.id : nil
                    },
                    onDragEnd: { universalScrub?(nil) },
                    onDrag: { point in
                        let frame = geometry.frame(in: .global)
                        universalScrub?(CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                    },
                    onRightDrop: { point in
                        let frame = geometry.frame(in: .global)
                        dropWindow?(window.id, CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                    },
                    onRightDragUpdate: { point in
                        let frame = geometry.frame(in: .global)
                        updateDrop?(window.id, CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                    }
                    )
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WindowDropFrames.self, value: [window.id: geometry.frame(in: .global)])
                    }
                }
                .overlay {
                    if let preview = dropPreview, preview.windowID == window.id {
                        GeometryReader { geometry in
                            let horizontal = preview.direction == "west" || preview.direction == "east"
                            let vertical = preview.direction == "north" || preview.direction == "south"
                            RoundedRectangle(cornerRadius: 3)
                                .fill(WindowDropStyle.color.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WindowDropStyle.color, lineWidth: 1))
                                .frame(width: geometry.size.width * (horizontal ? 0.5 : 1), height: geometry.size.height * (vertical ? 0.5 : 1))
                                .offset(x: preview.direction == "east" ? geometry.size.width / 2 : 0,
                                        y: preview.direction == "south" ? geometry.size.height / 2 : 0)
                        }.allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(window.title.isEmpty ? (window.appName ?? "Window") : window.title)
            }
        }
        .padding(.horizontal, group.isStack ? 2 : 0)
        .overlay(alignment: .bottom) {
            if group.isStack {
                if sliderMarker {
                    let selectedID = windows.first(where: \.isFocused)?.id ?? rememberedWindowID
                    // Match the normal focused-window capsule above.
                    let markerWidth: CGFloat = 12
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(isActive ? 0.62 : 0.36))
                            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
                        if let index = windows.firstIndex(where: { $0.id == selectedID }) {
                            ZStack(alignment: .bottom) {
                                Ellipse()
                                    .fill(Color.white.opacity(isActive ? 0.65 : 0.08))
                                    .frame(width: markerWidth + 3, height: 9)
                                    .blur(radius: 4)
                                    .offset(y: 2)
                                Capsule()
                                    .fill(Color.white.opacity(isActive ? 1 : 0.38))
                                    .frame(width: markerWidth, height: 2)
                            }
                            .frame(width: markerWidth, height: 2, alignment: .bottom)
                            .offset(x: CGFloat(index) * itemWidth)
                        }
                    }
                    .frame(height: 2)
                    .padding(.bottom, 1)
                    .padding(.horizontal, 2 + (itemWidth - markerWidth) / 2)
                    .allowsHitTesting(false)
                } else {
                    GeometryReader { geometry in
                        let bracket = Path { path in
                            path.move(to: CGPoint(x: 3, y: 0))
                            path.addLine(to: CGPoint(x: 3, y: 4))
                            path.addLine(to: CGPoint(x: geometry.size.width - 3, y: 4))
                            path.addLine(to: CGPoint(x: geometry.size.width - 3, y: 0))
                        }
                        bracket.stroke(.black.opacity(0.65), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        bracket.stroke(.white.opacity(0.90), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                    .frame(height: 5)
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear { rememberedWindowID = windows.first(where: \.isFocused)?.id ?? windows.first?.id }
        .onChange(of: windows.first(where: \.isFocused)?.id) { _, id in
            if let id { rememberedWindowID = id }
        }
        .onChange(of: windows.map(\.id)) { _, ids in
            if let rememberedWindowID, !ids.contains(rememberedWindowID) {
                self.rememberedWindowID = ids.first
            }
        }
        // Focus markers track rapid keyboard repeats without a trailing animation.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.isStack ? "Window stack" : "Window")
    }
}

/// This view shows a window icon only (no title).
private struct WindowIconView: View {
    @Environment(\.isSpaceScrubbing) private var isScrubbing
    let window: AnyWindow
    let space: AnySpace
    let isStackMember: Bool
    let isGroupActive: Bool
    let isSelected: Bool
    var artworkSize: CGFloat = 21

    @ObservedObject private var style = WindowStackStyleSettings.shared

    var body: some View {
        let size = artworkSize
        let iconBrightness: Double = !isScrubbing && isSelected ? 0.04 : 0
        let shadowOpacity = style.iconShadowOpacity
        let shadowRadius = style.iconShadowRadius
        ZStack {
            if window.title.localizedCaseInsensitiveContains("Tabs Outliner") {
                Image("TabsOutlinerIcon")
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .frame(width: size - 3, height: size - 3)
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: shadowRadius,
            x: 0,
            y: 0.5
        )
        .brightness(iconBrightness)
        .contrast(isSelected && !isScrubbing ? 1.04 : 1)
        .padding(.all, 2)
        .fixedSize(horizontal: true, vertical: true)
        .frame(height: 30)
        .accessibilityLabel(window.title.isEmpty ? (window.appName ?? "Window") : window.title)
    }
}

/// This view shows the focused window's title after all icons.
private struct FocusedWindowTitleView: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject var displayManager = DisplayManager.shared

    var config: ConfigData { configProvider.config }
    var windowConfig: ConfigData { config["window"]?.dictionaryValue ?? [:] }
    var titleConfig: ConfigData {
        windowConfig["title"]?.dictionaryValue ?? [:]
    }

    var showTitle: Bool { windowConfig["show-title"]?.boolValue ?? true }
    var maxLength: Int { titleConfig["max-length"]?.intValue ?? 50 }
    var alwaysDisplayAppTitleFor: [String] { titleConfig["always-display-app-name-for"]?.arrayValue?.filter({ $0.stringValue != nil }).map { $0.stringValue! } ?? [] }

    let window: AnyWindow
    let space: AnySpace

    var effectiveShowTitle: Bool {
        showTitle
    }

    var body: some View {
        if effectiveShowTitle {
            let sameAppCount = space.windows.filter { $0.appName == window.appName }.count
            let title = sameAppCount > 1 && !alwaysDisplayAppTitleFor.contains(where: { $0 == window.appName }) ? window.title : (window.appName ?? "")
            if !title.isEmpty {
                HStack(spacing: 0) {
                    Spacer().frame(width: 3)
                    Text(
                        title.count > maxLength
                            ? String(title.prefix(maxLength)) + "..."
                            : title
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .shadow(color: .foregroundShadow, radius: 3)
                    .fontWeight(.medium)
                    .padding(.trailing, 4)
                }
            }
        }
    }
}
