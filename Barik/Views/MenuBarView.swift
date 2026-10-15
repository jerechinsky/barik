import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

// Own the model without subscribing the entire menu bar to every focus event.
// SpacesWidget and FocusedWindowWidget observe it at their own view boundaries.
private final class SpacesModelOwner: ObservableObject {
    static let shared = SpacesModelOwner()
    let model = SpacesViewModel()
}

struct MenuBarView: View {
    @ObservedObject var configManager = ConfigManager.shared
    @ObservedObject var displayManager = DisplayManager.shared
    @ObservedObject private var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject private var caffeinateManager = CaffeinateManager.shared
    @ObservedObject private var batteryManager = BatteryManager.shared
    @StateObject private var spacesOwner = SpacesModelOwner.shared
    private var spacesViewModel: SpacesViewModel { spacesOwner.model }
    @StateObject private var contrastManager = AdaptiveContrastManager()
    @State private var widgetItems: [TomlWidgetItem] = []
    @State private var draggingItem: TomlWidgetItem?
    @State private var spacerFrame = CGRect.zero

    private let contextMenuWidgets: [(id: String, name: String)] = [
        ("default.system", "System"),
        ("default.spaces", "Spaces"),
        ("default.donotdisturb", "Do Not Disturb"),
        ("default.focustimer", "Focus Timer"),
        ("default.focusedwindow", "Focused Window"),
        ("default.spotify", "Spotify"),
        ("default.codexlimits", "Codex Limits"),
        ("default.codexactivity", "Codex Activity"),
        ("default.weather", "Weather"),
        ("default.inputsource", "Input Source"),
        ("default.resources", "Resources"),
        ("default.headsetbattery", "Headset Battery"),
        ("default.airpodsbattery", "AirPods Battery"),
        ("default.audiooutput", "Audio Output"),
        ("default.brightness", "Brightness"),
        ("default.network", "Network"),
        ("default.battery", "Battery"),
        ("default.time", "Time & Calendar"),
        ("default.nextmeeting", "Next Meeting"),
        ("default.iterm", "iTerm"),
        ("default.nowplaying", "Now Playing"),
        ("default.oneplus", "OnePlus 7"),
    ]

    private var displayedFingerprint: String {
        configManager.config.rootToml.widgets.displayed
            .map(\.id)
            .joined(separator: "|")
    }

