import SwiftUI

/// Widget displaying the Apple logo.
struct SystemWidget: View {
    private static let themes = ["dark", "light"]

    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var doNotDisturbManager = DoNotDisturbManager.shared
    var leadingPadding: CGFloat { CGFloat(configProvider.config["leading-padding"]?.doubleValue ?? 0) }
    var trailingPadding: CGFloat { CGFloat(configProvider.config["trailing-padding"]?.doubleValue ?? 0) }

    var body: some View {
        Image(systemName: "apple.logo")
            .font(.system(size: 15))
            .foregroundStyle(.foregroundOutside)
            .shadow(color: .foregroundShadowOutside, radius: 3)
            .offset(y: -1)
            .contentShape(Rectangle())
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .background(.black.opacity(0.001))
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    doNotDisturbManager.toggle()
                } else {
                    cycleTheme()
                }
            }
            .help("Click: switch theme. Option-click: toggle Do Not Disturb.")
            .accessibilityLabel("Theme control")
            .accessibilityValue(configManager.config.theme.capitalized)
            .accessibilityAction { cycleTheme() }
            .accessibilityAction(named: "Toggle Do Not Disturb") {
                doNotDisturbManager.toggle()
            }
    }

    private func cycleTheme() {
        let index = Self.themes.firstIndex(of: configManager.config.theme) ?? -1
        let nextTheme = Self.themes[(index + 1) % Self.themes.count]
        assert(Self.themes.contains(nextTheme))
        configManager.updateConfigValue(key: "theme", newValue: nextTheme)
    }
}

struct SystemWidget_Previews: PreviewProvider {
    static var previews: some View {
        SystemWidget()
            .frame(width: 100, height: 100)
            .background(Color.black)
    }
}
