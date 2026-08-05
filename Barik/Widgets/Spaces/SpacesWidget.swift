import SwiftUI

struct SpacesWidget: View {
    @ObservedObject var viewModel: SpacesViewModel

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    var body: some View {
        HStack(spacing: foregroundHeight < 30 ? 0 : 4) {
            ForEach(Array(viewModel.spaces.enumerated()), id: \.element.id) { index, space in
                if index > 0,
                   let prev = viewModel.spaces[index - 1].displayIndex,
                   let curr = space.displayIndex,
                   prev != curr {
                    Rectangle()
                        .fill(Color.foreground.opacity(0.4))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)
                }
                SpaceView(space: space)
            }
        }
        .experimentalConfiguration(horizontalPadding: 5, cornerRadius: 10)
        .foregroundStyle(Color.foreground)
        .environmentObject(viewModel)
    }
}

/// This view shows a space with its windows.
private struct SpaceView: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @EnvironmentObject var viewModel: SpacesViewModel

    var config: ConfigData { configProvider.config }
    var spaceConfig: ConfigData { config["space"]?.dictionaryValue ?? [:] }

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

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

    @Environment(\.colorScheme) var colorScheme
    @State var isHovered = false

    var body: some View {
        let isFocused = space.isFocused
        HStack(spacing: 0) {
            Spacer().frame(width: 6)
            if showKey {
                Text(space.id)
                    .font(.system(size: 13, weight: .medium))
                    .opacity(space.windows.isEmpty && !isFocused ? 0.5 : 1)
                    .frame(minWidth: 15)
                    .fixedSize(horizontal: true, vertical: false)
                if !space.windows.isEmpty {
                    Spacer().frame(width: 3)
                }
            }
            HStack(spacing: 2) {
                ForEach(space.windows) { window in
                    WindowIconView(window: window, space: space)
                }
            }
            if let displayWindow = space.windows.first(where: { $0.isFocused })
                ?? (isFocused ? space.windows.first : nil) {
                FocusedWindowTitleView(window: displayWindow, space: space)
            }
            Spacer().frame(width: 6)
        }
        .frame(height: 30)
        .background(
            foregroundHeight < 30 ?
            (isFocused
             ? Color.noActive
             : Color.clear) :
                (isFocused
                 ? Color.active
                 : isHovered ? Color.noActive : Color.noActive)
        )
        .clipShape(RoundedRectangle(cornerRadius: foregroundHeight < 30 ? 0 : 8, style: .continuous))
        .overlay(
            Group {
                if foregroundHeight >= 30 {
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
        .onTapGesture {
            viewModel.switchToSpace(space, needWindowFocus: true)
        }
        .onHover { value in
            isHovered = value
        }
    }
}

/// This view shows a window icon only (no title).
private struct WindowIconView: View {
    @EnvironmentObject var viewModel: SpacesViewModel

    let window: AnyWindow
    let space: AnySpace

    @State var isHovered = false

    var body: some View {
        let size: CGFloat = 21
        let spaceIsFocused = space.windows.contains { $0.isFocused }
        ZStack {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
                    .shadow(color: .iconShadow, radius: 2)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .opacity(spaceIsFocused && !window.isFocused ? 0.5 : 1)
        .animation(.easeOut(duration: 0.2), value: window.isFocused)
        .padding(.all, 2)
        .background(isHovered ? .selected : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.switchToSpace(space)
            usleep(100_000)
            viewModel.switchToWindow(window)
        }
        .onHover { value in
            isHovered = value
        }
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