    var body: some View {
        let hiddenWidgets = displayManager.isBuiltinDisplay
            ? configManager.config.builtinDisplay.hiddenWidgets
            : []
        let items = widgetItems.filter {
            !hiddenWidgets.contains($0.id)
                && !compactHiddenWidgetIDs.contains($0.id)
                && $0.id != "default.tailscale"
                && $0.id != "default.caffeinate"
                && ($0.id != "default.battery" || batteryManager.shouldShowWidget)
        }

        let hasFocusedWindow = items.contains(where: { $0.id == "default.focusedwindow" })
        let centersMusic = !displayManager.isBuiltinDisplay && hasFocusedWindow
            && items.contains(where: { $0.id == "spacer" })
            && items.contains(where: { $0.id == "default.spotify" })
        let displayItems = items.filter {
            $0.id != "default.focusedwindow"
                && (!centersMusic || $0.id != "default.spotify")
                && ($0.id != "default.donotdisturb" || doNotDisturbManager.isActive)
        }

        let notch = displayManager.notchAvoidanceRange
        let layout = notch.map {
            AnyLayout(NotchedMenuBarLayout(
                notch: ($0.lowerBound - effectiveHorizontalPadding)...($0.upperBound - effectiveHorizontalPadding),
                spacing: effectiveWidgetSpacing,
                height: configManager.config.experimental.foreground.resolveHeight()))
        } ?? AnyLayout(HStackLayout(spacing: effectiveWidgetSpacing))
        let spacerIndex = displayItems.firstIndex(where: { $0.id == "spacer" }) ?? displayItems.count / 2
        let arrangedItems = displayItems.enumerated().filter { notch == nil || $0.element.id != "spacer" }

        layout {
                ForEach(Array(arrangedItems), id: \.element.instanceID) { index, item in
                    buildView(for: item)
                        .layoutValue(key: BarikWidgetID.self, value: item.id)
                        .layoutValue(key: BarikWidgetOnLeft.self, value: index < spacerIndex)
                        .barikColorScheme(colorScheme(for: index, in: displayItems))
                        .opacity(draggingItem?.instanceID == item.instanceID ? 0.45 : 1)
                        .onDrag {
                            guard NSEvent.modifierFlags.contains(.command) else { return NSItemProvider() }
                            draggingItem = item
                            return NSItemProvider(object: item.instanceID.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: MenuBarWidgetDropDelegate(
                                target: item,
                                items: $widgetItems,
                                draggingItem: $draggingItem,
                                onOrderChanged: persistWidgetOrder
                            )
                        )
                }
            if !items.contains(where: { $0.id == "system-banner" }) {
                SystemBannerWidget(withLeftPadding: true)
                    .barikColorScheme(colorScheme(for: .right))
            }
        }
        .coordinateSpace(name: "menuBar")
        .overlay(alignment: .top) {
            if hasFocusedWindow {
                GeometryReader { geometry in
                    let center = geometry.size.width / 2
                    let availableWidth = spacerFrame.width > 0
                        ? max(0, 2 * min(center - spacerFrame.minX, spacerFrame.maxX - center))
                        : 360
                    FocusedWindowWidget(
                        spacesViewModel: spacesViewModel,
                        maxWidth: centersMusic ? min(360, availableWidth) : availableWidth
                    )
                    .barikColorScheme(colorScheme(for: .right))
                    .frame(maxWidth: .infinity)
                    if centersMusic, let music = items.first(where: { $0.id == "default.spotify" }) {
                        // Reserve a fixed title lane. Focused title length never moves music.
                        let left = max(center + 190, spacerFrame.minX)
                        let right = spacerFrame.maxX - 10
                        let width = max(0, min(230, right - left))
                        buildView(for: music)
                            .barikColorScheme(colorScheme(for: .right))
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                            .position(x: (left + right) / 2, y: geometry.size.height / 2)
                    }
                }
            }
        }
        .foregroundStyle(Color.foregroundOutside)
        .frame(height: max(configManager.config.experimental.foreground.resolveHeight(), 1.0))
        .frame(maxWidth: .infinity)
        .padding(.leading, effectiveHorizontalPadding)
        // The built-in display's rounded corner moves the privacy dot inward.
        // The external display's privacy dot is centered 8 pt from the edge.
        // Reserving 16 pt balances the clock-to-dot and dot-to-edge gaps.
        .padding(.trailing, displayManager.isBuiltinDisplay
            ? max(effectiveHorizontalPadding, 32)
            : 16)
        .background(.black.opacity(0.001))
        .contextMenu {
            Button(caffeinateManager.isActive ? "Turn Off Keep Awake" : "Turn On Keep Awake") {
                caffeinateManager.toggle()
            }
            Button(caffeinateManager.isJiggling ? "Turn Off Mouse Jiggler" : "Turn On Mouse Jiggler") {
                caffeinateManager.toggleJiggler()
            }
            Divider()
            if ProcessInfo.processInfo.arguments.contains("--stack-marker-comparison") {
                Button("Hide comparison bar") {
                    NotificationCenter.default.post(name: Notification.Name("HideStackMarkerComparison"), object: nil)
                }
                Divider()
            }
            Menu("Bar Theme") {
                Button(configManager.config.experimental.foreground.isCompactFlat ? "✓ Compact Flat" : "Compact Flat") {
                    configManager.updateConfigValue(key: "experimental.foreground.style", newValue: "compact-flat")
                }
                Button(configManager.config.experimental.foreground.isCompactFlat ? "Original Bubbles" : "✓ Original Bubbles") {
                    configManager.updateConfigValue(key: "experimental.foreground.style", newValue: "bubbles")
                }
            }
            Divider()
            ForEach(contextMenuWidgets, id: \.id) { entry in
                Button {
                    let wasDisplayed = widgetItems.contains(where: { $0.id == entry.id })
                    if wasDisplayed {
                        widgetItems.removeAll(where: { $0.id == entry.id })
                    } else {
                        widgetItems.append(TomlWidgetItem(id: entry.id, inlineParams: [:]))
                    }
                    assert(widgetItems.contains(where: { $0.id == entry.id }) != wasDisplayed)
                    persistWidgetOrder()
                } label: {
                    Label(
                        entry.name,
                        systemImage: widgetItems.contains(where: { $0.id == entry.id })
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
            Divider()
            Button("Edit Config…", systemImage: "doc.text") {
                configManager.openConfigFile()
            }
            Button("Quit Barik", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            widgetItems = configManager.config.rootToml.widgets.displayed
            contrastManager.setEnabled(configManager.config.theme == "adaptive")
        }
        .onChange(of: configManager.config.theme) { _, theme in
            contrastManager.setEnabled(theme == "adaptive")
        }
        .onChange(of: displayedFingerprint) { _, _ in
            if draggingItem == nil {
                widgetItems = configManager.config.rootToml.widgets.displayed
            }
        }
    }

    private func persistWidgetOrder() {
        configManager.updateDisplayedWidgets(widgetItems)
    }

    private func colorScheme(for index: Int, in items: [TomlWidgetItem]) -> ColorScheme? {
        if items[index].id == "default.system" {
            return colorScheme(for: .right)
        }
        if let spacer = items.firstIndex(where: { $0.id == "spacer" }) {
            return colorScheme(for: index < spacer ? .left : .right)
        }
        return colorScheme(for: index < items.count / 2 ? .left : .right)
    }

    private func colorScheme(for region: MenuBarRegion) -> ColorScheme? {
        return switch configManager.config.theme {
        case "light": .light
        case "dark": .dark
        case "adaptive": contrastManager.scheme(for: region)
        default: nil
        }
    }

    @ViewBuilder
    private func buildView(for item: TomlWidgetItem) -> some View {
        let config = ConfigProvider(
            config: configManager.resolvedWidgetConfig(for: item))

        switch item.id {
        case "default.system":
            SystemWidget().environmentObject(config)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)

        case "default.spaces":
            SpacesWidget(viewModel: spacesViewModel)
                .environmentObject(config)

        case "default.network":
            NetworkWidget().environmentObject(config)

        case "default.battery":
            BatteryWidget().environmentObject(config)

        case "default.time":
            TimeWidget(configProvider: config)
                .environmentObject(config)
                .layoutPriority(displayManager.isBuiltinDisplayOnly ? 2 : 0)

        case "default.nextmeeting":
            NextMeetingWidget(configProvider: config)
                .environmentObject(config)

        case "default.nowplaying":
            NowPlayingWidget()
                .environmentObject(config)

        case "default.audiooutput":
            AudioOutputWidget()
                .environmentObject(config)

        case "default.brightness":
            BrightnessWidget()

        case "default.headsetbattery":
            HeadsetBatteryWidget()
                .environmentObject(config)

        case "default.donotdisturb":
            DoNotDisturbWidget()
                .environmentObject(config)

        case "default.airpodsbattery":
            AirPodsBatteryWidget()
                .environmentObject(config)

        case "default.caffeinate":
            EmptyView()

        case "default.oneplus":
            OnePlusWidget()

        case "default.iterm":
            ITermWidget()
                .environmentObject(config)

        case "default.inputsource":
            InputSourceWidget()
                .environmentObject(config)

        case "default.weather":
            WeatherWidget()
                .environmentObject(config)

        case "default.codexlimits":
            CodexLimitsWidget()
                .environmentObject(config)

        case "default.codexactivity":
            CodexActivityWidget()
                .environmentObject(config)

        case "default.spotify":
            SpotifyWidget()
                .environmentObject(config)
                .layoutPriority(2)

        case "default.resources":
            ResourceMonitorWidget()
                .environmentObject(config)

        case "default.focustimer":
            FocusTimerWidget()

        case "default.focusedwindow":
            EmptyView()

        case "spacer":
            // Spaces inserts the physical notch gap itself. Let this flexible
            // separator collapse so the widgets after it remain on-screen.
            let minWidth: CGFloat = {
                if configManager.config.experimental.foreground.isCompactFlat,
                   let notch = displayManager.notchAvoidanceRange {
                    return notch.upperBound - notch.lowerBound + 24
                }
                return spacesAvoidNotch ? 0 : 50
            }()
            Spacer()
                .frame(minWidth: minWidth, maxWidth: .infinity)
                .padding(
                    .horizontal,
                    spacesAvoidNotch ? -effectiveWidgetSpacing : 0
                )
                .background {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .named("menuBar"))
                        Color.clear
                            .onAppear { spacerFrame = frame }
                            .onChange(of: frame) { _, frame in spacerFrame = frame }
                    }
                }

        case "fixed-spacer":
            let width = CGFloat(config.config["width"]?.doubleValue ?? 0)
            Color.clear
                .frame(width: max(0, width))
                .padding(.horizontal, -effectiveWidgetSpacing)

        case "divider":
            Rectangle()
                .fill(Color.foregroundOutside.opacity(0.5))
                .frame(width: 2, height: 15)
                .clipShape(Capsule())

        case "system-banner":
            SystemBannerWidget()

        default:
            Text("?\(item.id)?").foregroundColor(.red)
        }
    }

    private var spacesAvoidNotch: Bool {
        guard displayManager.notchAvoidanceRange != nil,
              !configManager.config.builtinDisplay.hiddenWidgets.contains("default.spaces"),
              let spacesIndex = widgetItems.firstIndex(where: { $0.id == "default.spaces" }),
              let spacerIndex = widgetItems.firstIndex(where: { $0.id == "spacer" })
        else { return false }

        return spacesIndex < spacerIndex
    }

    private var effectiveWidgetSpacing: CGFloat {
        displayManager.isBuiltinDisplay
            ? min(8, configManager.config.experimental.foreground.spacing)
            : configManager.config.experimental.foreground.spacing
    }

    private var effectiveHorizontalPadding: CGFloat {
        let configured = configManager.config.experimental.foreground.horizontalPadding
        // Keep the configured edge inset on the notebook too; 8 pt cramped the Apple logo.
        return configured
    }

    private var compactHiddenWidgetIDs: Set<String> {
        guard displayManager.isBuiltinDisplay else { return [] }
        return [
            // The centered window title would sit under the camera housing.
            "default.focusedwindow",
            "default.headsetbattery",
        ]
    }
}

private struct BarikWidgetID: LayoutValueKey {
    static let defaultValue = ""
}

private struct BarikWidgetOnLeft: LayoutValueKey {
    static let defaultValue = false
}

/// Anchor each side independently. Music can change sides, but no widget
/// can make the left edge or the clock drift beyond the screen.
private struct NotchedMenuBarLayout: Layout {
    let notch: ClosedRange<CGFloat>
    let spacing: CGFloat
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? NSScreen.main?.frame.width ?? 1512, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var left = subviews.indices.filter { subviews[$0][BarikWidgetOnLeft.self] }
        var right = subviews.indices.filter { !subviews[$0][BarikWidgetOnLeft.self] }
        let leftWidth = max(0, notch.lowerBound - 8)
        let rightStart = notch.upperBound + 8
        let rightWidth = max(0, bounds.width - rightStart)

        func totalWidth(_ indices: [Int]) -> CGFloat {
            let visible = indices.filter { sizes[$0].width > 0 }
            return visible.reduce(0) { $0 + sizes[$1].width }
                + CGFloat(max(0, visible.count - 1)) * spacing
        }

        if totalWidth(right) > rightWidth,
           let music = right.first(where: { subviews[$0][BarikWidgetID.self] == "default.spotify" }) {
            right.removeAll { $0 == music }
            left.append(music)
        }

        if let spaces = left.first(where: { subviews[$0][BarikWidgetID.self] == "default.spaces" }) {
            let others = left.filter { $0 != spaces && sizes[$0].width > 0 }
            let available = max(0, leftWidth - totalWidth(others) - (others.isEmpty ? 0 : spacing))
            sizes[spaces] = CGSize(width: available, height: height)
        }

        func place(_ indices: [Int], startingAt x: CGFloat) {
            var cursor = x
            for index in indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + cursor, y: bounds.midY),
                    anchor: .leading,
                    proposal: ProposedViewSize(width: size.width, height: height))
                if size.width > 0 { cursor += size.width + spacing }
            }
        }
        place(left, startingAt: 0)
        place(right, startingAt: max(rightStart, bounds.width - totalWidth(right)))
    }
}

