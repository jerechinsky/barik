// ABOUTME: Keep Awake and Mouse Jiggler dots around the native privacy indicator.
// ABOUTME: Border-highlight green marks Keep Awake; blue marks idle jiggling and violet marks a user-active pause.

import AppKit
import SwiftUI

struct CaffeinateWidget: View {
    @ObservedObject private var manager = CaffeinateManager.shared
    var dotSpacing: CGFloat = 8
    var reservesPrivacySlot = true

    private var jigglerStatus: String {
        if !manager.isJiggling { return "Off" }
        return manager.isUserActive ? "Paused while you are active" : "On, waiting for idle time or jiggling"
    }

    var body: some View {
        VStack(spacing: 0) {
            indicator(
                active: manager.isActive,
                color: Color(red: 98.0 / 255, green: 186.0 / 255, blue: 70.0 / 255),
                label: "Keep Awake",
                help: "Keep Awake is \(manager.isActive ? "on" : "off"). Click this spot to toggle. Option-click to toggle Mouse Jiggler.",
                action: {
                    if NSEvent.modifierFlags.contains(.option) {
                        manager.toggleJiggler()
                    } else {
                        manager.toggle()
                    }
                }
            )
            if reservesPrivacySlot { Color.clear.frame(height: dotSpacing) }
            indicator(
                active: manager.isJiggling,
                color: manager.isUserActive
                    ? Color(red: 0.55, green: 0.40, blue: 0.76)
                    : Color(red: 0.05, green: 0.39, blue: 0.95),
                label: "Mouse Jiggler",
                help: manager.jigglerNeedsPermission
                    ? "Allow Barik in System Settings > Privacy & Security > Accessibility, then try again."
                    : "Mouse Jiggler: \(jigglerStatus). Click this spot to toggle.",
                action: { manager.toggleJiggler() },
                accessibilityValue: jigglerStatus
            )
        }
        .frame(width: 16, height: dotSpacing * (reservesPrivacySlot ? 3 : 2))
    }

    private func indicator(active: Bool, color: Color, label: String,
                           help: String, action: @escaping () -> Void,
                           accessibilityValue: String? = nil) -> some View {
        Button(action: action) {
            Circle()
                .fill(active ? color : .clear)
                .overlay {
                    Circle().strokeBorder(color.opacity(active ? 1 : 0.75), lineWidth: 1)
                }
                .frame(width: 6, height: 6)
                .frame(width: 16, height: dotSpacing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isChanging)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? (active ? "On" : "Off"))
    }
}

struct CaffeinateWidget_Previews: PreviewProvider {
    static var previews: some View {
        CaffeinateWidget()
            .padding(8)
            .background(.black)
    }
}