private enum MenuBarRegion: Int, CaseIterable {
    case left, center, right
}

@MainActor
private final class AdaptiveContrastManager: ObservableObject {
    @Published private var schemes = Array(repeating: ColorScheme.dark, count: 3)

    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var timer: Timer?
    private var prepareTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var isSampling = false

    init() {
        #if DEBUG
        assert(Self.scheme(forLuminance: 0) == .dark)
        assert(Self.scheme(forLuminance: 1) == .light)
        #endif
    }

    deinit {
        timer?.invalidate()
        prepareTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func scheme(for region: MenuBarRegion) -> ColorScheme {
        schemes[region.rawValue]
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        prepareTask?.cancel()
        prepareTask = nil
        filter = nil
        configuration = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        guard enabled else { return }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return }

        prepareCapture()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer?.tolerance = 0.25
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareCapture() }
        }
    }

    private func prepareCapture() {
        prepareTask?.cancel()
        prepareTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return }
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard !Task.isCancelled else { return }
                let displayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else { return }
                let ownWindows = content.windows.filter {
                    $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(
                    x: 0, y: 0, width: display.width, height: 40)
                configuration.width = 90
                configuration.height = 3
                configuration.showsCursor = false

                self.filter = filter
                self.configuration = configuration
                sample()
            } catch is CancellationError {
            } catch {
                print("Adaptive contrast unavailable: \(error)")
            }
        }
    }

    private func sample() {
        guard !isSampling, let filter, let configuration else { return }
        guard CGPreflightScreenCaptureAccess() else {
            timer?.invalidate()
            timer = nil
            return
        }
        isSampling = true
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSampling = false
                guard let image else { return }
                self.schemes = Self.schemes(in: image)
            }
        }
    }

    private static func schemes(in image: CGImage) -> [ColorScheme] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return MenuBarRegion.allCases.map { region in
            let lower = image.width * region.rawValue / 3
            let upper = image.width * (region.rawValue + 1) / 3
            var luminance = 0.0
            var samples = 0.0
            for x in lower..<upper {
                for y in 0..<image.height {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    luminance += relativeLuminance(of: color)
                    samples += 1
                }
            }
            return scheme(forLuminance: samples == 0 ? 0 : luminance / samples)
        }
    }

    private static func relativeLuminance(of color: NSColor) -> Double {
        func linearize(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.redComponent)
            + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }

    private static func scheme(forLuminance luminance: Double) -> ColorScheme {
        // 0.179 is where black and white have equal WCAG contrast.
        luminance < 0.179 ? .dark : .light
    }
}

private extension View {
    @ViewBuilder
    func barikColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme)
        } else {
            self
        }
    }
}

private struct MenuBarWidgetDropDelegate: DropDelegate {
    let target: TomlWidgetItem
    @Binding var items: [TomlWidgetItem]
    @Binding var draggingItem: TomlWidgetItem?
    let onOrderChanged: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingItem,
              draggingItem != target,
              let source = items.firstIndex(of: draggingItem),
              let destination = items.firstIndex(of: target) else { return }
        withAnimation(.smooth(duration: 0.18)) {
            items.move(
                fromOffsets: IndexSet(integer: source),
                toOffset: destination > source ? destination + 1 : destination
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        onOrderChanged()
        return true
    }
}
